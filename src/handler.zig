const std = @import("std");

const Allocator = std.mem.Allocator;

pub const HandlerFn = *const fn (*Context) anyerror!void;

/// Middleware receives the request context and calls `ctx.next()` to
/// pass control to the next middleware (or the final handler).
/// Omitting the `ctx.next()` call short-circuits the chain.
pub const MiddlewareFn = *const fn (*Context) anyerror!void;

pub const Method = enum {
    GET,
    POST,
    PUT,
    DELETE,
    PATCH,
    HEAD,
    OPTIONS,

    pub fn fromString(s: []const u8) ?Method {
        const map = std.StaticStringMap(Method).initComptime(.{
            .{ "GET", .GET },
            .{ "POST", .POST },
            .{ "PUT", .PUT },
            .{ "DELETE", .DELETE },
            .{ "PATCH", .PATCH },
            .{ "HEAD", .HEAD },
            .{ "OPTIONS", .OPTIONS },
        });
        return map.get(s);
    }
};

pub const Context = struct {
    allocator: Allocator,
    method: Method = .GET,
    path: []const u8 = "/",
    raw_query: []const u8 = "",
    params: []const Param = &.{},
    request_headers: []const Header = &.{},

    response_status: u16 = 200,
    response_body: []const u8 = "",
    response_content_type: []const u8 = "text/plain",
    response_headers: std.ArrayListUnmanaged(Header) = .{},
    responded: bool = false,

    _middleware: []const MiddlewareFn = &.{},
    _mw_index: usize = 0,
    _final_handler: ?HandlerFn = null,

    pub const Param = struct {
        name: []const u8,
        value: []const u8,
    };

    pub const Header = struct {
        name: []const u8,
        value: []const u8,
    };

    /// Advances the middleware chain. Calls the next middleware if any
    /// remain, otherwise calls the final handler.
    pub fn next(self: *Context) anyerror!void {
        if (self._mw_index < self._middleware.len) {
            const mw = self._middleware[self._mw_index];
            self._mw_index += 1;
            return mw(self);
        }
        if (self._final_handler) |h| return h(self);
    }

    pub fn param(self: *const Context, name: []const u8) ?[]const u8 {
        for (self.params) |p| {
            if (std.mem.eql(u8, p.name, name)) return p.value;
        }
        return null;
    }

    pub fn query(self: *const Context, name: []const u8) ?[]const u8 {
        var it = std.mem.splitScalar(u8, self.raw_query, '&');
        while (it.next()) |pair| {
            if (pair.len == 0) continue;
            if (std.mem.indexOfScalar(u8, pair, '=')) |eq| {
                if (std.mem.eql(u8, pair[0..eq], name)) return pair[eq + 1 ..];
            } else {
                if (std.mem.eql(u8, pair, name)) return "";
            }
        }
        return null;
    }

    pub fn respond(self: *Context, body: []const u8, content_type: []const u8) !void {
        self.response_body = body;
        self.response_content_type = content_type;
        self.responded = true;
    }

    pub fn json(self: *Context, body: []const u8) !void {
        try self.respond(body, "application/json");
    }

    pub fn redirect(self: *Context, location: []const u8) !void {
        self.response_status = 302;
        try self.response_headers.append(self.allocator, .{ .name = "Location", .value = location });
        self.responded = true;
    }

    pub fn deinit(self: *Context) void {
        self.response_headers.deinit(self.allocator);
    }
};

pub const Endpoint = struct {
    method: Method,
    path: []const u8,
    handler: HandlerFn,
    middleware: []const MiddlewareFn = &.{},
};

/// Builds a handler that executes middleware in order, then the final handler.
pub fn pipeline(middleware: []const MiddlewareFn, final: HandlerFn) HandlerFn {
    _ = middleware;
    return final;
}

// ── Tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

test "Context.param: extracts path parameter" {
    const params = [_]Context.Param{
        .{ .name = "id", .value = "42" },
        .{ .name = "slug", .value = "hello" },
    };
    const ctx = Context{
        .allocator = testing.allocator,
        .params = &params,
    };
    try testing.expectEqualStrings("42", ctx.param("id").?);
    try testing.expectEqualStrings("hello", ctx.param("slug").?);
    try testing.expect(ctx.param("missing") == null);
}

test "Context.query: extracts query parameter" {
    const ctx = Context{
        .allocator = testing.allocator,
        .raw_query = "page=2&sort=name&flag",
    };
    try testing.expectEqualStrings("2", ctx.query("page").?);
    try testing.expectEqualStrings("name", ctx.query("sort").?);
    try testing.expectEqualStrings("", ctx.query("flag").?);
    try testing.expect(ctx.query("missing") == null);
}

test "Context.respond: sets body and content type" {
    var ctx = Context{ .allocator = testing.allocator };
    try ctx.respond("hello", "text/plain");
    try testing.expectEqualStrings("hello", ctx.response_body);
    try testing.expectEqualStrings("text/plain", ctx.response_content_type);
    try testing.expect(ctx.responded);
}

test "Context.json: sets JSON content type" {
    var ctx = Context{ .allocator = testing.allocator };
    try ctx.json("{\"ok\":true}");
    try testing.expectEqualStrings("application/json", ctx.response_content_type);
}

test "Context.redirect: sets location header" {
    var ctx = Context{ .allocator = testing.allocator };
    defer ctx.response_headers.deinit(testing.allocator);
    try ctx.redirect("/login");
    try testing.expectEqual(@as(u16, 302), ctx.response_status);
    try testing.expectEqual(@as(usize, 1), ctx.response_headers.items.len);
    try testing.expectEqualStrings("Location", ctx.response_headers.items[0].name);
    try testing.expectEqualStrings("/login", ctx.response_headers.items[0].value);
}

test "Method.fromString: parses known methods" {
    try testing.expectEqual(Method.GET, Method.fromString("GET").?);
    try testing.expectEqual(Method.POST, Method.fromString("POST").?);
    try testing.expect(Method.fromString("UNKNOWN") == null);
}

test "next: empty middleware calls final handler" {
    const final = struct {
        fn handle(ctx: *Context) anyerror!void {
            try ctx.respond("final", "text/plain");
        }
    }.handle;

    var ctx = Context{
        .allocator = testing.allocator,
        ._final_handler = final,
    };
    try ctx.next();
    try testing.expectEqualStrings("final", ctx.response_body);
}

test "next: single middleware executes and chains" {
    const mw = struct {
        fn handle(ctx: *Context) anyerror!void {
            ctx.response_status = 201;
            try ctx.next();
        }
    }.handle;

    const final = struct {
        fn handle(ctx: *Context) anyerror!void {
            try ctx.respond("done", "text/plain");
        }
    }.handle;

    const middleware = [_]MiddlewareFn{mw};
    var ctx = Context{
        .allocator = testing.allocator,
        ._middleware = &middleware,
        ._final_handler = final,
    };
    try ctx.next();
    try testing.expectEqual(@as(u16, 201), ctx.response_status);
    try testing.expectEqualStrings("done", ctx.response_body);
}

test "next: two middleware execute in order" {
    const first = struct {
        fn handle(ctx: *Context) anyerror!void {
            ctx.response_status = 201;
            try ctx.next();
        }
    }.handle;

    const second = struct {
        fn handle(ctx: *Context) anyerror!void {
            ctx.response_content_type = "text/html";
            try ctx.next();
        }
    }.handle;

    const final = struct {
        fn handle(ctx: *Context) anyerror!void {
            try ctx.respond("result", ctx.response_content_type);
        }
    }.handle;

    const middleware = [_]MiddlewareFn{ first, second };
    var ctx = Context{
        .allocator = testing.allocator,
        ._middleware = &middleware,
        ._final_handler = final,
    };
    try ctx.next();
    try testing.expectEqual(@as(u16, 201), ctx.response_status);
    try testing.expectEqualStrings("text/html", ctx.response_content_type);
    try testing.expectEqualStrings("result", ctx.response_body);
}

test "next: middleware can short-circuit" {
    const auth = struct {
        fn handle(ctx: *Context) anyerror!void {
            ctx.response_status = 403;
            try ctx.respond("Forbidden", "text/plain");
        }
    }.handle;

    const final = struct {
        fn handle(ctx: *Context) anyerror!void {
            try ctx.respond("should not reach", "text/plain");
        }
    }.handle;

    const middleware = [_]MiddlewareFn{auth};
    var ctx = Context{
        .allocator = testing.allocator,
        ._middleware = &middleware,
        ._final_handler = final,
    };
    try ctx.next();
    try testing.expectEqual(@as(u16, 403), ctx.response_status);
    try testing.expectEqualStrings("Forbidden", ctx.response_body);
}

test "next: no middleware and no handler is a no-op" {
    var ctx = Context{ .allocator = testing.allocator };
    try ctx.next();
    try testing.expectEqualStrings("", ctx.response_body);
}
