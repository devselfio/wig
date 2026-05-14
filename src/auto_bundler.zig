const std = @import("std");
const toupee = @import("toupee");
const pattern_loader = @import("pattern_loader.zig");

const Allocator = std.mem.Allocator;
const fs = std.fs;

const LoadResult = pattern_loader.LoadResult;

pub const AutoBundleResult = struct {
    path: []const u8,
    hash: []const u8,
    content: []const u8,
};

/// Generates a single auto-bundled CSS file from resolved patterns.
///
/// 1. Prepends `@layer` declaration with all CUBE categories
/// 2. For each category with CSS, wraps in `@layer {category} { ... }`
/// 3. Concatenates in CUBE CSS order
/// 4. Hashes with SHA-256 (truncated to 8 hex chars)
/// 5. Writes to `assets/css/styles/{style_name}.{hash}.css`
///
/// Returns the web path, hash, and content. Returns null if no patterns have CSS.
pub fn generateBundle(
    a: Allocator,
    style_name: []const u8,
    resolved: LoadResult,
    output_dir: fs.Dir,
) !?AutoBundleResult {
    var has_any_css = false;
    for (resolved.all) |p| {
        if (p.resources.contains("css")) {
            has_any_css = true;
            break;
        }
    }
    if (!has_any_css) return null;

    const content = try buildLayeredCss(a, resolved);

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(content);
    const digest = hasher.finalResult();
    const hex = std.fmt.bytesToHex(digest[0..4].*, .lower);
    const hash = try a.dupe(u8, &hex);

    const filename = try std.fmt.allocPrint(a, "{s}.{s}.css", .{ style_name, hash });
    const subdir = "assets/css/styles";
    output_dir.makePath(subdir) catch {};

    const out_path = try std.fmt.allocPrint(a, "{s}/{s}", .{ subdir, filename });
    var out_file = try output_dir.createFile(out_path, .{});
    defer out_file.close();
    try out_file.writeAll(content);

    const web_path = try std.fmt.allocPrint(a, "/{s}", .{out_path});

    return .{
        .path = web_path,
        .hash = hash,
        .content = content,
    };
}

/// Builds the complete `@layer`-wrapped CSS content from resolved patterns.
pub fn buildLayeredCss(a: Allocator, resolved: LoadResult) ![]const u8 {
    var parts = std.ArrayListUnmanaged([]const u8){};

    try parts.append(a, "@layer tokens, resets, globals, fonts, compositions, utilities, blocks, exceptions;\n");

    for (resolved.categories) |group| {
        var cat_css = std.ArrayListUnmanaged([]const u8){};
        for (group.patterns) |p| {
            if (p.resources.get("css")) |entry| {
                const trimmed = std.mem.trim(u8, entry.content, " \t\r\n");
                if (trimmed.len > 0) {
                    try cat_css.append(a, trimmed);
                }
            }
        }

        if (cat_css.items.len == 0) continue;

        try parts.append(a, try std.fmt.allocPrint(a, "\n@layer {s} {{\n", .{group.name}));

        for (cat_css.items, 0..) |css_block, i| {
            if (i > 0) try parts.append(a, "\n");
            try parts.append(a, css_block);
            try parts.append(a, "\n");
        }

        try parts.append(a, "}\n");
    }

    return std.mem.join(a, "", parts.items);
}

// ── Tests ───────────────────────────────────────────────────────────────

const testing = std.testing;
const ValueMap = std.StringArrayHashMapUnmanaged(toupee.Value);
const pattern_parser = @import("pattern_parser.zig");

fn stubPattern(a: Allocator, id: []const u8, category: []const u8, css: ?[]const u8) pattern_loader.Pattern {
    var meta = ValueMap{};
    meta.put(a, "name", .{ .string = id }) catch {};
    var resources = std.StringArrayHashMapUnmanaged(pattern_loader.ResourceEntry){};
    if (css) |c| resources.put(a, "css", .{
        .content = c,
        .rel_path = std.fmt.allocPrint(a, "{s}/{s}.css", .{ category, id }) catch "",
    }) catch {};
    return .{
        .id = id,
        .category = category,
        .slug = std.fmt.allocPrint(a, "{s}/{s}", .{ category, id }) catch id,
        .source_style = "test",
        .metadata = .{ .map = meta },
        .example = "",
        .variants = &.{},
        .resources = resources,
        .template_source = null,
        .file_paths = &.{},
    };
}

test "buildLayeredCss: single category" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const patterns = [_]pattern_loader.Pattern{
        stubPattern(a, "button", "blocks", ".button { display: flex; }"),
    };
    const groups = [_]pattern_loader.CategoryGroup{
        .{ .name = "blocks", .patterns = &patterns },
    };
    const result = LoadResult{
        .categories = &groups,
        .all = &patterns,
    };

    const css = try buildLayeredCss(a, result);

    try testing.expect(std.mem.startsWith(u8, css, "@layer tokens, resets, globals, fonts, compositions, utilities, blocks, exceptions;\n"));
    try testing.expect(std.mem.indexOf(u8, css, "@layer blocks {") != null);
    try testing.expect(std.mem.indexOf(u8, css, ".button { display: flex; }") != null);
}

test "buildLayeredCss: CUBE ordering preserved" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const block_p = [_]pattern_loader.Pattern{
        stubPattern(a, "button", "blocks", ".button {}"),
    };
    const reset_p = [_]pattern_loader.Pattern{
        stubPattern(a, "reset", "resets", "* { margin: 0; }"),
    };
    const groups = [_]pattern_loader.CategoryGroup{
        .{ .name = "resets", .patterns = &reset_p },
        .{ .name = "blocks", .patterns = &block_p },
    };
    const all = [_]pattern_loader.Pattern{
        stubPattern(a, "reset", "resets", "* { margin: 0; }"),
        stubPattern(a, "button", "blocks", ".button {}"),
    };
    const result = LoadResult{
        .categories = &groups,
        .all = &all,
    };

    const css = try buildLayeredCss(a, result);

    const reset_pos = std.mem.indexOf(u8, css, "@layer resets {") orelse return error.TestUnexpectedResult;
    const block_pos = std.mem.indexOf(u8, css, "@layer blocks {") orelse return error.TestUnexpectedResult;
    try testing.expect(reset_pos < block_pos);
}

test "buildLayeredCss: patterns without CSS are skipped" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const patterns = [_]pattern_loader.Pattern{
        stubPattern(a, "minimal", "blocks", null),
        stubPattern(a, "button", "blocks", ".button {}"),
    };
    const groups = [_]pattern_loader.CategoryGroup{
        .{ .name = "blocks", .patterns = &patterns },
    };
    const result = LoadResult{
        .categories = &groups,
        .all = &patterns,
    };

    const css = try buildLayeredCss(a, result);

    try testing.expect(std.mem.indexOf(u8, css, ".button {}") != null);
    try testing.expect(std.mem.indexOf(u8, css, "minimal") == null);
}

test "buildLayeredCss: empty categories omitted from layer blocks" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const patterns = [_]pattern_loader.Pattern{
        stubPattern(a, "reset", "resets", null),
    };
    const groups = [_]pattern_loader.CategoryGroup{
        .{ .name = "resets", .patterns = &patterns },
    };
    const result = LoadResult{
        .categories = &groups,
        .all = &patterns,
    };

    const css = try buildLayeredCss(a, result);

    try testing.expect(std.mem.startsWith(u8, css, "@layer tokens,"));
    try testing.expect(std.mem.indexOf(u8, css, "@layer resets {") == null);
}

test "generateBundle: writes file and returns path" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const patterns = [_]pattern_loader.Pattern{
        stubPattern(a, "button", "blocks", ".button { display: flex; }"),
    };
    const groups = [_]pattern_loader.CategoryGroup{
        .{ .name = "blocks", .patterns = &patterns },
    };
    const resolved = LoadResult{
        .categories = &groups,
        .all = &patterns,
    };

    const result = try generateBundle(a, "default", resolved, tmp.dir);
    try testing.expect(result != null);

    const r = result.?;
    try testing.expect(std.mem.startsWith(u8, r.path, "/assets/css/styles/default."));
    try testing.expect(std.mem.endsWith(u8, r.path, ".css"));
    try testing.expect(r.hash.len == 8);
    try testing.expect(std.mem.indexOf(u8, r.content, "@layer blocks {") != null);

    const file_path = r.path[1..];
    const on_disk = try tmp.dir.readFileAlloc(a, file_path, 64 * 1024);
    try testing.expectEqualStrings(r.content, on_disk);
}

test "generateBundle: returns null when no CSS" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const patterns = [_]pattern_loader.Pattern{
        stubPattern(a, "reset", "resets", null),
    };
    const groups = [_]pattern_loader.CategoryGroup{
        .{ .name = "resets", .patterns = &patterns },
    };
    const resolved = LoadResult{
        .categories = &groups,
        .all = &patterns,
    };

    const result = try generateBundle(a, "default", resolved, tmp.dir);
    try testing.expect(result == null);
}

test "buildLayeredCss: multiple patterns in same category" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const patterns = [_]pattern_loader.Pattern{
        stubPattern(a, "button", "blocks", ".button {}"),
        stubPattern(a, "tag", "blocks", ".tag {}"),
    };
    const groups = [_]pattern_loader.CategoryGroup{
        .{ .name = "blocks", .patterns = &patterns },
    };
    const result = LoadResult{
        .categories = &groups,
        .all = &patterns,
    };

    const css = try buildLayeredCss(a, result);

    try testing.expect(std.mem.indexOf(u8, css, ".button {}") != null);
    try testing.expect(std.mem.indexOf(u8, css, ".tag {}") != null);
    const count = std.mem.count(u8, css, "@layer blocks {");
    try testing.expectEqual(@as(usize, 1), count);
}
