const std = @import("std");
const comb = @import("comb");
const toupee = @import("toupee");
const config = @import("config.zig");
const context_mod = @import("context.zig");

const Allocator = std.mem.Allocator;
const fs = std.fs;
const ValueMap = std.StringArrayHashMapUnmanaged(toupee.Value);

/// Loads `styles/{style}/patterns/{category}/*.yaml` and merges into `style_ctx` at
/// `styles.{style}.patterns` as a nested map: `{category}.{stem}` → manifest value.
///
/// Each category map also receives an `items` key containing a list of all
/// patterns in that category (each augmented with an `id` field from the stem).
/// This enables `t-for` iteration via Toupee's map-with-items fallback while
/// preserving direct access by stem name.
pub fn loadIntoContext(
    ba: Allocator,
    abs_root: []const u8,
    style_cfgs: []config.StyleConfig,
    style_ctx: *toupee.Context,
) !void {
    for (style_cfgs) |sc| {
        const patterns_root_path = try fs.path.join(ba, &.{ abs_root, "styles", sc.name, "patterns" });

        var pdir = fs.openDirAbsolute(patterns_root_path, .{ .iterate = true }) catch continue;
        defer pdir.close();

        var patterns_map: ValueMap = .{};

        var cat_it = pdir.iterate();
        while (try cat_it.next()) |entry| {
            if (entry.kind != .directory) continue;

            var cat_dir = pdir.openDir(entry.name, .{ .iterate = true }) catch continue;
            defer cat_dir.close();

            const cat_key = try ba.dupe(u8, entry.name);

            var fit = cat_dir.iterate();
            while (try fit.next()) |fe| {
                if (fe.kind != .file) continue;
                const ext = fs.path.extension(fe.name);
                if (!std.mem.eql(u8, ext, ".yaml") and !std.mem.eql(u8, ext, ".yml")) continue;

                const stem = fe.name[0 .. fe.name.len - ext.len];
                const stem_key = try ba.dupe(u8, stem);

                // Keep file bytes and comb parse alive for the build: `combToToupee` borrows string
                // slices from the parse tree (and source), and Toupee values must stay valid through render.
                const contents = cat_dir.readFileAlloc(ba, fe.name, 1024 * 1024) catch continue;
                const parsed = comb.parse(ba, contents) catch continue;
                const tv = try context_mod.combToToupee(ba, parsed.value);

                const gop = try patterns_map.getOrPut(ba, cat_key);
                if (!gop.found_existing) {
                    gop.value_ptr.* = .{ .map = ValueMap{} };
                }
                switch (gop.value_ptr.*) {
                    .map => |*inner| {
                        try inner.put(ba, stem_key, tv);
                    },
                    else => return error.PatternCategoryNotMap,
                }
            }
        }

        // Build `items` list per category for t-for iteration.
        var map_it = patterns_map.iterator();
        while (map_it.next()) |cat_entry| {
            switch (cat_entry.value_ptr.*) {
                .map => |*inner| {
                    var items = std.ArrayListUnmanaged(toupee.Value){};
                    var stem_it = inner.iterator();
                    while (stem_it.next()) |stem_entry| {
                        var item_map = switch (stem_entry.value_ptr.*) {
                            .map => |m| try cloneMap(ba, m),
                            else => ValueMap{},
                        };
                        try item_map.put(ba, "id", .{ .string = stem_entry.key_ptr.* });
                        try items.append(ba, .{ .map = item_map });
                    }
                    try inner.put(ba, "items", .{ .list = try ba.dupe(toupee.Value, items.items) });
                },
                else => {},
            }
        }

        if (patterns_map.count() == 0) continue;

        // Build flat `all` list combining every category's items with a `category` field.
        var all = std.ArrayListUnmanaged(toupee.Value){};
        var all_it = patterns_map.iterator();
        while (all_it.next()) |cat_entry| {
            switch (cat_entry.value_ptr.*) {
                .map => |inner| {
                    const cat_items = inner.get("items") orelse continue;
                    switch (cat_items) {
                        .list => |list| {
                            for (list) |item| {
                                switch (item) {
                                    .map => |m| {
                                        var augmented = try cloneMap(ba, m);
                                        try augmented.put(ba, "category", .{ .string = cat_entry.key_ptr.* });
                                        try all.append(ba, .{ .map = augmented });
                                    },
                                    else => try all.append(ba, item),
                                }
                            }
                        },
                        else => {},
                    }
                },
                else => {},
            }
        }
        try patterns_map.put(ba, "all", .{ .list = try ba.dupe(toupee.Value, all.items) });

        const path = try std.fmt.allocPrint(ba, "styles.{s}.patterns", .{sc.name});
        try style_ctx.putAt(path, .{ .map = patterns_map });
    }
}

fn cloneMap(a: Allocator, src: ValueMap) !ValueMap {
    var dst: ValueMap = .{};
    var it = src.iterator();
    while (it.next()) |entry| {
        try dst.put(a, entry.key_ptr.*, entry.value_ptr.*);
    }
    return dst;
}
