const std = @import("std");

const Allocator = std.mem.Allocator;
const handler_mod = @import("handler.zig");
const router_mod = @import("router.zig");

pub const App = struct {
    allocator: Allocator,
    routes: std.ArrayListUnmanaged(router_mod.Route),
    middleware: std.ArrayListUnmanaged(handler_mod.MiddlewareFn),

    pub fn init(a: Allocator) App {
        return .{
            .allocator = a,
            .routes = .{},
            .middleware = .{},
        };
    }

    pub fn deinit(self: *App) void {
        self.routes.deinit(self.allocator);
        self.middleware.deinit(self.allocator);
    }

    pub fn get(self: *App, path: []const u8, h: handler_mod.HandlerFn) void {
        self.routes.append(self.allocator, .{ .method = "GET", .path = path, .handler = h }) catch {};
    }

    pub fn post(self: *App, path: []const u8, h: handler_mod.HandlerFn) void {
        self.routes.append(self.allocator, .{ .method = "POST", .path = path, .handler = h }) catch {};
    }

    pub fn put(self: *App, path: []const u8, h: handler_mod.HandlerFn) void {
        self.routes.append(self.allocator, .{ .method = "PUT", .path = path, .handler = h }) catch {};
    }

    pub fn delete(self: *App, path: []const u8, h: handler_mod.HandlerFn) void {
        self.routes.append(self.allocator, .{ .method = "DELETE", .path = path, .handler = h }) catch {};
    }

    pub fn use(self: *App, m: handler_mod.MiddlewareFn) void {
        self.middleware.append(self.allocator, m) catch {};
    }

    pub fn group(self: *App, prefix: []const u8) router_mod.RouteGroup {
        return router_mod.RouteGroup.init(self.allocator, prefix);
    }

    /// Adds all routes from a RouteGroup into this App.
    pub fn mount(self: *App, route_group: *const router_mod.RouteGroup) void {
        for (route_group.routes.items) |route| {
            self.routes.append(self.allocator, route) catch {};
        }
    }

    /// Dispatches a request context through the matched handler.
    pub fn dispatch(self: *App, ctx: *handler_mod.Context) !void {
        const result = try router_mod.match(self.allocator, self.routes.items, @tagName(ctx.method), ctx.path);
        if (result) |r| {
            defer self.allocator.free(r.params);
            const context_params = blk: {
                var p: std.ArrayListUnmanaged(handler_mod.Context.Param) = .{};
                defer p.deinit(self.allocator);
                for (r.params) |rp| {
                    try p.append(self.allocator, .{ .name = rp.name, .value = rp.value });
                }
                break :blk try self.allocator.dupe(handler_mod.Context.Param, p.items);
            };
            ctx.params = context_params;
            defer self.allocator.free(context_params);

            try r.handler(ctx);
        } else {
            ctx.response_status = 404;
            try ctx.respond("Not Found", "text/plain");
        }
    }

    /// Starts listening on the given port. Stub -- actual networking is
    /// a future integration piece.
    pub fn listen(self: *App, port: u16) !void {
        _ = self;
        _ = port;
        return error.NotImplemented;
    }
};

// ── Tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

test "App: route registration and dispatch" {
    const hello = struct {
        fn handle(ctx: *handler_mod.Context) anyerror!void {
            try ctx.respond("hello", "text/plain");
        }
    }.handle;

    var app = App.init(testing.allocator);
    defer app.deinit();

    app.get("/hello", hello);

    var ctx = handler_mod.Context{
        .allocator = testing.allocator,
        .method = .GET,
        .path = "/hello",
    };
    try app.dispatch(&ctx);
    try testing.expectEqualStrings("hello", ctx.response_body);
}

test "App: 404 on no match" {
    var app = App.init(testing.allocator);
    defer app.deinit();

    var ctx = handler_mod.Context{
        .allocator = testing.allocator,
        .method = .GET,
        .path = "/missing",
    };
    try app.dispatch(&ctx);
    try testing.expectEqual(@as(u16, 404), ctx.response_status);
}

test "App: listen returns NotImplemented" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try testing.expectError(error.NotImplemented, app.listen(8080));
}
