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

        if (patterns_map.count() == 0) continue;

        const path = try std.fmt.allocPrint(ba, "styles.{s}.patterns", .{sc.name});
        try style_ctx.putAt(path, .{ .map = patterns_map });
    }
}
