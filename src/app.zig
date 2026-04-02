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

    pub fn get(self: *App, path: []const u8, h: handler_mod.HandlerFn) !void {
        try self.routes.append(self.allocator, .{ .method = "GET", .path = path, .handler = h });
    }

    pub fn post(self: *App, path: []const u8, h: handler_mod.HandlerFn) !void {
        try self.routes.append(self.allocator, .{ .method = "POST", .path = path, .handler = h });
    }

    pub fn put(self: *App, path: []const u8, h: handler_mod.HandlerFn) !void {
        try self.routes.append(self.allocator, .{ .method = "PUT", .path = path, .handler = h });
    }

    pub fn delete(self: *App, path: []const u8, h: handler_mod.HandlerFn) !void {
        try self.routes.append(self.allocator, .{ .method = "DELETE", .path = path, .handler = h });
    }

    pub fn use(self: *App, m: handler_mod.MiddlewareFn) !void {
        try self.middleware.append(self.allocator, m);
    }

    pub fn group(self: *App, prefix: []const u8) router_mod.RouteGroup {
        return router_mod.RouteGroup.init(self.allocator, prefix);
    }

    /// Adds all routes from a RouteGroup into this App, duping path strings
    /// so the App owns its copies independently of the group's lifetime.
    pub fn mount(self: *App, route_group: *const router_mod.RouteGroup) !void {
        for (route_group.routes.items) |route| {
            const path_copy = try self.allocator.dupe(u8, route.path);
            errdefer self.allocator.free(path_copy);
            try self.routes.append(self.allocator, .{ .method = route.method, .path = path_copy, .handler = route.handler });
        }
    }

    /// Dispatches a request context through middleware then the matched handler.
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

            ctx._middleware = self.middleware.items;
            ctx._mw_index = 0;
            ctx._final_handler = r.handler;
            try ctx.next();
        } else {
            ctx.response_status = 404;
            try ctx.respond("Not Found", "text/plain");
        }
    }

    /// Starts listening on the given port.
    ///
    /// **Deferred:** TCP server implementation requires `std.net.Server`
    /// integration and is planned for a future phase. Currently returns
    /// `error.NotImplemented`. Use `dispatch()` directly for testing.
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

    try app.get("/hello", hello);

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

test "App: middleware runs before handler" {
    const mw = struct {
        fn handle(ctx: *handler_mod.Context) anyerror!void {
            ctx.response_status = 201;
            try ctx.next();
        }
    }.handle;

    const hello = struct {
        fn handle(ctx: *handler_mod.Context) anyerror!void {
            try ctx.respond("hello", "text/plain");
        }
    }.handle;

    var a = App.init(testing.allocator);
    defer a.deinit();

    try a.use(mw);
    try a.get("/hello", hello);

    var ctx = handler_mod.Context{
        .allocator = testing.allocator,
        .method = .GET,
        .path = "/hello",
    };
    try a.dispatch(&ctx);
    try testing.expectEqual(@as(u16, 201), ctx.response_status);
    try testing.expectEqualStrings("hello", ctx.response_body);
}

test "App: listen returns NotImplemented" {
    var a = App.init(testing.allocator);
    defer a.deinit();
    try testing.expectError(error.NotImplemented, a.listen(8080));
}
