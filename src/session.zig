const std = @import("std");

const Allocator = std.mem.Allocator;

pub const SessionStore = struct {
    ptr: *const anyopaque,
    load_fn: *const fn (*const anyopaque, []const u8) ?std.StringHashMap([]const u8),
    save_fn: *const fn (*const anyopaque, []const u8, std.StringHashMap([]const u8)) void,
    destroy_fn: *const fn (*const anyopaque, []const u8) void,

    pub fn load(self: SessionStore, id: []const u8) ?std.StringHashMap([]const u8) {
        return self.load_fn(self.ptr, id);
    }

    pub fn save(self: SessionStore, id: []const u8, data: std.StringHashMap([]const u8)) void {
        return self.save_fn(self.ptr, id, data);
    }

    pub fn destroy(self: SessionStore, id: []const u8) void {
        return self.destroy_fn(self.ptr, id);
    }
};

pub const MemoryStore = struct {
    allocator: Allocator,

    pub fn init(a: Allocator) MemoryStore {
        return .{ .allocator = a };
    }

    pub fn store(self: *const MemoryStore) !SessionStore {
        _ = self;
        return error.NotImplemented;
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
