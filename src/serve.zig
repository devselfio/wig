const std = @import("std");
const Allocator = std.mem.Allocator;
const fs = std.fs;
const wig = @import("root.zig");
const mime = @import("mime.zig");
const Watcher = @import("watcher.zig").Watcher;

const reload_js = @embedFile("serve/reload.js");
const reload_script_tag = "<script defer src=\"/__wig/reload.js\"></script>";

const log = std.log.scoped(.serve);

pub const Options = struct {
    /// Bind address. Defaults to 127.0.0.1; use "0.0.0.0" to accept from all interfaces.
    host: []const u8 = "127.0.0.1",
    port: u16 = 8080,
    live_reload: bool = true,
};

pub const DevServer = struct {
    allocator: Allocator,
    site: *wig.Site,
    options: Options,

    build_lock: std.Thread.RwLock = .{},
    output_path: ?[]const u8 = null,

    ws_mutex: std.Thread.Mutex = .{},
    ws_clients: std.ArrayListUnmanaged(std.http.Server.WebSocket) = .{},

    pub fn run(allocator: Allocator, site: *wig.Site, options: Options) !void {
        var self = DevServer{
            .allocator = allocator,
            .site = site,
            .options = options,
        };

        const abs_root = try site.root_dir.realpathAlloc(allocator, ".");
        defer allocator.free(abs_root);

        std.debug.print("wig serve: building site...\n", .{});
        self.rebuild();

        const watch_dirs: []const []const u8 = &.{
            "pages",
            "data",
            "styles",
            "assets",
        };

        var watcher = Watcher.init(
            allocator,
            abs_root,
            watch_dirs,
            200 * std.time.ns_per_ms,
        );
        try watcher.start();
        defer watcher.stop();

        const http_thread = try std.Thread.spawn(.{}, httpAcceptLoop, .{&self});
        http_thread.detach();

        std.debug.print(
            "wig serve: listening on http://{s}:{d}/\n",
            .{ options.host, options.port },
        );

        while (true) {
            watcher.waitForChange();

            std.debug.print("wig serve: change detected, rebuilding...\n", .{});
            self.build_lock.lock();
            self.rebuild();
            self.build_lock.unlock();

            if (options.live_reload) {
                self.broadcastReload();
            }
        }
    }

    fn rebuild(self: *DevServer) void {
        const result = self.site.buildAll(.{ .clean = false }) catch |err| {
            std.debug.print("wig serve: build failed ({any})\n", .{err});
            if (self.options.live_reload) self.broadcastError("Build failed");
            return;
        };
        std.debug.print("wig serve: ok ({d} pages)\n", .{result.page_count});

        if (self.output_path == null) {
            const path = self.site.root_dir.realpathAlloc(
                self.allocator,
                "zig-out/site",
            ) catch return;
            self.output_path = path;
        }
    }

    fn broadcastReload(self: *DevServer) void {
        self.ws_mutex.lock();
        defer self.ws_mutex.unlock();

        var i: usize = 0;
        while (i < self.ws_clients.items.len) {
            var ws = &self.ws_clients.items[i];
            ws.writeMessage("{\"command\":\"reload\"}", .text) catch {
                _ = self.ws_clients.swapRemove(i);
                continue;
            };
            i += 1;
        }
    }

    fn broadcastError(self: *DevServer, msg: []const u8) void {
        self.ws_mutex.lock();
        defer self.ws_mutex.unlock();

        var buf: [512]u8 = undefined;
        const json = std.fmt.bufPrint(&buf, "{{\"command\":\"error\",\"message\":\"{s}\"}}", .{msg}) catch return;

        var i: usize = 0;
        while (i < self.ws_clients.items.len) {
            var ws = &self.ws_clients.items[i];
            ws.writeMessage(json, .text) catch {
                _ = self.ws_clients.swapRemove(i);
                continue;
            };
            i += 1;
        }
    }

    fn httpAcceptLoop(self: *DevServer) void {
        const address = std.net.Address.resolveIp(self.options.host, self.options.port) catch |err| {
            std.debug.print("wig serve: failed to resolve address: {s}\n", .{@errorName(err)});
            return;
        };

        var tcp = address.listen(.{ .reuse_address = true }) catch |err| {
            std.debug.print("wig serve: failed to bind port {d}: {s}\n", .{ self.options.port, @errorName(err) });
            return;
        };
        defer tcp.deinit();

        while (true) {
            const conn = tcp.accept() catch |err| {
                log.debug("accept error: {s}", .{@errorName(err)});
                continue;
            };
            const t = std.Thread.spawn(.{}, handleConnection, .{ self, conn }) catch {
                conn.stream.close();
                continue;
            };
            t.detach();
        }
    }

    fn handleConnection(self: *DevServer, conn: std.net.Server.Connection) void {
        defer conn.stream.close();

        var read_buf: [8192]u8 = undefined;
        var in = conn.stream.reader(&read_buf);
        var write_buf: [4096]u8 = undefined;
        var out = conn.stream.writer(&write_buf);

        var http = std.http.Server.init(in.interface(), &out.interface);

        while (true) {
            var request = http.receiveHead() catch return;
            self.handleRequest(&request) catch return;
        }
    }

    fn handleRequest(self: *DevServer, req: *std.http.Server.Request) !void {
        const target = req.head.target;

        if (std.mem.indexOf(u8, target, "..") != null) {
            try req.respond("Forbidden", .{
                .status = .forbidden,
                .extra_headers = &.{
                    .{ .name = "content-type", .value = "text/plain" },
                },
            });
            return;
        }

        var path = target[0 .. std.mem.indexOfScalar(u8, target, '?') orelse target.len];

        if (self.options.live_reload) {
            if (std.mem.eql(u8, path, "/__wig/reload.js")) {
                try req.respond(reload_js, .{
                    .extra_headers = &.{
                        .{ .name = "content-type", .value = "text/javascript; charset=utf-8" },
                    },
                });
                return;
            }

            if (std.mem.eql(u8, path, "/__wig/ws")) {
                self.handleWebSocket(req);
                return;
            }
        }

        if (std.mem.endsWith(u8, path, "/")) {
            path = std.fmt.allocPrint(self.allocator, "{s}index.html", .{path}) catch return;
        }

        const serve_path = if (path.len > 0 and path[0] == '/') path[1..] else path;

        self.build_lock.lockShared();
        defer self.build_lock.unlockShared();

        const out_path = self.output_path orelse {
            try req.respond("Site not built yet", .{
                .status = .service_unavailable,
                .extra_headers = &.{
                    .{ .name = "content-type", .value = "text/plain" },
                },
            });
            return;
        };

        var dir = fs.openDirAbsolute(out_path, .{}) catch {
            try req.respond("Output directory not found", .{
                .status = .internal_server_error,
                .extra_headers = &.{
                    .{ .name = "content-type", .value = "text/plain" },
                },
            });
            return;
        };
        defer dir.close();

        const content = dir.readFileAlloc(self.allocator, serve_path, 64 * 1024 * 1024) catch {
            try req.respond("Not Found", .{
                .status = .not_found,
                .extra_headers = &.{
                    .{ .name = "content-type", .value = "text/plain" },
                },
            });
            return;
        };
        defer self.allocator.free(content);

        const content_type = mime.fromPath(serve_path);
        const is_html = std.mem.startsWith(u8, content_type, "text/html");

        if (is_html and self.options.live_reload) {
            self.sendHtmlWithReload(req, content) catch |err| {
                log.debug("error sending HTML: {s}", .{@errorName(err)});
            };
        } else {
            req.respond(content, .{
                .extra_headers = &.{
                    .{ .name = "content-type", .value = content_type },
                },
            }) catch |err| {
                log.debug("error sending response: {s}", .{@errorName(err)});
            };
        }
    }

    fn sendHtmlWithReload(self: *DevServer, req: *std.http.Server.Request, html: []const u8) !void {
        const head_pos = std.mem.indexOf(u8, html, "</head>") orelse html.len;
        const injected = try std.fmt.allocPrint(self.allocator, "{s}{s}{s}", .{
            html[0..head_pos],
            reload_script_tag,
            html[head_pos..],
        });
        defer self.allocator.free(injected);

        try req.respond(injected, .{
            .extra_headers = &.{
                .{ .name = "content-type", .value = "text/html; charset=utf-8" },
            },
        });
    }

    fn handleWebSocket(self: *DevServer, req: *std.http.Server.Request) void {
        const up = req.upgradeRequested();
        const key = switch (up) {
            .websocket => |k| k orelse {
                req.respond("Bad WebSocket request", .{ .status = .bad_request }) catch {};
                return;
            },
            else => {
                req.respond("Expected WebSocket upgrade", .{ .status = .bad_request }) catch {};
                return;
            },
        };

        var ws = req.respondWebSocket(.{ .key = key }) catch return;

        {
            self.ws_mutex.lock();
            defer self.ws_mutex.unlock();
            self.ws_clients.append(self.allocator, ws) catch return;
        }

        while (true) {
            _ = ws.readSmallMessage() catch {
                self.ws_mutex.lock();
                defer self.ws_mutex.unlock();
                for (self.ws_clients.items, 0..) |*c, i| {
                    if (c.key.ptr == ws.key.ptr) {
                        _ = self.ws_clients.swapRemove(i);
                        break;
                    }
                }
                return;
            };
        }
    }
};
