const std = @import("std");
const comb = @import("comb");
const toupee = @import("toupee");

const Allocator = std.mem.Allocator;

const ValueMap = std.StringArrayHashMapUnmanaged(toupee.Value);

/// Translates a Comb YAML value to a Toupee template value.
pub fn combToToupee(a: Allocator, val: comb.Value) !toupee.Value {
    return switch (val) {
        .string => |s| .{ .string = s },
        .integer => |i| .{ .integer = i },
        .float => |f| .{ .float = f },
        .boolean => |b| .{ .boolean = b },
        .null_val => .nil,
        .array => |arr| blk: {
            const items = try a.alloc(toupee.Value, arr.len);
            for (arr, 0..) |item, idx| {
                items[idx] = try combToToupee(a, item);
            }
            break :blk .{ .list = items };
        },
        .object => |entries| blk: {
            var map: ValueMap = .{};
            for (entries) |entry| {
                const key = switch (entry.key) {
                    .string => |s| s,
                    else => continue,
                };
                const v = try combToToupee(a, entry.value);
                try map.put(a, key, v);
            }
            break :blk .{ .map = map };
        },
        else => .nil,
    };
}

/// Translates a std.json.Value to a Toupee template value.
pub fn jsonToToupee(a: Allocator, val: std.json.Value) !toupee.Value {
    return switch (val) {
        .string => |s| .{ .string = s },
        .integer => |i| .{ .integer = i },
        .float => |f| .{ .float = f },
        .bool => |b| .{ .boolean = b },
        .null => .nil,
        .array => |arr| blk: {
            const items = try a.alloc(toupee.Value, arr.items.len);
            for (arr.items, 0..) |item, idx| {
                items[idx] = try jsonToToupee(a, item);
            }
            break :blk .{ .list = items };
        },
        .object => |obj| blk: {
            var map: ValueMap = .{};
            var it = obj.iterator();
            while (it.next()) |entry| {
                const v = try jsonToToupee(a, entry.value_ptr.*);
                try map.put(a, entry.key_ptr.*, v);
            }
            break :blk .{ .map = map };
        },
        .number_string => |s| .{ .string = s },
    };
}

const testing = std.testing;

fn expectToupeeStr(val: toupee.Value, expected: []const u8) !void {
    switch (val) {
        .string => |s| try testing.expectEqualStrings(expected, s),
        else => return error.TestExpectedEqual,
    }
}

fn expectToupeeInt(val: toupee.Value, expected: i64) !void {
    switch (val) {
        .integer => |i| try testing.expectEqual(expected, i),
        else => return error.TestExpectedEqual,
    }
}

fn expectToupeeFloat(val: toupee.Value, expected: f64) !void {
    switch (val) {
        .float => |f| try testing.expectEqual(expected, f),
        else => return error.TestExpectedEqual,
    }
}

fn expectToupeeBool(val: toupee.Value, expected: bool) !void {
    switch (val) {
        .boolean => |b| try testing.expectEqual(expected, b),
        else => return error.TestExpectedEqual,
    }
}

fn expectToupeeNil(val: toupee.Value) !void {
    switch (val) {
        .nil => {},
        else => return error.TestExpectedEqual,
    }
}

fn toupeeMapGet(val: toupee.Value, key: []const u8) ?toupee.Value {
    const map = switch (val) {
        .map => |m| m,
        else => return null,
    };
    return map.get(key);
}

fn toupeeListItems(val: toupee.Value) ?[]const toupee.Value {
    return switch (val) {
        .list => |l| l,
        else => null,
    };
}

// ── combToToupee tests ──────────────────────────────────────────────────

test "combToToupee: string" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try combToToupee(arena.allocator(), .{ .string = "hello" });
    try expectToupeeStr(result, "hello");
}

test "combToToupee: empty string" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try combToToupee(arena.allocator(), .{ .string = "" });
    try expectToupeeStr(result, "");
}

test "combToToupee: integer" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try combToToupee(arena.allocator(), .{ .integer = 42 });
    try expectToupeeInt(result, 42);
}

test "combToToupee: negative integer" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try combToToupee(arena.allocator(), .{ .integer = -7 });
    try expectToupeeInt(result, -7);
}

test "combToToupee: zero" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try combToToupee(arena.allocator(), .{ .integer = 0 });
    try expectToupeeInt(result, 0);
}

test "combToToupee: float" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try combToToupee(arena.allocator(), .{ .float = 3.14 });
    try expectToupeeFloat(result, 3.14);
}

test "combToToupee: negative float" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try combToToupee(arena.allocator(), .{ .float = -1.5 });
    try expectToupeeFloat(result, -1.5);
}

test "combToToupee: boolean true" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try combToToupee(arena.allocator(), .{ .boolean = true });
    try expectToupeeBool(result, true);
}

test "combToToupee: boolean false" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try combToToupee(arena.allocator(), .{ .boolean = false });
    try expectToupeeBool(result, false);
}

test "combToToupee: null" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try combToToupee(arena.allocator(), .{ .null_val = {} });
    try expectToupeeNil(result);
}

test "combToToupee: array" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const items = [_]comb.Value{
        .{ .string = "a" },
        .{ .integer = 1 },
        .{ .boolean = true },
    };
    const result = try combToToupee(a, .{ .array = &items });
    const list = toupeeListItems(result) orelse return error.TestExpectedEqual;
    try testing.expectEqual(@as(usize, 3), list.len);
    try expectToupeeStr(list[0], "a");
    try expectToupeeInt(list[1], 1);
    try expectToupeeBool(list[2], true);
}

test "combToToupee: empty array" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try combToToupee(arena.allocator(), .{ .array = &.{} });
    const list = toupeeListItems(result) orelse return error.TestExpectedEqual;
    try testing.expectEqual(@as(usize, 0), list.len);
}

test "combToToupee: object" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const entries = [_]comb.Entry{
        .{ .key = .{ .string = "name" }, .value = .{ .string = "Alice" } },
        .{ .key = .{ .string = "age" }, .value = .{ .integer = 30 } },
    };
    const result = try combToToupee(a, .{ .object = &entries });
    try expectToupeeStr(toupeeMapGet(result, "name") orelse return error.TestExpectedEqual, "Alice");
    try expectToupeeInt(toupeeMapGet(result, "age") orelse return error.TestExpectedEqual, 30);
}

test "combToToupee: empty object" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try combToToupee(arena.allocator(), .{ .object = &.{} });
    const map = switch (result) {
        .map => |m| m,
        else => return error.TestExpectedEqual,
    };
    try testing.expectEqual(@as(usize, 0), map.count());
}

test "combToToupee: object skips non-string keys" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const entries = [_]comb.Entry{
        .{ .key = .{ .integer = 42 }, .value = .{ .string = "skipped" } },
        .{ .key = .{ .string = "kept" }, .value = .{ .string = "value" } },
    };
    const result = try combToToupee(a, .{ .object = &entries });
    const map = switch (result) {
        .map => |m| m,
        else => return error.TestExpectedEqual,
    };
    try testing.expectEqual(@as(usize, 1), map.count());
    try expectToupeeStr(map.get("kept") orelse return error.TestExpectedEqual, "value");
}

test "combToToupee: nested structure" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var parsed = try comb.parse(a,
        \\site:
        \\  title: My Site
        \\  tags:
        \\    - zig
        \\    - web
        \\  meta:
        \\    version: 2
        \\    active: true
    );
    defer parsed.deinit();

    const result = try combToToupee(a, parsed.value);
    const site = toupeeMapGet(result, "site") orelse return error.TestExpectedEqual;
    try expectToupeeStr(toupeeMapGet(site, "title") orelse return error.TestExpectedEqual, "My Site");

    const tags = toupeeListItems(toupeeMapGet(site, "tags") orelse return error.TestExpectedEqual) orelse return error.TestExpectedEqual;
    try testing.expectEqual(@as(usize, 2), tags.len);
    try expectToupeeStr(tags[0], "zig");
    try expectToupeeStr(tags[1], "web");

    const meta = toupeeMapGet(site, "meta") orelse return error.TestExpectedEqual;
    try expectToupeeInt(toupeeMapGet(meta, "version") orelse return error.TestExpectedEqual, 2);
    try expectToupeeBool(toupeeMapGet(meta, "active") orelse return error.TestExpectedEqual, true);
}

test "combToToupee: binary becomes nil" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try combToToupee(arena.allocator(), .{ .binary = "data" });
    try expectToupeeNil(result);
}

test "combToToupee: tagged becomes nil" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const inner = comb.Value{ .string = "value" };
    const result = try combToToupee(arena.allocator(), .{ .tagged = .{ .tag = "!custom", .value = &inner } });
    try expectToupeeNil(result);
}

// ── jsonToToupee tests ──────────────────────────────────────────────────

test "jsonToToupee: string" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try jsonToToupee(arena.allocator(), .{ .string = "world" });
    try expectToupeeStr(result, "world");
}

test "jsonToToupee: integer" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try jsonToToupee(arena.allocator(), .{ .integer = 99 });
    try expectToupeeInt(result, 99);
}

test "jsonToToupee: float" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try jsonToToupee(arena.allocator(), .{ .float = 2.718 });
    try expectToupeeFloat(result, 2.718);
}

test "jsonToToupee: bool true" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try jsonToToupee(arena.allocator(), .{ .bool = true });
    try expectToupeeBool(result, true);
}

test "jsonToToupee: bool false" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try jsonToToupee(arena.allocator(), .{ .bool = false });
    try expectToupeeBool(result, false);
}

test "jsonToToupee: null" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try jsonToToupee(arena.allocator(), .null);
    try expectToupeeNil(result);
}

test "jsonToToupee: number_string" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try jsonToToupee(arena.allocator(), .{ .number_string = "1e308" });
    try expectToupeeStr(result, "1e308");
}

test "jsonToToupee: array" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var arr = std.json.Array.init(a);
    try arr.append(.{ .string = "x" });
    try arr.append(.{ .integer = 5 });

    const result = try jsonToToupee(a, .{ .array = arr });
    const list = toupeeListItems(result) orelse return error.TestExpectedEqual;
    try testing.expectEqual(@as(usize, 2), list.len);
    try expectToupeeStr(list[0], "x");
    try expectToupeeInt(list[1], 5);
}

test "jsonToToupee: empty array" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const arr = std.json.Array.init(a);
    const result = try jsonToToupee(a, .{ .array = arr });
    const list = toupeeListItems(result) orelse return error.TestExpectedEqual;
    try testing.expectEqual(@as(usize, 0), list.len);
}

test "jsonToToupee: object" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var obj = std.json.ObjectMap.init(a);
    try obj.put("color", .{ .string = "red" });
    try obj.put("count", .{ .integer = 3 });

    const result = try jsonToToupee(a, .{ .object = obj });
    try expectToupeeStr(toupeeMapGet(result, "color") orelse return error.TestExpectedEqual, "red");
    try expectToupeeInt(toupeeMapGet(result, "count") orelse return error.TestExpectedEqual, 3);
}

test "jsonToToupee: empty object" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const obj = std.json.ObjectMap.init(a);
    const result = try jsonToToupee(a, .{ .object = obj });
    const map = switch (result) {
        .map => |m| m,
        else => return error.TestExpectedEqual,
    };
    try testing.expectEqual(@as(usize, 0), map.count());
}

test "jsonToToupee: nested structure" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var inner = std.json.ObjectMap.init(a);
    try inner.put("x", .{ .integer = 10 });

    var arr = std.json.Array.init(a);
    try arr.append(.{ .string = "item" });

    var outer = std.json.ObjectMap.init(a);
    try outer.put("nested", .{ .object = inner });
    try outer.put("items", .{ .array = arr });
    try outer.put("flag", .{ .bool = false });

    const result = try jsonToToupee(a, .{ .object = outer });

    const nested = toupeeMapGet(result, "nested") orelse return error.TestExpectedEqual;
    try expectToupeeInt(toupeeMapGet(nested, "x") orelse return error.TestExpectedEqual, 10);

    const items = toupeeListItems(toupeeMapGet(result, "items") orelse return error.TestExpectedEqual) orelse return error.TestExpectedEqual;
    try testing.expectEqual(@as(usize, 1), items.len);
    try expectToupeeStr(items[0], "item");

    try expectToupeeBool(toupeeMapGet(result, "flag") orelse return error.TestExpectedEqual, false);
}

// ── Cross-format consistency ────────────────────────────────────────────

test "comb and json produce same toupee structure for equivalent data" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Same data via Comb YAML
    var parsed_yaml = try comb.parse(a,
        \\title: Hello
        \\count: 5
        \\active: true
    );
    defer parsed_yaml.deinit();
    const from_comb = try combToToupee(a, parsed_yaml.value);

    // Same data via JSON
    var json_obj = std.json.ObjectMap.init(a);
    try json_obj.put("title", .{ .string = "Hello" });
    try json_obj.put("count", .{ .integer = 5 });
    try json_obj.put("active", .{ .bool = true });
    const from_json = try jsonToToupee(a, .{ .object = json_obj });

    // Both should produce equivalent toupee maps
    try expectToupeeStr(toupeeMapGet(from_comb, "title").?, "Hello");
    try expectToupeeStr(toupeeMapGet(from_json, "title").?, "Hello");
    try expectToupeeInt(toupeeMapGet(from_comb, "count").?, 5);
    try expectToupeeInt(toupeeMapGet(from_json, "count").?, 5);
    try expectToupeeBool(toupeeMapGet(from_comb, "active").?, true);
    try expectToupeeBool(toupeeMapGet(from_json, "active").?, true);
}
