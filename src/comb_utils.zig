const std = @import("std");
const comb = @import("comb");

/// Extracts a string value from a comb.Value object entry.
pub fn getString(val: comb.Value, key: []const u8) ?[]const u8 {
    const v = val.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

/// Extracts a boolean value from a comb.Value object entry.
pub fn getBool(val: comb.Value, key: []const u8) ?bool {
    const v = val.get(key) orelse return null;
    return switch (v) {
        .boolean => |b| b,
        else => null,
    };
}

/// Extracts an integer value from a comb.Value object entry.
pub fn getInt(val: comb.Value, key: []const u8) ?i64 {
    const v = val.get(key) orelse return null;
    return switch (v) {
        .integer => |i| i,
        else => null,
    };
}

/// Extracts an array value from a comb.Value object entry.
pub fn getList(val: comb.Value, key: []const u8) ?[]const comb.Value {
    const v = val.get(key) orelse return null;
    return switch (v) {
        .array => |a| a,
        else => null,
    };
}

/// Extracts a nested object value from a comb.Value object entry.
pub fn getObject(val: comb.Value, key: []const u8) ?comb.Value {
    const v = val.get(key) orelse return null;
    return switch (v) {
        .object => v,
        else => null,
    };
}

// ── Tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

test "getString: present" {
    var p = try comb.parse(testing.allocator, "name: Alice\n");
    defer p.deinit();
    try testing.expectEqualStrings("Alice", getString(p.value, "name").?);
}

test "getString: missing" {
    var p = try comb.parse(testing.allocator, "name: Alice\n");
    defer p.deinit();
    try testing.expect(getString(p.value, "age") == null);
}

test "getString: wrong type" {
    var p = try comb.parse(testing.allocator, "count: 5\n");
    defer p.deinit();
    try testing.expect(getString(p.value, "count") == null);
}

test "getBool: true" {
    var p = try comb.parse(testing.allocator, "draft: true\n");
    defer p.deinit();
    try testing.expect(getBool(p.value, "draft").? == true);
}

test "getBool: false" {
    var p = try comb.parse(testing.allocator, "draft: false\n");
    defer p.deinit();
    try testing.expect(getBool(p.value, "draft").? == false);
}

test "getBool: missing" {
    var p = try comb.parse(testing.allocator, "title: Hi\n");
    defer p.deinit();
    try testing.expect(getBool(p.value, "draft") == null);
}

test "getInt: present" {
    var p = try comb.parse(testing.allocator, "size: 10\n");
    defer p.deinit();
    try testing.expectEqual(@as(i64, 10), getInt(p.value, "size").?);
}

test "getList: present" {
    var p = try comb.parse(testing.allocator,
        \\tags:
        \\  - zig
        \\  - web
        \\
    );
    defer p.deinit();
    const list = getList(p.value, "tags").?;
    try testing.expectEqual(@as(usize, 2), list.len);
}

test "getObject: present" {
    var p = try comb.parse(testing.allocator,
        \\meta:
        \\  name: wig
        \\
    );
    defer p.deinit();
    const obj = getObject(p.value, "meta").?;
    try testing.expectEqualStrings("wig", getString(obj, "name").?);
}
