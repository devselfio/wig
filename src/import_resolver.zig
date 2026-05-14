const std = @import("std");
const comb = @import("comb");
const toupee = @import("toupee");
const pattern_loader = @import("pattern_loader.zig");
const config = @import("config.zig");

const Allocator = std.mem.Allocator;
const fs = std.fs;
const ValueMap = std.StringArrayHashMapUnmanaged(toupee.Value);

const Pattern = pattern_loader.Pattern;
const CategoryGroup = pattern_loader.CategoryGroup;
const LoadResult = pattern_loader.LoadResult;

pub const ResolvedStyle = struct {
    name: []const u8,
    result: LoadResult,
};

/// Resolves patterns for all styles, processing in topological order
/// so that upstream styles are resolved before their dependents.
///
/// For each style: loads local patterns, then merges in imported patterns
/// according to the `imports:` declarations. Local patterns override imported
/// ones at the same `{category}/{id}`.
///
/// Returns one `ResolvedStyle` per input style config, in the same order
/// as `style_cfgs` after dependency sorting.
pub fn resolveAllStyles(
    a: Allocator,
    style_cfgs: []config.StyleConfig,
    styles_dir: fs.Dir,
    style_ctx: *const toupee.Context,
) ![]const ResolvedStyle {
    config.sortByDependencyOrder(style_cfgs);

    var resolved_map = std.StringArrayHashMapUnmanaged(LoadResult){};
    var results = std.ArrayListUnmanaged(ResolvedStyle){};

    for (style_cfgs) |style_cfg| {
        var style_dir = styles_dir.openDir(style_cfg.name, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => {
                const empty = LoadResult{ .categories = &.{}, .all = &.{} };
                try resolved_map.put(a, style_cfg.name, empty);
                try results.append(a, .{ .name = style_cfg.name, .result = empty });
                continue;
            },
            else => return err,
        };
        defer style_dir.close();

        const local = try pattern_loader.loadStylePatterns(a, style_cfg.name, style_dir, style_ctx);

        const import_decls = try parseImports(a, style_cfg.raw);

        if (import_decls.len == 0) {
            try resolved_map.put(a, style_cfg.name, local);
            try results.append(a, .{ .name = style_cfg.name, .result = local });
            continue;
        }

        var merged = local;
        for (import_decls) |decl| {
            const upstream = resolved_map.get(decl.upstream_name) orelse
                return error.MissingImportStyle;

            const filtered = try filterPatterns(a, upstream, decl.pattern_spec);
            merged = try mergePatterns(a, merged, filtered);
        }

        try resolved_map.put(a, style_cfg.name, merged);
        try results.append(a, .{ .name = style_cfg.name, .result = merged });
    }

    return try a.dupe(ResolvedStyle, results.items);
}

pub const ImportDecl = struct {
    upstream_name: []const u8,
    pattern_spec: PatternSpec,
    data_entries: []const DataEntry,
};

pub const PatternSpec = union(enum) {
    none,
    all,
    categories: []const CategorySpec,
};

pub const CategorySpec = struct {
    name: []const u8,
    items: ItemSpec,
};

pub const ItemSpec = union(enum) {
    all,
    specific: []const []const u8,
};

pub const DataEntry = struct {
    path: []const u8,
    items: []const []const u8,
};

/// Parses `imports:` from a style's raw YAML configuration.
///
/// Supports:
/// - `imports: {style}: patterns: **` (import all patterns)
/// - `imports: {style}: patterns: {cat}: **` (import category)
/// - `imports: {style}: patterns: {cat}: [id, ...]` (import specific items)
/// - `imports: {style}: data: {path}: [items]` (validate data exists)
pub fn parseImports(a: Allocator, raw: comb.Value) ![]const ImportDecl {
    const imports_val = raw.get("imports") orelse return &.{};
    if (imports_val != .object) return &.{};

    var decls = std.ArrayListUnmanaged(ImportDecl){};

    for (imports_val.object) |style_entry| {
        const upstream_name = switch (style_entry.key) {
            .string => |s| s,
            else => continue,
        };

        if (style_entry.value != .object) continue;

        var pattern_spec: PatternSpec = .none;
        var data_entries = std.ArrayListUnmanaged(DataEntry){};

        for (style_entry.value.object) |field_entry| {
            const field_name = switch (field_entry.key) {
                .string => |s| s,
                else => continue,
            };

            if (std.mem.eql(u8, field_name, "patterns")) {
                pattern_spec = try parsePatternSpec(a, field_entry.value);
            } else if (std.mem.eql(u8, field_name, "data")) {
                if (field_entry.value == .object) {
                    for (field_entry.value.object) |data_entry| {
                        const path = switch (data_entry.key) {
                            .string => |s| s,
                            else => continue,
                        };
                        var items = std.ArrayListUnmanaged([]const u8){};
                        if (data_entry.value == .array) {
                            for (data_entry.value.array) |item| {
                                if (item == .string) try items.append(a, item.string);
                            }
                        }
                        try data_entries.append(a, .{
                            .path = path,
                            .items = try a.dupe([]const u8, items.items),
                        });
                    }
                }
            }
        }

        try decls.append(a, .{
            .upstream_name = upstream_name,
            .pattern_spec = pattern_spec,
            .data_entries = try a.dupe(DataEntry, data_entries.items),
        });
    }

    return try a.dupe(ImportDecl, decls.items);
}

fn parsePatternSpec(a: Allocator, val: comb.Value) !PatternSpec {
    if (val == .string and std.mem.eql(u8, val.string, "**")) {
        return .all;
    }

    if (val != .object) return .none;

    var categories = std.ArrayListUnmanaged(CategorySpec){};
    for (val.object) |cat_entry| {
        const cat_name = switch (cat_entry.key) {
            .string => |s| s,
            else => continue,
        };

        const item_spec: ItemSpec = blk: {
            if (cat_entry.value == .string and std.mem.eql(u8, cat_entry.value.string, "**")) {
                break :blk .all;
            }
            if (cat_entry.value == .array) {
                var items = std.ArrayListUnmanaged([]const u8){};
                for (cat_entry.value.array) |item| {
                    if (item == .string) try items.append(a, item.string);
                }
                break :blk .{ .specific = try a.dupe([]const u8, items.items) };
            }
            break :blk .all;
        };

        try categories.append(a, .{ .name = cat_name, .items = item_spec });
    }

    return .{ .categories = try a.dupe(CategorySpec, categories.items) };
}

/// Filters patterns from an upstream LoadResult according to a PatternSpec.
fn filterPatterns(a: Allocator, upstream: LoadResult, spec: PatternSpec) !LoadResult {
    switch (spec) {
        .none => return LoadResult{ .categories = &.{}, .all = &.{} },
        .all => return upstream,
        .categories => |cats| {
            var filtered_groups = std.ArrayListUnmanaged(CategoryGroup){};
            var filtered_all = std.ArrayListUnmanaged(Pattern){};

            for (cats) |cat_spec| {
                for (upstream.categories) |group| {
                    if (!std.mem.eql(u8, group.name, cat_spec.name)) continue;

                    switch (cat_spec.items) {
                        .all => {
                            try filtered_groups.append(a, group);
                            for (group.patterns) |p| try filtered_all.append(a, p);
                        },
                        .specific => |names| {
                            var selected = std.ArrayListUnmanaged(Pattern){};
                            for (group.patterns) |p| {
                                for (names) |name| {
                                    if (std.mem.eql(u8, p.id, name)) {
                                        try selected.append(a, p);
                                        try filtered_all.append(a, p);
                                        break;
                                    }
                                }
                            }
                            if (selected.items.len > 0) {
                                try filtered_groups.append(a, .{
                                    .name = group.name,
                                    .patterns = try a.dupe(Pattern, selected.items),
                                });
                            }
                        },
                    }
                    break;
                }
            }

            return .{
                .categories = try a.dupe(CategoryGroup, filtered_groups.items),
                .all = try a.dupe(Pattern, filtered_all.items),
            };
        },
    }
}

/// Merges imported patterns into the local set. Local patterns override
/// imported ones at the same `{category}/{id}`. The result maintains
/// CUBE CSS category order, with alphabetical ordering within categories.
fn mergePatterns(a: Allocator, local: LoadResult, imported: LoadResult) !LoadResult {
    var local_slugs = std.StringArrayHashMapUnmanaged(void){};
    for (local.all) |p| try local_slugs.put(a, p.slug, {});

    var category_map = std.StringArrayHashMapUnmanaged(std.ArrayListUnmanaged(Pattern)){};

    for (local.all) |p| {
        const gop = try category_map.getOrPut(a, p.category);
        if (!gop.found_existing) gop.value_ptr.* = .{};
        try gop.value_ptr.append(a, p);
    }

    for (imported.all) |p| {
        if (local_slugs.contains(p.slug)) continue;
        const gop = try category_map.getOrPut(a, p.category);
        if (!gop.found_existing) gop.value_ptr.* = .{};
        try gop.value_ptr.append(a, p);
    }

    var groups = std.ArrayListUnmanaged(CategoryGroup){};
    var all = std.ArrayListUnmanaged(Pattern){};

    for (pattern_loader.CUBE_CATEGORIES) |cat_name| {
        const list = category_map.getPtr(cat_name) orelse continue;
        if (list.items.len == 0) continue;

        std.mem.sort(Pattern, list.items, {}, struct {
            fn cmp(_: void, lhs: Pattern, rhs: Pattern) bool {
                return std.mem.order(u8, lhs.id, rhs.id) == .lt;
            }
        }.cmp);

        try groups.append(a, .{
            .name = cat_name,
            .patterns = try a.dupe(Pattern, list.items),
        });
        for (list.items) |p| try all.append(a, p);
    }

    return .{
        .categories = try a.dupe(CategoryGroup, groups.items),
        .all = try a.dupe(Pattern, all.items),
    };
}

/// Extracts dependency names from `imports:` keys for topological sorting.
/// This replaces `depends:` for determining processing order.
pub fn extractImportDependencies(a: Allocator, raw: comb.Value) ![]const []const u8 {
    const imports_val = raw.get("imports") orelse return &.{};
    if (imports_val != .object) return &.{};

    var deps = std.ArrayListUnmanaged([]const u8){};
    for (imports_val.object) |entry| {
        const name = switch (entry.key) {
            .string => |s| s,
            else => continue,
        };
        try deps.append(a, name);
    }
    return try a.dupe([]const u8, deps.items);
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

test "parseImports: no imports field" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var parsed = try comb.parse(arena.allocator(), "name: default");
    defer parsed.deinit();

    const decls = try parseImports(arena.allocator(), parsed.value);
    try testing.expectEqual(@as(usize, 0), decls.len);
}

test "parseImports: glob all patterns" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var parsed = try comb.parse(a, "imports:\n  cube:\n    patterns: \"**\"");
    defer parsed.deinit();

    const decls = try parseImports(a, parsed.value);
    try testing.expectEqual(@as(usize, 1), decls.len);
    try testing.expectEqualStrings("cube", decls[0].upstream_name);
    try testing.expect(decls[0].pattern_spec == .all);
}

test "parseImports: category-level import" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var parsed = try comb.parse(a,
        \\imports:
        \\  base:
        \\    patterns:
        \\      blocks: "**"
    );
    defer parsed.deinit();

    const decls = try parseImports(a, parsed.value);
    try testing.expectEqual(@as(usize, 1), decls.len);
    const cats = decls[0].pattern_spec.categories;
    try testing.expectEqual(@as(usize, 1), cats.len);
    try testing.expectEqualStrings("blocks", cats[0].name);
    try testing.expect(cats[0].items == .all);
}

test "parseImports: item-level import" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var parsed = try comb.parse(a,
        \\imports:
        \\  base:
        \\    patterns:
        \\      globals:
        \\        - syntax
    );
    defer parsed.deinit();

    const decls = try parseImports(a, parsed.value);
    const cats = decls[0].pattern_spec.categories;
    try testing.expectEqual(@as(usize, 1), cats.len);
    try testing.expectEqualStrings("globals", cats[0].name);
    const items = cats[0].items.specific;
    try testing.expectEqual(@as(usize, 1), items.len);
    try testing.expectEqualStrings("syntax", items[0]);
}

test "parseImports: data imports" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var parsed = try comb.parse(a,
        \\imports:
        \\  highlights:
        \\    data:
        \\      colors:
        \\        - rosepine
        \\        - solarized
    );
    defer parsed.deinit();

    const decls = try parseImports(a, parsed.value);
    try testing.expectEqual(@as(usize, 1), decls.len);
    try testing.expectEqual(@as(usize, 1), decls[0].data_entries.len);
    try testing.expectEqualStrings("colors", decls[0].data_entries[0].path);
    try testing.expectEqual(@as(usize, 2), decls[0].data_entries[0].items.len);
    try testing.expectEqualStrings("rosepine", decls[0].data_entries[0].items[0]);
}

test "filterPatterns: all passes through" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const patterns = [_]Pattern{
        stubPattern(a, "button", "blocks"),
        stubPattern(a, "tag", "blocks"),
    };
    const groups = [_]CategoryGroup{
        .{ .name = "blocks", .patterns = &patterns },
    };
    const upstream = LoadResult{
        .categories = &groups,
        .all = &patterns,
    };

    const result = try filterPatterns(a, upstream, .all);
    try testing.expectEqual(@as(usize, 2), result.all.len);
}

test "filterPatterns: category filter" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const block_patterns = [_]Pattern{stubPattern(a, "button", "blocks")};
    const reset_patterns = [_]Pattern{stubPattern(a, "reset", "resets")};
    const groups = [_]CategoryGroup{
        .{ .name = "resets", .patterns = &reset_patterns },
        .{ .name = "blocks", .patterns = &block_patterns },
    };
    const all_p = [_]Pattern{ stubPattern(a, "reset", "resets"), stubPattern(a, "button", "blocks") };
    const upstream = LoadResult{
        .categories = &groups,
        .all = &all_p,
    };

    const cats = [_]CategorySpec{
        .{ .name = "blocks", .items = .all },
    };
    const result = try filterPatterns(a, upstream, .{ .categories = &cats });
    try testing.expectEqual(@as(usize, 1), result.all.len);
    try testing.expectEqualStrings("button", result.all[0].id);
}

test "filterPatterns: item filter" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const patterns = [_]Pattern{
        stubPattern(a, "button", "blocks"),
        stubPattern(a, "tag", "blocks"),
        stubPattern(a, "card", "blocks"),
    };
    const groups = [_]CategoryGroup{
        .{ .name = "blocks", .patterns = &patterns },
    };
    const upstream = LoadResult{
        .categories = &groups,
        .all = &patterns,
    };

    const names = [_][]const u8{"button"};
    const cats = [_]CategorySpec{
        .{ .name = "blocks", .items = .{ .specific = &names } },
    };
    const result = try filterPatterns(a, upstream, .{ .categories = &cats });
    try testing.expectEqual(@as(usize, 1), result.all.len);
    try testing.expectEqualStrings("button", result.all[0].id);
}

test "mergePatterns: local overrides imported" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const local_button = stubPatternWithName(a, "button", "blocks", "Local Button");
    const imported_button = stubPatternWithName(a, "button", "blocks", "Imported Button");
    const imported_tag = stubPatternWithName(a, "tag", "blocks", "Imported Tag");

    const local_patterns = [_]Pattern{local_button};
    const local_groups = [_]CategoryGroup{
        .{ .name = "blocks", .patterns = &local_patterns },
    };
    const local = LoadResult{
        .categories = &local_groups,
        .all = &local_patterns,
    };

    const imported_patterns = [_]Pattern{ imported_button, imported_tag };
    const imported_groups = [_]CategoryGroup{
        .{ .name = "blocks", .patterns = &imported_patterns },
    };
    const imported = LoadResult{
        .categories = &imported_groups,
        .all = &imported_patterns,
    };

    const result = try mergePatterns(a, local, imported);

    try testing.expectEqual(@as(usize, 2), result.all.len);

    var found_local_button = false;
    var found_imported_tag = false;
    for (result.all) |p| {
        if (std.mem.eql(u8, p.id, "button")) {
            try testing.expectEqualStrings("Local Button", p.metadata.map.get("name").?.string);
            found_local_button = true;
        }
        if (std.mem.eql(u8, p.id, "tag")) {
            try testing.expectEqualStrings("Imported Tag", p.metadata.map.get("name").?.string);
            found_imported_tag = true;
        }
    }
    try testing.expect(found_local_button);
    try testing.expect(found_imported_tag);
}

test "mergePatterns: maintains CUBE order" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const local_button = stubPattern(a, "button", "blocks");
    const imported_reset = stubPattern(a, "reset", "resets");
    const imported_stack = stubPattern(a, "stack", "compositions");

    const local_patterns = [_]Pattern{local_button};
    const local_groups = [_]CategoryGroup{
        .{ .name = "blocks", .patterns = &local_patterns },
    };
    const local = LoadResult{
        .categories = &local_groups,
        .all = &local_patterns,
    };

    const imported_patterns = [_]Pattern{ imported_reset, imported_stack };
    const imported_groups = [_]CategoryGroup{
        .{ .name = "resets", .patterns = &[_]Pattern{imported_reset} },
        .{ .name = "compositions", .patterns = &[_]Pattern{imported_stack} },
    };
    const imported = LoadResult{
        .categories = &imported_groups,
        .all = &imported_patterns,
    };

    const result = try mergePatterns(a, local, imported);

    try testing.expectEqual(@as(usize, 3), result.all.len);
    try testing.expectEqualStrings("resets", result.all[0].category);
    try testing.expectEqualStrings("compositions", result.all[1].category);
    try testing.expectEqualStrings("blocks", result.all[2].category);
}

test "extractImportDependencies: extracts style names from imports keys" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var parsed = try comb.parse(a,
        \\imports:
        \\  cube:
        \\    patterns: "**"
        \\  highlights:
        \\    patterns:
        \\      globals:
        \\        - syntax
    );
    defer parsed.deinit();

    const deps = try extractImportDependencies(a, parsed.value);
    try testing.expectEqual(@as(usize, 2), deps.len);
    try testing.expectEqualStrings("cube", deps[0]);
    try testing.expectEqualStrings("highlights", deps[1]);
}

fn stubPattern(a: Allocator, id: []const u8, category: []const u8) Pattern {
    return stubPatternWithName(a, id, category, id);
}

fn stubPatternWithName(a: Allocator, id: []const u8, category: []const u8, name: []const u8) Pattern {
    var meta = ValueMap{};
    meta.put(a, "name", .{ .string = name }) catch {};
    const slug = std.fmt.allocPrint(a, "{s}/{s}", .{ category, id }) catch id;
    return .{
        .id = id,
        .category = category,
        .slug = slug,
        .source_style = "test",
        .metadata = .{ .map = meta },
        .example = "",
        .variants = &.{},
        .resources = std.StringArrayHashMapUnmanaged(pattern_loader.ResourceEntry){},
        .template_source = null,
        .file_paths = &.{},
    };
}
