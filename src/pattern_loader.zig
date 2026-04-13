const std = @import("std");
const toupee = @import("toupee");
const comb = @import("comb");
const pattern_parser = @import("pattern_parser.zig");
const frontmatter = @import("frontmatter.zig");
const context_mod = @import("context.zig");

const Allocator = std.mem.Allocator;
const fs = std.fs;
const ValueMap = std.StringArrayHashMapUnmanaged(toupee.Value);

/// Fixed CUBE CSS category order. Determines `@layer` priority and display order.
pub const CUBE_CATEGORIES = [_][]const u8{
    "tokens",
    "resets",
    "globals",
    "fonts",
    "compositions",
    "utilities",
    "blocks",
    "exceptions",
};

pub const Pattern = struct {
    id: []const u8,
    category: []const u8,
    slug: []const u8,
    metadata: toupee.Value,
    example: []const u8,
    variants: []const pattern_parser.Variant,
    css_source: ?[]const u8,
    template_source: ?[]const u8,
    js_source: ?[]const u8,
    asset_paths: []const []const u8,
};

pub const LoadResult = struct {
    /// All patterns grouped by CUBE category, in fixed order.
    /// Only categories with at least one pattern are included.
    categories: []const CategoryGroup,
    /// Flat list of all patterns: CUBE category order, alphabetical within.
    all: []const Pattern,
};

pub const CategoryGroup = struct {
    name: []const u8,
    patterns: []const Pattern,
};

/// Loads all patterns from a single style's directory.
///
/// Scans `patterns/{category}/*.html` for each CUBE CSS category,
/// parses HTML+front-matter files, discovers associated resources by convention,
/// and renders CSS files through Toupee when they have front-matter.
///
/// `style_dir` is the style's root directory (e.g. `styles/cube/`).
/// `style_ctx` provides the rendering context for front-matter CSS.
pub fn loadStylePatterns(
    a: Allocator,
    style_dir: fs.Dir,
    style_ctx: *const toupee.Context,
) !LoadResult {
    var categories = std.ArrayListUnmanaged(CategoryGroup){};
    var all_patterns = std.ArrayListUnmanaged(Pattern){};

    var patterns_dir = style_dir.openDir("patterns", .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return .{
            .categories = &.{},
            .all = &.{},
        },
        else => return err,
    };
    defer patterns_dir.close();

    for (CUBE_CATEGORIES) |category| {
        var cat_dir = patterns_dir.openDir(category, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => continue,
            else => return err,
        };
        defer cat_dir.close();

        var names = std.ArrayListUnmanaged([]const u8){};
        var it = cat_dir.iterate();
        while (try it.next()) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".html")) continue;
            try names.append(a, try a.dupe(u8, entry.name));
        }
        std.mem.sort([]const u8, names.items, {}, struct {
            fn cmp(_: void, lhs: []const u8, rhs: []const u8) bool {
                return std.mem.order(u8, lhs, rhs) == .lt;
            }
        }.cmp);

        if (names.items.len == 0) continue;

        var cat_patterns = std.ArrayListUnmanaged(Pattern){};
        for (names.items) |filename| {
            const id = filename[0 .. filename.len - ".html".len];
            const rel_path = try std.fmt.allocPrint(a, "patterns/{s}/{s}", .{ category, filename });

            const source = try style_dir.readFileAlloc(a, rel_path, 4 * 1024 * 1024);
            const parsed = try pattern_parser.parsePatternFile(a, source);

            const css_source = readResourceFile(a, style_dir, "css", category, id, style_ctx);
            const template_source = readRawResourceFile(a, style_dir, "templates", category, id);
            const js_source = readRawResourceFile(a, style_dir, "js", category, id);
            const asset_paths = discoverAssets(a, style_dir, category, id);

            const pattern = Pattern{
                .id = try a.dupe(u8, id),
                .category = category,
                .slug = try std.fmt.allocPrint(a, "{s}/{s}", .{ category, id }),
                .metadata = parsed.metadata,
                .example = parsed.example,
                .variants = parsed.variants,
                .css_source = css_source,
                .template_source = template_source,
                .js_source = js_source,
                .asset_paths = asset_paths,
            };

            try cat_patterns.append(a, pattern);
            try all_patterns.append(a, pattern);
        }

        try categories.append(a, .{
            .name = category,
            .patterns = try a.dupe(Pattern, cat_patterns.items),
        });
    }

    return .{
        .categories = try a.dupe(CategoryGroup, categories.items),
        .all = try a.dupe(Pattern, all_patterns.items),
    };
}

/// Reads a resource file (e.g. CSS), rendering through Toupee if it has front-matter.
fn readResourceFile(
    a: Allocator,
    style_dir: fs.Dir,
    resource_type: []const u8,
    category: []const u8,
    id: []const u8,
    style_ctx: *const toupee.Context,
) ?[]const u8 {
    const rel_path = std.fmt.allocPrint(a, "{s}/{s}/{s}.css", .{ resource_type, category, id }) catch return null;
    const source = style_dir.readFileAlloc(a, rel_path, 4 * 1024 * 1024) catch return null;

    var fm_result = frontmatter.parse(a, source) catch return source;
    if (fm_result) |*fm| {
        defer fm.deinit();

        var work_arena = std.heap.ArenaAllocator.init(a);
        defer work_arena.deinit();
        const wa = work_arena.allocator();

        var ctx = toupee.Context.initFrom(wa, style_ctx) catch return source;

        const fm_toupee = context_mod.combToToupee(wa, fm.data) catch return source;
        if (fm_toupee == .map) {
            var it = fm_toupee.map.iterator();
            while (it.next()) |entry| {
                ctx.put(entry.key_ptr.*, entry.value_ptr.*) catch {};
            }
        }

        var resolver: toupee.Resolver = .{};
        const rendered = toupee.render(wa, fm.content, &ctx, resolver.loader(), .{}) catch return source;
        return a.dupe(u8, rendered) catch return source;
    }

    return source;
}

/// Reads a raw resource file without rendering. Returns null if the file doesn't exist.
fn readRawResourceFile(
    a: Allocator,
    style_dir: fs.Dir,
    resource_type: []const u8,
    category: []const u8,
    id: []const u8,
) ?[]const u8 {
    const ext: []const u8 = if (std.mem.eql(u8, resource_type, "js")) ".js" else ".html";
    const rel_path = std.fmt.allocPrint(a, "{s}/{s}/{s}{s}", .{ resource_type, category, id, ext }) catch return null;
    return style_dir.readFileAlloc(a, rel_path, 4 * 1024 * 1024) catch return null;
}

/// Discovers asset files at `assets/{category}/{id}/`.
fn discoverAssets(
    a: Allocator,
    style_dir: fs.Dir,
    category: []const u8,
    id: []const u8,
) []const []const u8 {
    const dir_path = std.fmt.allocPrint(a, "assets/{s}/{s}", .{ category, id }) catch return &.{};

    var asset_dir = style_dir.openDir(dir_path, .{ .iterate = true }) catch return &.{};
    defer asset_dir.close();

    var paths = std.ArrayListUnmanaged([]const u8){};
    var it = asset_dir.iterate();
    while (it.next()) |entry_opt| {
        const entry = entry_opt orelse break;
        if (entry.kind != .file) continue;
        const full = std.fmt.allocPrint(a, "{s}/{s}", .{ dir_path, entry.name }) catch continue;
        paths.append(a, full) catch continue;
    } else |_| {}

    std.mem.sort([]const u8, paths.items, {}, struct {
        fn cmp(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.order(u8, lhs, rhs) == .lt;
        }
    }.cmp);

    return a.dupe([]const u8, paths.items) catch &.{};
}

/// Converts a LoadResult into a Toupee value tree suitable for the template context.
///
/// Produces:
/// ```
/// {category}.{id}.name, .id, .category, .slug, .description, .example, .variants, ...
/// {category}.items = [...]
/// all = [... flat list, CUBE order, alpha within ...]
/// ```
pub fn buildPatternContext(a: Allocator, result: LoadResult) !toupee.Value {
    var root = ValueMap{};

    for (result.categories) |group| {
        var cat_map = ValueMap{};
        var items = std.ArrayListUnmanaged(toupee.Value){};

        for (group.patterns) |pattern| {
            const pat_val = try patternToValue(a, pattern);
            try cat_map.put(a, pattern.id, pat_val);
            try items.append(a, pat_val);
        }

        try cat_map.put(a, "items", .{ .list = try a.dupe(toupee.Value, items.items) });
        try root.put(a, group.name, .{ .map = cat_map });
    }

    var all_items = std.ArrayListUnmanaged(toupee.Value){};
    for (result.all) |pattern| {
        try all_items.append(a, try patternToValue(a, pattern));
    }
    try root.put(a, "all", .{ .list = try a.dupe(toupee.Value, all_items.items) });

    return .{ .map = root };
}

fn patternToValue(a: Allocator, pattern: Pattern) !toupee.Value {
    var map = ValueMap{};

    try map.put(a, "id", .{ .string = pattern.id });
    try map.put(a, "category", .{ .string = pattern.category });
    try map.put(a, "slug", .{ .string = pattern.slug });
    try map.put(a, "example", .{ .string = pattern.example });

    if (pattern.metadata == .map) {
        var it = pattern.metadata.map.iterator();
        while (it.next()) |entry| {
            if (!map.contains(entry.key_ptr.*)) {
                try map.put(a, entry.key_ptr.*, entry.value_ptr.*);
            }
        }
    }

    var variant_list = std.ArrayListUnmanaged(toupee.Value){};
    for (pattern.variants) |v| {
        var v_map = ValueMap{};
        try v_map.put(a, "name", .{ .string = v.name });
        try v_map.put(a, "example", .{ .string = v.content });
        try variant_list.append(a, .{ .map = v_map });
    }
    try map.put(a, "variants", .{ .list = try a.dupe(toupee.Value, variant_list.items) });

    if (pattern.css_source) |css| try map.put(a, "css_source", .{ .string = css });
    if (pattern.template_source) |tmpl| try map.put(a, "template_source", .{ .string = tmpl });
    if (pattern.js_source) |js| try map.put(a, "js_source", .{ .string = js });

    if (pattern.asset_paths.len > 0) {
        var asset_list = std.ArrayListUnmanaged(toupee.Value){};
        for (pattern.asset_paths) |path| {
            try asset_list.append(a, .{ .string = path });
        }
        try map.put(a, "asset_paths", .{ .list = try a.dupe(toupee.Value, asset_list.items) });
    }

    return .{ .map = map };
}

// ── Tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

fn createFile(dir: fs.Dir, path: []const u8, content: []const u8) !void {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |sep| {
        dir.makePath(path[0..sep]) catch {};
    }
    var f = try dir.createFile(path, .{});
    defer f.close();
    try f.writeAll(content);
}

test "loadStylePatterns: empty patterns directory" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("patterns");

    var ctx = toupee.Context.init(a);
    const result = try loadStylePatterns(a, tmp.dir, &ctx);

    try testing.expectEqual(@as(usize, 0), result.categories.len);
    try testing.expectEqual(@as(usize, 0), result.all.len);
}

test "loadStylePatterns: no patterns directory" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var ctx = toupee.Context.init(a);
    const result = try loadStylePatterns(a, tmp.dir, &ctx);

    try testing.expectEqual(@as(usize, 0), result.categories.len);
    try testing.expectEqual(@as(usize, 0), result.all.len);
}

test "loadStylePatterns: single pattern with CSS" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try createFile(tmp.dir, "patterns/blocks/button.html",
        \\---
        \\name: Button
        \\description: A clickable button
        \\---
        \\<button class="button">Click me</button>
    );
    try createFile(tmp.dir, "css/blocks/button.css",
        \\.button { display: inline-flex; }
    );

    var ctx = toupee.Context.init(a);
    const result = try loadStylePatterns(a, tmp.dir, &ctx);

    try testing.expectEqual(@as(usize, 1), result.categories.len);
    try testing.expectEqualStrings("blocks", result.categories[0].name);
    try testing.expectEqual(@as(usize, 1), result.categories[0].patterns.len);

    const p = result.categories[0].patterns[0];
    try testing.expectEqualStrings("button", p.id);
    try testing.expectEqualStrings("blocks", p.category);
    try testing.expectEqualStrings("blocks/button", p.slug);
    try testing.expectEqualStrings("Button", p.metadata.map.get("name").?.string);
    try testing.expect(std.mem.indexOf(u8, p.example, "Click me") != null);
    try testing.expect(p.css_source != null);
    try testing.expect(std.mem.indexOf(u8, p.css_source.?, "inline-flex") != null);
    try testing.expectEqual(@as(usize, 0), p.variants.len);
}

test "loadStylePatterns: front-matter-only pattern" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try createFile(tmp.dir, "patterns/resets/reset.html",
        \\---
        \\name: Reset
        \\description: CSS reset
        \\---
    );
    try createFile(tmp.dir, "css/resets/reset.css",
        \\* { margin: 0; }
    );

    var ctx = toupee.Context.init(a);
    const result = try loadStylePatterns(a, tmp.dir, &ctx);

    try testing.expectEqual(@as(usize, 1), result.categories.len);
    try testing.expectEqualStrings("resets", result.categories[0].name);
    const p = result.categories[0].patterns[0];
    try testing.expectEqualStrings("reset", p.id);
    try testing.expectEqualStrings("", p.example);
}

test "loadStylePatterns: pattern with variants" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try createFile(tmp.dir, "patterns/blocks/button.html",
        \\---
        \\name: Button
        \\---
        \\<button class="button">Default</button>
        \\
        \\<!-- variant: primary -->
        \\<button class="button" data-variant="primary">Primary</button>
    );

    var ctx = toupee.Context.init(a);
    const result = try loadStylePatterns(a, tmp.dir, &ctx);

    const p = result.all[0];
    try testing.expectEqual(@as(usize, 1), p.variants.len);
    try testing.expectEqualStrings("primary", p.variants[0].name);
}

test "loadStylePatterns: CUBE category ordering" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try createFile(tmp.dir, "patterns/blocks/button.html",
        "---\nname: Button\n---\n<button>B</button>"
    );
    try createFile(tmp.dir, "patterns/resets/reset.html",
        "---\nname: Reset\n---"
    );
    try createFile(tmp.dir, "patterns/compositions/stack.html",
        "---\nname: Stack\n---\n<div>S</div>"
    );

    var ctx = toupee.Context.init(a);
    const result = try loadStylePatterns(a, tmp.dir, &ctx);

    try testing.expectEqual(@as(usize, 3), result.categories.len);
    try testing.expectEqualStrings("resets", result.categories[0].name);
    try testing.expectEqualStrings("compositions", result.categories[1].name);
    try testing.expectEqualStrings("blocks", result.categories[2].name);

    try testing.expectEqual(@as(usize, 3), result.all.len);
    try testing.expectEqualStrings("resets/reset", result.all[0].slug);
    try testing.expectEqualStrings("compositions/stack", result.all[1].slug);
    try testing.expectEqualStrings("blocks/button", result.all[2].slug);
}

test "loadStylePatterns: alphabetical within category" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try createFile(tmp.dir, "patterns/blocks/tag.html",
        "---\nname: Tag\n---\n<span>T</span>"
    );
    try createFile(tmp.dir, "patterns/blocks/button.html",
        "---\nname: Button\n---\n<button>B</button>"
    );
    try createFile(tmp.dir, "patterns/blocks/card.html",
        "---\nname: Card\n---\n<div>C</div>"
    );

    var ctx = toupee.Context.init(a);
    const result = try loadStylePatterns(a, tmp.dir, &ctx);

    try testing.expectEqual(@as(usize, 3), result.categories[0].patterns.len);
    try testing.expectEqualStrings("button", result.categories[0].patterns[0].id);
    try testing.expectEqualStrings("card", result.categories[0].patterns[1].id);
    try testing.expectEqualStrings("tag", result.categories[0].patterns[2].id);
}

test "loadStylePatterns: missing resources are null" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try createFile(tmp.dir, "patterns/blocks/minimal.html",
        "---\nname: Minimal\n---\n<div>M</div>"
    );

    var ctx = toupee.Context.init(a);
    const result = try loadStylePatterns(a, tmp.dir, &ctx);

    const p = result.all[0];
    try testing.expect(p.css_source == null);
    try testing.expect(p.template_source == null);
    try testing.expect(p.js_source == null);
    try testing.expectEqual(@as(usize, 0), p.asset_paths.len);
}

test "loadStylePatterns: template source read raw" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try createFile(tmp.dir, "patterns/blocks/button.html",
        "---\nname: Button\n---\n<button>B</button>"
    );
    try createFile(tmp.dir, "templates/blocks/button.html",
        "<button class=\"button\"><t-slot /></button>"
    );

    var ctx = toupee.Context.init(a);
    const result = try loadStylePatterns(a, tmp.dir, &ctx);

    const p = result.all[0];
    try testing.expect(p.template_source != null);
    try testing.expect(std.mem.indexOf(u8, p.template_source.?, "t-slot") != null);
}

test "loadStylePatterns: CSS with front-matter is rendered" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try createFile(tmp.dir, "patterns/tokens/colors.html",
        "---\nname: Colours\n---"
    );
    try createFile(tmp.dir, "css/tokens/colors.css",
        "---\ncolor: red\n---\n:root { --accent: <t-raw name=\"color\" />; }"
    );

    var ctx = toupee.Context.init(a);
    const result = try loadStylePatterns(a, tmp.dir, &ctx);

    const p = result.all[0];
    try testing.expect(p.css_source != null);
    try testing.expectEqualStrings(":root { --accent: red; }", p.css_source.?);
}

test "loadStylePatterns: CSS without front-matter passed through" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try createFile(tmp.dir, "patterns/blocks/tag.html",
        "---\nname: Tag\n---\n<span>T</span>"
    );
    try createFile(tmp.dir, "css/blocks/tag.css",
        ".tag { display: inline-block; }"
    );

    var ctx = toupee.Context.init(a);
    const result = try loadStylePatterns(a, tmp.dir, &ctx);

    try testing.expectEqualStrings(".tag { display: inline-block; }", result.all[0].css_source.?);
}

test "buildPatternContext: creates correct tree structure" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try createFile(tmp.dir, "patterns/blocks/button.html",
        "---\nname: Button\ndescription: A button\n---\n<button>B</button>\n\n<!-- variant: primary -->\n<button data-variant=\"primary\">P</button>"
    );
    try createFile(tmp.dir, "css/blocks/button.css",
        ".button { display: flex; }"
    );

    var ctx = toupee.Context.init(a);
    const load = try loadStylePatterns(a, tmp.dir, &ctx);
    const tree = try buildPatternContext(a, load);

    const blocks = tree.map.get("blocks").?.map;
    const button = blocks.get("button").?.map;
    try testing.expectEqualStrings("Button", button.get("name").?.string);
    try testing.expectEqualStrings("button", button.get("id").?.string);
    try testing.expectEqualStrings("blocks", button.get("category").?.string);
    try testing.expectEqualStrings("blocks/button", button.get("slug").?.string);
    try testing.expect(button.get("css_source") != null);

    const variants = button.get("variants").?.list;
    try testing.expectEqual(@as(usize, 1), variants.len);
    try testing.expectEqualStrings("primary", variants[0].map.get("name").?.string);

    const items = blocks.get("items").?.list;
    try testing.expectEqual(@as(usize, 1), items.len);

    const all = tree.map.get("all").?.list;
    try testing.expectEqual(@as(usize, 1), all.len);
}
