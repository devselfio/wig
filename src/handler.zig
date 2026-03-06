const std = @import("std");

const Allocator = std.mem.Allocator;

pub const HandlerFn = *const fn (*Context) anyerror!void;
pub const NextFn = *const fn (*Context) anyerror!void;
pub const MiddlewareFn = *const fn (*Context, NextFn) anyerror!void;

/// Builds a single handler function that chains middleware in order,
/// terminating at the final handler.
pub fn buildChain(
    a: Allocator,
    middleware: []const MiddlewareFn,
    final_handler: HandlerFn,
) !HandlerFn {
    if (middleware.len == 0) return final_handler;

    var current: HandlerFn = final_handler;
    var i: usize = middleware.len;
    while (i > 0) {
        i -= 1;
        const mw = middleware[i];
        const next_handler = current;
        const wrapper = try ChainWrapper.create(a, mw, next_handler);
        current = wrapper.handler();
    }
    return current;
}

const ChainWrapper = struct {
    mw: MiddlewareFn,
    next_handler: HandlerFn,

    fn create(a: Allocator, mw: MiddlewareFn, next_handler: HandlerFn) !*ChainWrapper {
        const self = try a.create(ChainWrapper);
        self.* = .{ .mw = mw, .next_handler = next_handler };
        return self;
    }

    fn handler(self: *const ChainWrapper) HandlerFn {
        _ = self;
        return &dispatch;
    }

    fn dispatch(ctx: *Context) anyerror!void {
        _ = ctx;
        return error.NotImplemented;
    }
};

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

    pub const Param = struct {
        name: []const u8,
        value: []const u8,
    };

    pub const Header = struct {
        name: []const u8,
        value: []const u8,
    };

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
};

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
