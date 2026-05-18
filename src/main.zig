const std = @import("std");
const wig = @import("wig");
const options = @import("options");

pub fn main() !void {
    const a = std.heap.page_allocator;
    var args = std.process.args();
    _ = args.next(); // skip executable name

    const command = args.next() orelse {
        printUsage();
        return;
    };

    if (std.mem.eql(u8, command, "--version") or std.mem.eql(u8, command, "-V")) {
        printVersion();
        return;
    }

    if (std.mem.eql(u8, command, "init")) {
        const path = args.next() orelse ".";
        try wig.scaffold.init(a, path);
    } else if (std.mem.eql(u8, command, "build")) {
        const opts = parseBuildArgs(&args);
        var site = try wig.Site.init(a, .{ .root = opts.path });
        defer site.deinit();
        const result = site.buildAll(.{
            .clean = opts.clean,
            .pretty = opts.pretty,
            .strict_links = opts.strict_links,
        }) catch |err| {
            std.debug.print("wig build: failed ({any})\n", .{err});
            return err;
        };
        printBuildDiagnostics(result.diagnostics);
        std.debug.print("wig build: ok ({d} pages) → {s}/zig-out/site/\n", .{ result.page_count, opts.path });
        if (result.diagnostics.hasErrors()) std.process.exit(1);
    } else if (std.mem.eql(u8, command, "check")) {
        const v = parseCheckArgs(&args);
        var site = try wig.Site.init(a, .{ .root = v.path });
        defer site.deinit();
        const diags = try site.check(.{ .external_links = v.external });
        defer site.allocator.free(diags);
        printDiagnostics(diags);
        if (hasErrors(diags)) std.process.exit(1);
    } else if (std.mem.eql(u8, command, "install")) {
        const name_or_url = args.next() orelse {
            std.debug.print("wig install: missing style name or URL\n", .{});
            return;
        };
        const force = hasFlag(&args, "--force");
        const pages = hasFlag(&args, "--pages");
        wig.scaffold.install(a, name_or_url, ".", .{ .force = force, .include_pages = pages }) catch |err| {
            if (err == error.NotImplemented) {
                std.debug.print("wig install: not available in v0.1.0 (planned for a future release)\n", .{});
                std.process.exit(2);
            }
            return err;
        };
    } else if (std.mem.eql(u8, command, "add")) {
        const sub = args.next() orelse {
            std.debug.print("wig add: specify 'style' or 'block'\n", .{});
            return;
        };
        if (std.mem.eql(u8, sub, "style")) {
            const name = args.next() orelse {
                std.debug.print("wig add style: missing style name\n", .{});
                return;
            };
            try wig.scaffold.addStyle(a, "styles", name);
        } else if (std.mem.eql(u8, sub, "block")) {
            const style = args.next() orelse {
                std.debug.print("wig add block: missing style name\n", .{});
                return;
            };
            const block = args.next() orelse {
                std.debug.print("wig add block: missing block name\n", .{});
                return;
            };
            try wig.scaffold.addBlock(a, "styles", style, block);
        } else {
            std.debug.print("wig add: unknown subcommand '{s}'\n", .{sub});
        }
    } else if (std.mem.eql(u8, command, "serve")) {
        const opts = parseServeArgs(&args);
        var site = try wig.Site.init(a, .{ .root = opts.path });
        defer site.deinit();
        wig.serve_mod.DevServer.run(a, &site, .{
            .host = opts.host,
            .port = opts.port,
            .live_reload = opts.live_reload,
        }) catch |err| {
            std.debug.print("wig serve: failed ({any})\n", .{err});
            return err;
        };
    } else if (std.mem.eql(u8, command, "styles")) {
        std.debug.print("wig styles: not available in v0.1.0 (planned for a future release)\n", .{});
        std.process.exit(2);
    } else {
        std.debug.print("wig: unknown command '{s}'\n", .{command});
        printUsage();
    }
}

fn printVersion() void {
    std.debug.print("wig {f}\n", .{options.version});
}

fn printBuildDiagnostics(diags: wig.diagnostics_mod.Collector) void {
    for (diags.items.items) |d| {
        const label: []const u8 = switch (d.kind) {
            .err => "error",
            .warning => "warning",
        };
        std.debug.print("{s}: {s}\n", .{ label, d.message });
    }
}

fn printDiagnostics(diags: []const wig.Diagnostic) void {
    for (diags) |d| {
        const label: []const u8 = switch (d.kind) {
            .err => "error",
            .warning => "warning",
        };
        if (d.template_name) |t| {
            std.debug.print("{s}: {s}: {s}\n", .{ label, t, d.message });
        } else {
            std.debug.print("{s}: {s}\n", .{ label, d.message });
        }
    }
}

fn hasErrors(diags: []const wig.Diagnostic) bool {
    for (diags) |d| {
        if (d.kind == .err) return true;
    }
    return false;
}

fn printUsage() void {
    std.debug.print(
        \\Usage: wig <command> [options]
        \\
        \\Global:
        \\  -V, --version                Print version and exit
        \\
        \\Commands:
        \\  init [path]                  Scaffold a new Wig project
        \\  build [path] [--clean] [--pretty] [--strict-links]
        \\                               Build static site to zig-out/site/
        \\  install <name|url>           Install a style (not available in v0.1.0)
        \\  add style <name>             Create a new empty style
        \\  add block <style> <name>     Add a block pattern to a style
        \\    serve [path] [--host HOST] [--port PORT] [--no-reload]
\\                               Dev server with live reload
        \\  check [path] [--external]    Validate config/templates without building
        \\
    , .{});
}

const BuildArgs = struct {
    path: []const u8,
    clean: bool,
    pretty: bool,
    strict_links: bool,
};

/// Parses optional `[path]`, `--clean`, `--pretty`, `--strict-links`,
/// `--external-links` in any order after the subcommand.
fn parseBuildArgs(args: *std.process.ArgIterator) BuildArgs {
    var path: ?[]const u8 = null;
    var clean = false;
    var pretty = false;
    var strict_links = false;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--clean")) {
            clean = true;
        } else if (std.mem.eql(u8, arg, "--pretty")) {
            pretty = true;
        } else if (std.mem.eql(u8, arg, "--strict-links")) {
            strict_links = true;
        } else if (std.mem.eql(u8, arg, "--external-links")) {
            std.debug.print("wig build: --external-links is not yet implemented\n", .{});
        } else if (arg.len > 0 and arg[0] == '-') {
            std.debug.print("wig build: unknown option '{s}'\n", .{arg});
        } else if (path == null) {
            path = arg;
        } else {
            std.debug.print("wig build: unexpected extra argument '{s}'\n", .{arg});
        }
    }
    return .{ .path = path orelse ".", .clean = clean, .pretty = pretty, .strict_links = strict_links };
}

const CheckArgs = struct {
    path: []const u8,
    external: bool,
};

/// Parses optional `[path]` and `--external` in any order after `check`.
fn parseCheckArgs(args: *std.process.ArgIterator) CheckArgs {
    var path: ?[]const u8 = null;
    var external = false;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--external")) {
            external = true;
        } else if (arg.len > 0 and arg[0] == '-') {
            std.debug.print("wig check: unknown option '{s}'\n", .{arg});
        } else if (path == null) {
            path = arg;
        } else {
            std.debug.print("wig check: unexpected extra argument '{s}'\n", .{arg});
        }
    }
    return .{ .path = path orelse ".", .external = external };
}

const ServeArgs = struct {
    path: []const u8,
    host: []const u8,
    port: u16,
    live_reload: bool,
};

fn parseServeArgs(args: *std.process.ArgIterator) ServeArgs {
    var path: ?[]const u8 = null;
    var host: []const u8 = "127.0.0.1";
    var port: u16 = 8080;
    var live_reload = true;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--no-reload")) {
            live_reload = false;
        } else if (std.mem.startsWith(u8, arg, "--host")) {
            if (std.mem.eql(u8, arg, "--host")) {
                if (args.next()) |h| host = h;
            } else if (arg.len > 7 and arg[6] == '=') {
                host = arg[7..];
            }
        } else if (std.mem.startsWith(u8, arg, "--port")) {
            if (std.mem.eql(u8, arg, "--port")) {
                if (args.next()) |p| {
                    port = std.fmt.parseInt(u16, p, 10) catch 8080;
                }
            } else if (arg.len > 7 and arg[6] == '=') {
                port = std.fmt.parseInt(u16, arg[7..], 10) catch 8080;
            }
        } else if (arg.len > 0 and arg[0] == '-') {
            std.debug.print("wig serve: unknown option '{s}'\n", .{arg});
        } else if (path == null) {
            path = arg;
        } else {
            std.debug.print("wig serve: unexpected extra argument '{s}'\n", .{arg});
        }
    }
    return .{ .path = path orelse ".", .host = host, .port = port, .live_reload = live_reload };
}

fn hasFlag(args: *std.process.ArgIterator, flag: []const u8) bool {
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, flag)) return true;
    }
    return false;
}
