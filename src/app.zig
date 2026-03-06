const std = @import("std");

const Allocator = std.mem.Allocator;
const handler_mod = @import("handler.zig");

pub const App = struct {
    allocator: Allocator,

    pub fn init(a: Allocator) App {
        return .{ .allocator = a };
    }

    pub fn deinit(self: *App) void {
        _ = self;
    }

    pub fn get(self: *App, path: []const u8, h: handler_mod.HandlerFn) void {
        _ = self;
        _ = path;
        _ = h;
    }

    pub fn post(self: *App, path: []const u8, h: handler_mod.HandlerFn) void {
        _ = self;
        _ = path;
        _ = h;
    }

    pub fn use(self: *App, m: handler_mod.MiddlewareFn) void {
        _ = self;
        _ = m;
    }

    pub fn listen(self: *App, port: u16) !void {
        _ = self;
        _ = port;
        return error.NotImplemented;
    }
};

test "app: placeholder" {
    // Populated in Phase 11
}
