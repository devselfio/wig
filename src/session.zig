const std = @import("std");

const Allocator = std.mem.Allocator;

pub const SessionStore = struct {
    ptr: *const anyopaque,
    loadFn: *const fn (*const anyopaque, []const u8) ?std.StringHashMap([]const u8),
    saveFn: *const fn (*const anyopaque, []const u8, std.StringHashMap([]const u8)) void,
    destroyFn: *const fn (*const anyopaque, []const u8) void,

    pub fn load(self: SessionStore, id: []const u8) ?std.StringHashMap([]const u8) {
        return self.loadFn(self.ptr, id);
    }

    pub fn save(self: SessionStore, id: []const u8, data: std.StringHashMap([]const u8)) void {
        return self.saveFn(self.ptr, id, data);
    }

    pub fn destroy(self: SessionStore, id: []const u8) void {
        return self.destroyFn(self.ptr, id);
    }
};

pub const MemoryStore = struct {
    allocator: Allocator,

    pub fn init(a: Allocator) MemoryStore {
        return .{ .allocator = a };
    }

    pub fn store(self: *const MemoryStore) SessionStore {
        _ = self;
        @panic("MemoryStore not implemented");
    }
};

/// Generates a cryptographically random session ID.
pub fn generateId() ![32]u8 {
    var buf: [32]u8 = undefined;
    std.crypto.random.bytes(&buf);
    return buf;
}

test "session: placeholder" {
    // Populated in Phase 11
}
