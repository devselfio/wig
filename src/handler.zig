const std = @import("std");

const Allocator = std.mem.Allocator;

pub const HandlerFn = *const fn (*Context) anyerror!void;
pub const MiddlewareFn = *const fn (*Context, *Chain) anyerror!void;

pub const Chain = struct {
    middleware: []const MiddlewareFn,
    index: usize = 0,
    final_handler: HandlerFn,

    pub fn next(self: *Chain, ctx: *Context) !void {
        if (self.index < self.middleware.len) {
            const mw = self.middleware[self.index];
            self.index += 1;
            try mw(ctx, self);
        } else {
            try self.final_handler(ctx);
        }
    }
};

pub const Context = struct {
    allocator: Allocator,

    pub fn respond(self: *Context, body: []const u8, content_type: []const u8) !void {
        _ = self;
        _ = body;
        _ = content_type;
        return error.NotImplemented;
    }

    pub fn redirect(self: *Context, location: []const u8) !void {
        _ = self;
        _ = location;
        return error.NotImplemented;
    }
};

test "handler: placeholder" {
    // Populated in Phase 11
}
