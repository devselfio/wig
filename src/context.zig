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

test "combToToupee: basic types" {
    // Placeholder for Phase 2.7
}

test "jsonToToupee: basic types" {
    // Placeholder for Phase 2.7
}
