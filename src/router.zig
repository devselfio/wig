const std = @import("std");
const handler_mod = @import("handler.zig");

const Allocator = std.mem.Allocator;

pub const Route = struct {
    method: []const u8,
    path: []const u8,
    handler: handler_mod.HandlerFn,
};

pub const MatchResult = struct {
    handler: handler_mod.HandlerFn,
    params: []const Param,
};

pub const Param = struct {
    name: []const u8,
    value: []const u8,
};

pub const RouteGroup = struct {
    prefix: []const u8,
    routes: std.ArrayListUnmanaged(Route),
    allocator: Allocator,

    pub fn init(a: Allocator, prefix: []const u8) RouteGroup {
        return .{
            .prefix = prefix,
            .routes = .{},
            .allocator = a,
        };
    }

    pub fn deinit(self: *RouteGroup) void {
        for (self.routes.items) |r| self.allocator.free(@constCast(r.path));
        self.routes.deinit(self.allocator);
    }

    pub fn add(self: *RouteGroup, method: []const u8, sub_path: []const u8, h: handler_mod.HandlerFn) !void {
        const full = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ self.prefix, sub_path });
        errdefer self.allocator.free(full);
        try self.routes.append(self.allocator, .{ .method = method, .path = full, .handler = h });
    }

    pub fn get(self: *RouteGroup, sub_path: []const u8, h: handler_mod.HandlerFn) !void {
        try self.add("GET", sub_path, h);
    }

    pub fn post(self: *RouteGroup, sub_path: []const u8, h: handler_mod.HandlerFn) !void {
        try self.add("POST", sub_path, h);
    }
};

/// Matches a request path against registered routes, returning the handler
/// and any extracted path parameters.
///
/// Route segments starting with `:` are treated as parameters. For example
/// `/users/:id` matches `/users/42` and extracts `id=42`.
pub fn match(a: Allocator, routes: []const Route, method: []const u8, path: []const u8) !?MatchResult {
    for (routes) |route| {
        if (!std.mem.eql(u8, route.method, method)) continue;

        if (tryMatch(a, route.path, path)) |params| {
            return .{ .handler = route.handler, .params = params };
        } else |_| {
            continue;
        }
    }
    return null;
}

/// Attempts to match a route pattern against a concrete path.
/// Returns extracted parameters on success.
fn tryMatch(a: Allocator, pattern: []const u8, path: []const u8) ![]const Param {
    var params: std.ArrayListUnmanaged(Param) = .empty;
    errdefer params.deinit(a);

    var pat_it = splitPath(pattern);
    var path_it = splitPath(path);

    while (true) {
        const pat_seg = pat_it.next();
        const path_seg = path_it.next();

        if (pat_seg == null and path_seg == null) break;
        if (pat_seg == null or path_seg == null) return error.NoMatch;

        const ps = pat_seg.?;
        const vs = path_seg.?;

        if (ps.len > 0 and ps[0] == ':') {
            try params.append(a, .{ .name = ps[1..], .value = vs });
        } else if (!std.mem.eql(u8, ps, vs)) {
            return error.NoMatch;
        }
    }

    const result = try a.dupe(Param, params.items);
    params.deinit(a);
    return result;
}

fn splitPath(path: []const u8) std.mem.SplitIterator(u8, .scalar) {
    const trimmed = std.mem.trim(u8, path, "/");
    return std.mem.splitScalar(u8, trimmed, '/');
}

// ── Tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

const dummy_handler = struct {
    fn handle(_: *handler_mod.Context) anyerror!void {}
}.handle;

const other_handler = struct {
    fn handle(ctx: *handler_mod.Context) anyerror!void {
        try ctx.respond("other", "text/plain");
    }
}.handle;

test "match: exact path" {
    const routes = [_]Route{
        .{ .method = "GET", .path = "/about", .handler = dummy_handler },
    };
    const result = try match(testing.allocator, &routes, "GET", "/about");
    try testing.expect(result != null);
    try testing.expectEqual(@as(usize, 0), result.?.params.len);
    testing.allocator.free(result.?.params);
}

test "match: path parameter extraction" {
    const routes = [_]Route{
        .{ .method = "GET", .path = "/users/:id", .handler = dummy_handler },
    };
    const result = try match(testing.allocator, &routes, "GET", "/users/42");
    try testing.expect(result != null);
    try testing.expectEqual(@as(usize, 1), result.?.params.len);
    try testing.expectEqualStrings("id", result.?.params[0].name);
    try testing.expectEqualStrings("42", result.?.params[0].value);
    testing.allocator.free(result.?.params);
}

test "match: method dispatch" {
    const routes = [_]Route{
        .{ .method = "GET", .path = "/items", .handler = dummy_handler },
        .{ .method = "POST", .path = "/items", .handler = other_handler },
    };

    const get_result = try match(testing.allocator, &routes, "GET", "/items");
    try testing.expect(get_result != null);
    try testing.expect(get_result.?.handler == dummy_handler);
    testing.allocator.free(get_result.?.params);

    const post_result = try match(testing.allocator, &routes, "POST", "/items");
    try testing.expect(post_result != null);
    try testing.expect(post_result.?.handler == other_handler);
    testing.allocator.free(post_result.?.params);
}

test "match: no match returns null" {
    const routes = [_]Route{
        .{ .method = "GET", .path = "/about", .handler = dummy_handler },
    };
    const result = try match(testing.allocator, &routes, "GET", "/contact");
    try testing.expect(result == null);
}

test "match: wrong method returns null" {
    const routes = [_]Route{
        .{ .method = "POST", .path = "/submit", .handler = dummy_handler },
    };
    const result = try match(testing.allocator, &routes, "GET", "/submit");
    try testing.expect(result == null);
}

test "match: multiple parameters" {
    const routes = [_]Route{
        .{ .method = "GET", .path = "/posts/:year/:slug", .handler = dummy_handler },
    };
    const result = try match(testing.allocator, &routes, "GET", "/posts/2026/hello");
    try testing.expect(result != null);
    try testing.expectEqual(@as(usize, 2), result.?.params.len);
    try testing.expectEqualStrings("year", result.?.params[0].name);
    try testing.expectEqualStrings("2026", result.?.params[0].value);
    try testing.expectEqualStrings("slug", result.?.params[1].name);
    try testing.expectEqualStrings("hello", result.?.params[1].value);
    testing.allocator.free(result.?.params);
}

test "RouteGroup: prefix applied to routes" {
    var group = RouteGroup.init(testing.allocator, "/api");
    defer {
        for (group.routes.items) |r| testing.allocator.free(@constCast(r.path));
        group.routes.deinit(testing.allocator);
    }

    try group.get("/users", dummy_handler);
    try group.post("/users", other_handler);

    try testing.expectEqual(@as(usize, 2), group.routes.items.len);
    try testing.expectEqualStrings("/api/users", group.routes.items[0].path);
    try testing.expectEqualStrings("GET", group.routes.items[0].method);
    try testing.expectEqualStrings("/api/users", group.routes.items[1].path);
    try testing.expectEqualStrings("POST", group.routes.items[1].method);
}
