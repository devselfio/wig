const std = @import("std");

const Allocator = std.mem.Allocator;

pub const SessionStore = struct {
    ptr: *const anyopaque,
    load_fn: *const fn (*const anyopaque, []const u8) ?*std.StringHashMap([]const u8),
    save_fn: *const fn (*const anyopaque, []const u8, std.StringHashMap([]const u8)) anyerror!void,
    destroy_fn: *const fn (*const anyopaque, []const u8) void,

    pub fn load(self: SessionStore, id: []const u8) ?*std.StringHashMap([]const u8) {
        return self.load_fn(self.ptr, id);
    }

    pub fn save(self: SessionStore, id: []const u8, data: std.StringHashMap([]const u8)) !void {
        return self.save_fn(self.ptr, id, data);
    }

    pub fn destroy(self: SessionStore, id: []const u8) void {
        return self.destroy_fn(self.ptr, id);
    }
};

pub const MemoryStore = struct {
    allocator: Allocator,
    sessions: std.StringHashMap(std.StringHashMap([]const u8)),

    pub fn init(a: Allocator) MemoryStore {
        return .{
            .allocator = a,
            .sessions = std.StringHashMap(std.StringHashMap([]const u8)).init(a),
        };
    }

    pub fn deinit(self: *MemoryStore) void {
        var it = self.sessions.iterator();
        while (it.next()) |entry| {
            var data = entry.value_ptr.*;
            data.deinit();
        }
        self.sessions.deinit();
    }

    pub fn loadSession(self: *const MemoryStore, id: []const u8) ?*std.StringHashMap([]const u8) {
        return @constCast(&self.sessions).getPtr(id);
    }

    pub fn saveSession(self: *MemoryStore, id: []const u8, data: std.StringHashMap([]const u8)) !void {
        if (self.sessions.getPtr(id)) |old| old.deinit();
        try self.sessions.put(id, data);
    }

    pub fn destroySession(self: *MemoryStore, id: []const u8) void {
        if (self.sessions.fetchRemove(id)) |kv| {
            var data = kv.value;
            data.deinit();
        }
    }

    pub fn store(self: *MemoryStore) SessionStore {
        return .{
            .ptr = @ptrCast(self),
            .load_fn = @ptrCast(&struct {
                fn load(ptr: *const MemoryStore, id: []const u8) ?*std.StringHashMap([]const u8) {
                    return ptr.loadSession(id);
                }
            }.load),
            .save_fn = @ptrCast(&struct {
                fn save(ptr: *MemoryStore, id: []const u8, data: std.StringHashMap([]const u8)) anyerror!void {
                    try ptr.saveSession(id, data);
                }
            }.save),
            .destroy_fn = @ptrCast(&struct {
                fn destroy(ptr: *MemoryStore, id: []const u8) void {
                    ptr.destroySession(id);
                }
            }.destroy),
        };
    }
};

/// Generates a cryptographically random session ID as a hex string.
pub fn generateId(a: Allocator, io: std.Io) ![]const u8 {
    var buf: [16]u8 = undefined;
    const io_source = std.Random.IoSource{ .io = io };
    const random = io_source.interface();
    std.Random.bytes(random, &buf);
    const hex = std.fmt.bytesToHex(buf, .lower);
    return try a.dupe(u8, &hex);
}

/// Parses a cookie header string and returns the value for the given name.
pub fn parseCookie(header: []const u8, name: []const u8) ?[]const u8 {
    var it = std.mem.splitSequence(u8, header, "; ");
    while (it.next()) |pair| {
        const trimmed = std.mem.trim(u8, pair, " ");
        if (std.mem.indexOfScalar(u8, trimmed, '=')) |eq| {
            const key = std.mem.trim(u8, trimmed[0..eq], " ");
            if (std.mem.eql(u8, key, name)) {
                return std.mem.trim(u8, trimmed[eq + 1 ..], " ");
            }
        }
    }
    return null;
}

/// Formats a Set-Cookie header value with secure defaults.
pub fn formatSetCookie(a: Allocator, name: []const u8, value: []const u8) ![]const u8 {
    return try std.fmt.allocPrint(
        a,
        "{s}={s}; Path=/; HttpOnly; SameSite=Strict; Secure",
        .{ name, value },
    );
}

// ── Tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

test "generateId: produces 32-char hex string" {
    const id = try generateId(testing.allocator, std.testing.io);
    defer testing.allocator.free(id);
    try testing.expectEqual(@as(usize, 32), id.len);

    for (id) |c| {
        try testing.expect(std.ascii.isHex(c));
    }
}

test "generateId: unique across calls" {
    const id1 = try generateId(testing.allocator, std.testing.io);
    defer testing.allocator.free(id1);
    const id2 = try generateId(testing.allocator, std.testing.io);
    defer testing.allocator.free(id2);
    try testing.expect(!std.mem.eql(u8, id1, id2));
}

test "MemoryStore: save and load" {
    var ms = MemoryStore.init(testing.allocator);
    defer ms.deinit();

    var data = std.StringHashMap([]const u8).init(testing.allocator);
    try data.put("user", "alice");
    try ms.saveSession("sess1", data);

    const loaded = ms.loadSession("sess1");
    try testing.expect(loaded != null);
    try testing.expectEqualStrings("alice", loaded.?.*.get("user").?);
}

test "MemoryStore: destroy removes session" {
    var ms = MemoryStore.init(testing.allocator);
    defer ms.deinit();

    var data = std.StringHashMap([]const u8).init(testing.allocator);
    try data.put("key", "val");
    try ms.saveSession("sess2", data);

    ms.destroySession("sess2");
    try testing.expect(ms.loadSession("sess2") == null);
}

test "MemoryStore: load missing session returns null" {
    var ms = MemoryStore.init(testing.allocator);
    defer ms.deinit();

    try testing.expect(ms.loadSession("nonexistent") == null);
}

test "parseCookie: extracts cookie value" {
    const header = "session=abc123; theme=dark; lang=en";
    try testing.expectEqualStrings("abc123", parseCookie(header, "session").?);
    try testing.expectEqualStrings("dark", parseCookie(header, "theme").?);
    try testing.expectEqualStrings("en", parseCookie(header, "lang").?);
    try testing.expect(parseCookie(header, "missing") == null);
}

test "parseCookie: single cookie" {
    const header = "id=xyz";
    try testing.expectEqualStrings("xyz", parseCookie(header, "id").?);
}

test "formatSetCookie: includes secure flags" {
    const cookie = try formatSetCookie(testing.allocator, "session", "abc");
    defer testing.allocator.free(cookie);
    try testing.expect(std.mem.indexOf(u8, cookie, "HttpOnly") != null);
    try testing.expect(std.mem.indexOf(u8, cookie, "Secure") != null);
    try testing.expect(std.mem.indexOf(u8, cookie, "SameSite=Strict") != null);
    try testing.expect(std.mem.startsWith(u8, cookie, "session=abc"));
}
