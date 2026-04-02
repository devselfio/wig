const std = @import("std");
const comb = @import("comb");
const toupee = @import("toupee");
const cu = @import("comb_utils.zig");

const Allocator = std.mem.Allocator;
const ValueMap = std.StringArrayHashMapUnmanaged(toupee.Value);

pub const PaginateConfig = struct {
    collection: []const u8,
    size: usize,
    path: []const u8 = "page",
    alias: []const u8 = "posts",
};

pub const DocumentOverrides = struct {
    layout: ?[]const u8 = null,
    style: ?[]const u8 = null,
    extra: ?comb.Value = null,
};

pub const CascadeData = struct {
    document: ?DocumentOverrides = null,
    site: ?comb.Value = null,
};

pub const PageMeta = struct {
    title: ?[]const u8 = null,
    layout: ?[]const u8 = null,
    style: ?[]const u8 = null,
    date: ?[]const u8 = null,
    tags: []const []const u8 = &.{},
    description: ?[]const u8 = null,
    thumbnail: ?[]const u8 = null,
    draft: bool = false,
    debug: bool = false,
    search: bool = true,
    slugify: ?bool = null,
    feeds: []const []const u8 = &.{},
    paginate: ?PaginateConfig = null,
    cascade: ?CascadeData = null,
};

/// Extracts typed `PageMeta` from normalized frontmatter (canonical shape:
/// `{ document: { title: ..., draft: ..., ... } }`).
pub fn parsePageMeta(a: Allocator, canonical_fm: comb.Value) !PageMeta {
    const doc = canonical_fm.get("document") orelse return .{};
    if (doc != .object) return .{};

    var meta: PageMeta = .{};

    meta.title = cu.getString(doc, "title");
    meta.layout = cu.getString(doc, "layout");
    meta.style = cu.getString(doc, "style");
    meta.date = cu.getString(doc, "date");
    meta.description = cu.getString(doc, "description");
    meta.thumbnail = cu.getString(doc, "thumbnail");
    meta.draft = cu.getBool(doc, "draft") orelse false;
    meta.debug = cu.getBool(doc, "debug") orelse false;
    meta.search = cu.getBool(doc, "search") orelse true;
    meta.slugify = cu.getBool(doc, "slugify");

    if (cu.getList(doc, "tags")) |tag_vals| {
        const strs = try a.alloc([]const u8, tag_vals.len);
        var n: usize = 0;
        for (tag_vals) |tv| {
            switch (tv) {
                .string => |s| {
                    strs[n] = s;
                    n += 1;
                },
                else => {},
            }
        }
        meta.tags = strs[0..n];
    } else if (doc.get("tags")) |tv| {
        if (tv == .string) {
            const single = try a.alloc([]const u8, 1);
            single[0] = tv.string;
            meta.tags = single;
        }
    }

    if (cu.getList(doc, "feeds")) |feed_vals| {
        const strs = try a.alloc([]const u8, feed_vals.len);
        var n: usize = 0;
        for (feed_vals) |fv| {
            switch (fv) {
                .string => |s| {
                    strs[n] = s;
                    n += 1;
                },
                else => {},
            }
        }
        meta.feeds = strs[0..n];
    }

    if (cu.getObject(doc, "paginate")) |pag| {
        const coll = cu.getString(pag, "collection") orelse null;
        if (coll) |c| {
            const size_val = cu.getInt(pag, "size") orelse 10;
            meta.paginate = .{
                .collection = c,
                .size = @intCast(size_val),
                .path = cu.getString(pag, "path") orelse "page",
                .alias = cu.getString(pag, "alias") orelse "posts",
            };
        }
    }

    if (cu.getObject(doc, "data")) |data| {
        var cascade: CascadeData = .{};
        if (cu.getObject(data, "document")) |doc_ovr| {
            cascade.document = .{
                .layout = cu.getString(doc_ovr, "layout"),
                .style = cu.getString(doc_ovr, "style"),
                .extra = doc_ovr,
            };
        }
        if (data.get("site")) |site_val| {
            if (site_val == .object) {
                cascade.site = site_val;
            }
        }
        if (cascade.document != null or cascade.site != null) {
            meta.cascade = cascade;
        }
    }

    return meta;
}

/// Converts typed `PageMeta` to a `toupee.Value` map suitable for the `document.*`
/// template namespace. Called once at the render boundary.
pub fn toTemplateValue(a: Allocator, meta: PageMeta) !toupee.Value {
    var doc = ValueMap{};

    if (meta.title) |t| try doc.put(a, "title", .{ .string = t });
    if (meta.layout) |l| try doc.put(a, "layout", .{ .string = l });
    if (meta.style) |s| try doc.put(a, "style", .{ .string = s });
    if (meta.date) |d| try doc.put(a, "date", .{ .string = d });
    if (meta.description) |d| try doc.put(a, "description", .{ .string = d });
    if (meta.thumbnail) |t| try doc.put(a, "thumbnail", .{ .string = t });
    if (!meta.search) try doc.put(a, "search", .{ .boolean = false });
    if (meta.draft) try doc.put(a, "draft", .{ .boolean = true });
    if (meta.debug) try doc.put(a, "debug", .{ .boolean = true });

    if (meta.tags.len > 0) {
        const tag_vals = try a.alloc(toupee.Value, meta.tags.len);
        for (meta.tags, tag_vals) |t, *out| out.* = .{ .string = t };
        try doc.put(a, "tags", .{ .list = tag_vals });
    }

    if (meta.feeds.len > 0) {
        const feed_vals = try a.alloc(toupee.Value, meta.feeds.len);
        for (meta.feeds, feed_vals) |f, *out| out.* = .{ .string = f };
        try doc.put(a, "feeds", .{ .list = feed_vals });
    }

    if (meta.paginate) |p| {
        var pag_map = ValueMap{};
        try pag_map.put(a, "collection", .{ .string = p.collection });
        try pag_map.put(a, "size", .{ .integer = @intCast(p.size) });
        try pag_map.put(a, "path", .{ .string = p.path });
        try pag_map.put(a, "alias", .{ .string = p.alias });
        try doc.put(a, "paginate", .{ .map = pag_map });
    }

    return .{ .map = doc };
}

// ── Tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

test "parsePageMeta: basic fields" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var p = try comb.parse(testing.allocator, "title: Hello\ndraft: true\n");
    defer p.deinit();

    const fm = @import("frontmatter.zig");
    const canonical = try fm.normalizeWigPageFrontmatter(a, p.value);
    const meta = try parsePageMeta(a, canonical);

    try testing.expectEqualStrings("Hello", meta.title.?);
    try testing.expect(meta.draft);
    try testing.expect(!meta.debug);
    try testing.expect(meta.search);
}

test "parsePageMeta: tags as list" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var p = try comb.parse(testing.allocator,
        \\title: Post
        \\tags:
        \\  - zig
        \\  - web
        \\
    );
    defer p.deinit();

    const fm = @import("frontmatter.zig");
    const canonical = try fm.normalizeWigPageFrontmatter(a, p.value);
    const meta = try parsePageMeta(a, canonical);

    try testing.expectEqual(@as(usize, 2), meta.tags.len);
    try testing.expectEqualStrings("zig", meta.tags[0]);
    try testing.expectEqualStrings("web", meta.tags[1]);
}

test "parsePageMeta: tags as single string" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var p = try comb.parse(testing.allocator, "tags: solo\n");
    defer p.deinit();

    const fm = @import("frontmatter.zig");
    const canonical = try fm.normalizeWigPageFrontmatter(a, p.value);
    const meta = try parsePageMeta(a, canonical);

    try testing.expectEqual(@as(usize, 1), meta.tags.len);
    try testing.expectEqualStrings("solo", meta.tags[0]);
}

test "parsePageMeta: paginate config" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var p = try comb.parse(testing.allocator,
        \\paginate:
        \\  collection: pages.posts
        \\  size: 5
        \\  path: p
        \\  alias: entries
        \\
    );
    defer p.deinit();

    const fm = @import("frontmatter.zig");
    const canonical = try fm.normalizeWigPageFrontmatter(a, p.value);
    const meta = try parsePageMeta(a, canonical);

    const pag = meta.paginate.?;
    try testing.expectEqualStrings("pages.posts", pag.collection);
    try testing.expectEqual(@as(usize, 5), pag.size);
    try testing.expectEqualStrings("p", pag.path);
    try testing.expectEqualStrings("entries", pag.alias);
}

test "parsePageMeta: cascade data" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var p = try comb.parse(testing.allocator,
        \\data:
        \\  document:
        \\    layout: post.html
        \\    style: blog
        \\  site:
        \\    nav: posts
        \\
    );
    defer p.deinit();

    const fm = @import("frontmatter.zig");
    const canonical = try fm.normalizeWigPageFrontmatter(a, p.value);
    const meta = try parsePageMeta(a, canonical);

    const cascade = meta.cascade.?;
    const doc = cascade.document.?;
    try testing.expectEqualStrings("post.html", doc.layout.?);
    try testing.expectEqualStrings("blog", doc.style.?);
    try testing.expect(cascade.site != null);
}

test "parsePageMeta: empty frontmatter" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const fm = @import("frontmatter.zig");
    const canonical = try fm.normalizeWigPageFrontmatter(a, .null_val);
    const meta = try parsePageMeta(a, canonical);

    try testing.expect(meta.title == null);
    try testing.expect(!meta.draft);
    try testing.expect(meta.search);
    try testing.expectEqual(@as(usize, 0), meta.tags.len);
}

test "parsePageMeta: search false" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var p = try comb.parse(testing.allocator, "search: false\n");
    defer p.deinit();

    const fm = @import("frontmatter.zig");
    const canonical = try fm.normalizeWigPageFrontmatter(a, p.value);
    const meta = try parsePageMeta(a, canonical);

    try testing.expect(!meta.search);
}

test "toTemplateValue: round-trip basic fields" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const meta = PageMeta{
        .title = "Hello",
        .layout = "page.html",
        .date = "2026-01-01",
        .tags = &.{ "zig", "web" },
        .draft = true,
    };

    const val = try toTemplateValue(a, meta);
    try testing.expect(val == .map);
    try testing.expectEqualStrings("Hello", val.map.get("title").?.string);
    try testing.expectEqualStrings("page.html", val.map.get("layout").?.string);
    try testing.expectEqualStrings("2026-01-01", val.map.get("date").?.string);
    try testing.expect(val.map.get("draft").?.boolean);
    try testing.expectEqual(@as(usize, 2), val.map.get("tags").?.list.len);
}

test "toTemplateValue: omits defaults" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const val = try toTemplateValue(a, .{});
    try testing.expect(val == .map);
    try testing.expect(val.map.get("title") == null);
    try testing.expect(val.map.get("draft") == null);
    try testing.expect(val.map.get("search") == null);
    try testing.expect(val.map.get("tags") == null);
}
