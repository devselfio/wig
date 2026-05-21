const std = @import("std");
const toupee = @import("toupee");
const pattern_loader = @import("pattern_loader.zig");

const Allocator = std.mem.Allocator;

const LoadResult = pattern_loader.LoadResult;

pub const AutoBundleResult = struct {
    path: []const u8,
    hash: []const u8,
    content: []const u8,
};

/// Generates a single auto-bundled CSS file from resolved patterns.
///
/// 1. Prepends `@layer` declaration with all CUBE categories
/// 2. For each category with CSS, renders the raw CSS body through Toupee with a
///    per-consumer context (base style_ctx + `style` key pointing to this consumer's data)
/// 3. Wraps each category in `@layer {category} { ... }`
/// 4. Hashes with SHA-256 (truncated to 8 hex chars)
/// 5. Writes to `assets/css/styles/{style_name}.{hash}.css`
///
/// Returns the web path, hash, and content. Returns null if no patterns have CSS.
pub fn generateBundle(
    a: Allocator,
    io: std.Io,
    style_name: []const u8,
    resolved: LoadResult,
    output_dir: std.Io.Dir,
    style_ctx: *const toupee.Context,
) !?AutoBundleResult {
    var has_any_css = false;
    for (resolved.all) |p| {
        if (p.resources.contains("css")) {
            has_any_css = true;
            break;
        }
    }
    if (!has_any_css) return null;

    const content = try buildLayeredCss(a, style_name, resolved, style_ctx);

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(content);
    const digest = hasher.finalResult();
    const hex = std.fmt.bytesToHex(digest[0..4].*, .lower);
    const hash = try a.dupe(u8, &hex);

    const filename = try std.fmt.allocPrint(a, "{s}.{s}.css", .{ style_name, hash });
    const subdir = "assets/css/styles";
    std.Io.Dir.createDirPath(output_dir, io, subdir) catch {};

    const out_path = try std.fmt.allocPrint(a, "{s}/{s}", .{ subdir, filename });
    var out_file = try std.Io.Dir.createFile(output_dir, io, out_path, .{});
    defer out_file.close(io);
    try out_file.writeStreamingAll(io, content);

    const web_path = try std.fmt.allocPrint(a, "/{s}", .{out_path});

    return .{
        .path = web_path,
        .hash = hash,
        .content = content,
    };
}

/// Builds the complete `@layer`-wrapped CSS content from resolved patterns.
///
/// Each pattern's CSS body (stored raw after frontmatter stripping) is rendered
/// through Toupee with a per-consumer context. The context inherits `style_ctx`
/// and adds a top-level `style` key bound to the consuming style's data so that
/// templates like `<t-for pair in style.highlights.available>` work correctly
/// for each consumer independently.
pub fn buildLayeredCss(
    a: Allocator,
    style_name: []const u8,
    resolved: LoadResult,
    style_ctx: *const toupee.Context,
) ![]const u8 {
    // Build per-consumer context.
    var consumer_ctx = try toupee.Context.initFrom(a, style_ctx);
    const style_key = try std.fmt.allocPrint(a, "styles.{s}", .{style_name});
    if (style_ctx.resolve(style_key)) |style_val| {
        try consumer_ctx.put("style", style_val);
    }
    var resolver: toupee.Resolver = .{};

    var parts = std.ArrayListUnmanaged([]const u8).empty;

    try parts.append(a, "@layer tokens, resets, globals, fonts, compositions, utilities, blocks, exceptions;\n");

    for (resolved.categories) |group| {
        var cat_css = std.ArrayListUnmanaged([]const u8).empty;
        for (group.patterns) |p| {
            if (p.resources.get("css")) |entry| {
                const raw = std.mem.trim(u8, entry.content, " \t\r\n");
                if (raw.len == 0) continue;

                var sheet_ctx = try toupee.Context.initFrom(a, &consumer_ctx);
                if (entry.stylesheet_fm_overlay == .map) {
                    var o_it = entry.stylesheet_fm_overlay.map.iterator();
                    while (o_it.next()) |kv| {
                        try sheet_ctx.put(kv.key_ptr.*, kv.value_ptr.*);
                    }
                }

                const rendered = toupee.render(a, raw, &sheet_ctx, resolver.loader(), .{ .strict = false }) catch raw;
                const trimmed = std.mem.trim(u8, rendered, " \t\r\n");
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

    var ctx = toupee.Context.init(a);
    const css = try buildLayeredCss(a, "test", result, &ctx);

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

    var ctx = toupee.Context.init(a);
    const css = try buildLayeredCss(a, "test", result, &ctx);

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

    var ctx = toupee.Context.init(a);
    const css = try buildLayeredCss(a, "test", result, &ctx);

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

    var ctx = toupee.Context.init(a);
    const css = try buildLayeredCss(a, "test", result, &ctx);

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

    var ctx = toupee.Context.init(a);
    const result = try generateBundle(a, "default", resolved, tmp.dir, &ctx);
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

    var ctx = toupee.Context.init(a);
    const result = try generateBundle(a, "default", resolved, tmp.dir, &ctx);
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

    var ctx = toupee.Context.init(a);
    const css = try buildLayeredCss(a, "test", result, &ctx);

    try testing.expect(std.mem.indexOf(u8, css, ".button {}") != null);
    try testing.expect(std.mem.indexOf(u8, css, ".tag {}") != null);
    const count = std.mem.count(u8, css, "@layer blocks {");
    try testing.expectEqual(@as(usize, 1), count);
}

test "buildLayeredCss: per-consumer rendering uses consumer style context" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Build a style context with styles.myStyle.accent = "red"
    var style_data = std.StringArrayHashMapUnmanaged(toupee.Value){};
    try style_data.put(a, "accent", .{ .string = "red" });

    var styles_map = std.StringArrayHashMapUnmanaged(toupee.Value){};
    try styles_map.put(a, "myStyle", .{ .map = style_data });

    var base_ctx = toupee.Context.init(a);
    try base_ctx.put("styles", .{ .map = styles_map });

    // CSS template references the consumer's style.accent
    const patterns = [_]pattern_loader.Pattern{
        stubPattern(a, "colors", "tokens", ":root { --accent: <t-raw name=\"style.accent\" />; }"),
    };
    const groups = [_]pattern_loader.CategoryGroup{
        .{ .name = "tokens", .patterns = &patterns },
    };
    const result = LoadResult{
        .categories = &groups,
        .all = &patterns,
    };

    const css = try buildLayeredCss(a, "myStyle", result, &base_ctx);
    try testing.expect(std.mem.indexOf(u8, css, "--accent: red;") != null);
}

test "buildLayeredCss: per-consumer renders differently for two consumers" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Two consumers with different accent colors
    var style_a_data = std.StringArrayHashMapUnmanaged(toupee.Value){};
    try style_a_data.put(a, "accent", .{ .string = "blue" });
    var style_b_data = std.StringArrayHashMapUnmanaged(toupee.Value){};
    try style_b_data.put(a, "accent", .{ .string = "green" });

    var styles_map = std.StringArrayHashMapUnmanaged(toupee.Value){};
    try styles_map.put(a, "consumerA", .{ .map = style_a_data });
    try styles_map.put(a, "consumerB", .{ .map = style_b_data });

    var base_ctx = toupee.Context.init(a);
    try base_ctx.put("styles", .{ .map = styles_map });

    const patterns = [_]pattern_loader.Pattern{
        stubPattern(a, "colors", "tokens", "--accent: <t-raw name=\"style.accent\" />;"),
    };
    const groups = [_]pattern_loader.CategoryGroup{
        .{ .name = "tokens", .patterns = &patterns },
    };
    const result = LoadResult{
        .categories = &groups,
        .all = &patterns,
    };

    const css_a = try buildLayeredCss(a, "consumerA", result, &base_ctx);
    const css_b = try buildLayeredCss(a, "consumerB", result, &base_ctx);
    try testing.expect(std.mem.indexOf(u8, css_a, "--accent: blue;") != null);
    try testing.expect(std.mem.indexOf(u8, css_b, "--accent: green;") != null);
    try testing.expect(std.mem.indexOf(u8, css_a, "green") == null);
    try testing.expect(std.mem.indexOf(u8, css_b, "blue") == null);
}
