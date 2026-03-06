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

/// Matches a request path against registered routes.
pub fn match(routes: []const Route, method: []const u8, path: []const u8) ?MatchResult {
    _ = routes;
    _ = method;
    _ = path;
    return null;
}

test "router: placeholder" {
    // Populated in Phase 11
}
