const std = @import("std");
const toupee = @import("toupee");
const scanner_mod = @import("scanner.zig");

const Allocator = std.mem.Allocator;
const ValueMap = std.StringArrayHashMapUnmanaged(toupee.Value);

/// Builds taxonomy reverse indexes from scanned page entries.
///
/// For each taxonomy field (e.g. "tags", "categories"), builds a map of
/// slug -> list of page references. Returns a Toupee map:
///   `{ tags: { zig: [page, ...], web: [page, ...] }, categories: { ... } }`
///
/// Terms are slugified (lowercase, spaces to hyphens) for keys.
/// Display names use the first-seen form. String-valued fields are treated
/// as single-element lists.
pub fn buildIndex(
    a: Allocator,
    pages: []const scanner_mod.PageEntry,
    taxonomy_fields: []const []const u8,
) !toupee.Value {
    var root = ValueMap{};

    for (taxonomy_fields) |field| {
        var term_map = std.StringArrayHashMapUnmanaged(TermBucket){};

        for (pages) |page| {
            if (page.is_section) continue;
            const terms = getTerms(page.frontmatter, field) orelse continue;

            for (terms) |term_val| {
                const raw_term = switch (term_val) {
                    .string => |s| s,
                    else => continue,
                };

                const slug = try slugify(a, raw_term);
                const gop = try term_map.getOrPut(a, slug);
                if (!gop.found_existing) {
                    gop.value_ptr.* = .{
                        .display_name = raw_term,
                        .pages = .{},
                    };
                }

                var page_map = ValueMap{};
                try page_map.put(a, "path", .{ .string = page.url_path });
                try page_map.put(a, "url", .{ .string = page.absolute_url });
                try page_map.put(a, "source", .{ .string = page.source_path });

                if (page.frontmatter == .map) {
                    var fm_it = page.frontmatter.map.iterator();
                    while (fm_it.next()) |entry| {
                        try page_map.put(a, entry.key_ptr.*, entry.value_ptr.*);
                    }
                }

                try gop.value_ptr.pages.append(a, .{ .map = page_map });
            }
        }

        var field_map = ValueMap{};
        var it = term_map.iterator();
        while (it.next()) |entry| {
            var term_result = ValueMap{};
            const items = try a.dupe(toupee.Value, entry.value_ptr.pages.items);
            try term_result.put(a, "name", .{ .string = entry.value_ptr.display_name });
            try term_result.put(a, "slug", .{ .string = entry.key_ptr.* });
            try term_result.put(a, "pages", .{ .list = items });
            try field_map.put(a, entry.key_ptr.*, .{ .map = term_result });
        }

        try root.put(a, field, .{ .map = field_map });
    }

    return .{ .map = root };
}

const TermBucket = struct {
    display_name: []const u8,
    pages: std.ArrayListUnmanaged(toupee.Value),
};

/// Extracts taxonomy terms from a page's frontmatter. Handles both list
/// values (`tags: [zig, web]`) and single string values (`tags: zig`).
fn getTerms(fm: toupee.Value, field: []const u8) ?[]const toupee.Value {
    const val = switch (fm) {
        .map => |m| m.get(field) orelse return null,
        else => return null,
    };
    return switch (val) {
        .list => |l| l,
        .string => @as(*const [1]toupee.Value, @ptrCast(&val)),
        else => null,
    };
}

/// Slugifies a taxonomy term: lowercase ASCII, spaces to hyphens.
pub fn slugify(a: Allocator, term: []const u8) ![]const u8 {
    const buf = try a.alloc(u8, term.len);
    for (term, 0..) |c, i| {
        buf[i] = if (c == ' ') '-' else std.ascii.toLower(c);
    }
    return buf;
}

// ── Tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

test "slugify: lowercase and spaces" {
    const a = testing.allocator;
    const r = try slugify(a, "Hello World");
    defer a.free(r);
    try testing.expectEqualStrings("hello-world", r);
}

test "slugify: already lowercase no spaces" {
    const a = testing.allocator;
    const r = try slugify(a, "zig");
    defer a.free(r);
    try testing.expectEqualStrings("zig", r);
}

test "slugify: mixed case" {
    const a = testing.allocator;
    const r = try slugify(a, "Web Development");
    defer a.free(r);
    try testing.expectEqualStrings("web-development", r);
}

fn makeFmMap(a: Allocator, tags: []const toupee.Value) !toupee.Value {
    var map = ValueMap{};
    try map.put(a, "title", .{ .string = "Test" });
    const tag_slice = try a.dupe(toupee.Value, tags);
    try map.put(a, "tags", .{ .list = tag_slice });
    return .{ .map = map };
}

test "buildIndex: single taxonomy with tagged pages" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const tags1 = [_]toupee.Value{ .{ .string = "zig" }, .{ .string = "web" } };
    const tags2 = [_]toupee.Value{.{ .string = "zig" }};

    const pages = [_]scanner_mod.PageEntry{
        .{
            .source_path = "posts/first.dj",
            .output_file = "posts/first/index.html",
            .url_path = "/posts/first/",
            .absolute_url = "https://example.com/posts/first/",
            .content_body = "",
            .extension = ".dj",
            .frontmatter = try makeFmMap(a, &tags1),
            .collection_key = "pages.posts",
        },
        .{
            .source_path = "posts/second.dj",
            .output_file = "posts/second/index.html",
            .url_path = "/posts/second/",
            .absolute_url = "https://example.com/posts/second/",
            .content_body = "",
            .extension = ".dj",
            .frontmatter = try makeFmMap(a, &tags2),
            .collection_key = "pages.posts",
        },
    };

    const fields = [_][]const u8{"tags"};
    const result = try buildIndex(a, &pages, &fields);

    const tags_map = result.map.get("tags").?.map;
    const zig_term = tags_map.get("zig").?.map;
    const zig_pages = zig_term.get("pages").?.list;
    try testing.expectEqual(@as(usize, 2), zig_pages.len);
    try testing.expectEqualStrings("zig", zig_term.get("name").?.string);

    const web_term = tags_map.get("web").?.map;
    const web_pages = web_term.get("pages").?.list;
    try testing.expectEqual(@as(usize, 1), web_pages.len);
}

test "buildIndex: string-as-single-element list" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fm_map = ValueMap{};
    try fm_map.put(a, "tags", .{ .string = "solo" });

    const pages = [_]scanner_mod.PageEntry{
        .{
            .source_path = "page.dj",
            .output_file = "page/index.html",
            .url_path = "/page/",
            .absolute_url = "https://example.com/page/",
            .content_body = "",
            .extension = ".dj",
            .frontmatter = .{ .map = fm_map },
            .collection_key = "pages",
        },
    };

    const fields = [_][]const u8{"tags"};
    const result = try buildIndex(a, &pages, &fields);

    const solo_term = result.map.get("tags").?.map.get("solo").?.map;
    try testing.expectEqual(@as(usize, 1), solo_term.get("pages").?.list.len);
}

test "buildIndex: page with no tags skipped" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fm_map = ValueMap{};
    try fm_map.put(a, "title", .{ .string = "No Tags" });

    const pages = [_]scanner_mod.PageEntry{
        .{
            .source_path = "page.dj",
            .output_file = "page/index.html",
            .url_path = "/page/",
            .absolute_url = "https://example.com/page/",
            .content_body = "",
            .extension = ".dj",
            .frontmatter = .{ .map = fm_map },
            .collection_key = "pages",
        },
    };

    const fields = [_][]const u8{"tags"};
    const result = try buildIndex(a, &pages, &fields);

    const tags_map = result.map.get("tags").?.map;
    try testing.expectEqual(@as(usize, 0), tags_map.count());
}

test "buildIndex: multiple taxonomies" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fm_map = ValueMap{};
    const tags = [_]toupee.Value{.{ .string = "zig" }};
    const cats = [_]toupee.Value{.{ .string = "tutorial" }};
    try fm_map.put(a, "tags", .{ .list = try a.dupe(toupee.Value, &tags) });
    try fm_map.put(a, "categories", .{ .list = try a.dupe(toupee.Value, &cats) });

    const pages = [_]scanner_mod.PageEntry{
        .{
            .source_path = "page.dj",
            .output_file = "page/index.html",
            .url_path = "/page/",
            .absolute_url = "https://example.com/page/",
            .content_body = "",
            .extension = ".dj",
            .frontmatter = .{ .map = fm_map },
            .collection_key = "pages",
        },
    };

    const fields = [_][]const u8{ "tags", "categories" };
    const result = try buildIndex(a, &pages, &fields);

    try testing.expect(result.map.get("tags") != null);
    try testing.expect(result.map.get("categories") != null);

    const tutorial = result.map.get("categories").?.map.get("tutorial").?.map;
    try testing.expectEqual(@as(usize, 1), tutorial.get("pages").?.list.len);
}

test "buildIndex: sections excluded from taxonomy" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const tags = [_]toupee.Value{.{ .string = "zig" }};

    const pages = [_]scanner_mod.PageEntry{
        .{
            .source_path = "posts/_index.dj",
            .output_file = "posts/index.html",
            .url_path = "/posts/",
            .absolute_url = "https://example.com/posts/",
            .content_body = "",
            .extension = ".dj",
            .frontmatter = try makeFmMap(a, &tags),
            .collection_key = "pages.posts",
            .is_section = true,
        },
    };

    const fields = [_][]const u8{"tags"};
    const result = try buildIndex(a, &pages, &fields);

    const tags_map = result.map.get("tags").?.map;
    try testing.expectEqual(@as(usize, 0), tags_map.count());
}

test "buildIndex: slugification normalises terms" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const tags1 = [_]toupee.Value{.{ .string = "Web Dev" }};
    const tags2 = [_]toupee.Value{.{ .string = "web dev" }};

    const pages = [_]scanner_mod.PageEntry{
        .{
            .source_path = "a.dj",
            .output_file = "a/index.html",
            .url_path = "/a/",
            .absolute_url = "https://example.com/a/",
            .content_body = "",
            .extension = ".dj",
            .frontmatter = try makeFmMap(a, &tags1),
            .collection_key = "pages",
        },
        .{
            .source_path = "b.dj",
            .output_file = "b/index.html",
            .url_path = "/b/",
            .absolute_url = "https://example.com/b/",
            .content_body = "",
            .extension = ".dj",
            .frontmatter = try makeFmMap(a, &tags2),
            .collection_key = "pages",
        },
    };

    const fields = [_][]const u8{"tags"};
    const result = try buildIndex(a, &pages, &fields);

    const tags_map = result.map.get("tags").?.map;
    try testing.expectEqual(@as(usize, 1), tags_map.count());

    const term = tags_map.get("web-dev").?.map;
    try testing.expectEqual(@as(usize, 2), term.get("pages").?.list.len);
    try testing.expectEqualStrings("Web Dev", term.get("name").?.string);
}
