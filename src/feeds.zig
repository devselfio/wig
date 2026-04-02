const std = @import("std");
const scanner_mod = @import("scanner.zig");
const config_mod = @import("config.zig");
const page_meta_mod = @import("page_meta.zig");

const Allocator = std.mem.Allocator;
const fs = std.fs;

/// Generates an Atom feed XML for a named feed from a collection of pages.
/// `rendered_content` maps page source paths to their rendered HTML content bodies.
pub fn generateAtom(
    a: Allocator,
    feed_config: config_mod.FeedConfig,
    pages: []const scanner_mod.PageEntry,
    site_url: []const u8,
    site_title: []const u8,
    site_author: []const u8,
    output_dir: fs.Dir,
    rendered_content: ?std.StringArrayHashMapUnmanaged([]const u8),
) !void {
    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(a);

    try buf.appendSlice(a, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n");
    try buf.appendSlice(a, "<feed xmlns=\"http://www.w3.org/2005/Atom\">\n");

    try buf.appendSlice(a, "  <title>");
    try appendXmlEscaped(&buf, a, feed_config.title);
    try buf.appendSlice(a, "</title>\n");

    const base = if (site_url.len > 0 and site_url[site_url.len - 1] == '/') site_url[0 .. site_url.len - 1] else site_url;
    try buf.appendSlice(a, "  <link href=\"");
    try appendXmlEscaped(&buf, a, site_url);
    if (site_url.len == 0 or site_url[site_url.len - 1] != '/') try buf.append(a, '/');
    try buf.appendSlice(a, "\" />\n");

    const feed_path = try std.fmt.allocPrint(a, "feeds/{s}.xml", .{feed_config.name});
    defer a.free(feed_path);
    const feed_self_url = try std.fmt.allocPrint(a, "{s}/{s}", .{ base, feed_path });
    defer a.free(feed_self_url);
    try buf.appendSlice(a, "  <link href=\"");
    try appendXmlEscaped(&buf, a, feed_self_url);
    try buf.appendSlice(a, "\" rel=\"self\" />\n");

    // RFC 4287 required: <id>
    try buf.appendSlice(a, "  <id>");
    try appendXmlEscaped(&buf, a, feed_self_url);
    try buf.appendSlice(a, "</id>\n");

    try buf.appendSlice(a, "  <author><name>");
    try appendXmlEscaped(&buf, a, if (site_author.len > 0) site_author else site_title);
    try buf.appendSlice(a, "</name></author>\n");

    var feed_pages = std.ArrayListUnmanaged(*const scanner_mod.PageEntry){};
    for (pages) |*page| {
        if (!matchesFeed(page.*, feed_config)) continue;
        if (page.is_section) continue;
        try feed_pages.append(a, page);
    }
    std.mem.sort(*const scanner_mod.PageEntry, feed_pages.items, {}, struct {
        fn lessThan(_: void, lhs: *const scanner_mod.PageEntry, rhs: *const scanner_mod.PageEntry) bool {
            const l_date = lhs.meta.date orelse "";
            const r_date = rhs.meta.date orelse "";
            return std.mem.order(u8, r_date, l_date) == .lt;
        }
    }.lessThan);

    if (feed_pages.items.len > 0) {
        const newest = feed_pages.items[0];
        const updated = newest.meta.date orelse "";
        if (updated.len > 0) {
            try buf.appendSlice(a, "  <updated>");
            try appendXmlEscaped(&buf, a, updated);
            try buf.appendSlice(a, "</updated>\n");
        }
    }

    for (feed_pages.items) |page| {
        try buf.appendSlice(a, "  <entry>\n");

        const title = page.meta.title orelse page.source_path;
        try buf.appendSlice(a, "    <title>");
        try appendXmlEscaped(&buf, a, title);
        try buf.appendSlice(a, "</title>\n");

        try buf.appendSlice(a, "    <link href=\"");
        try appendXmlEscaped(&buf, a, page.absolute_url);
        try buf.appendSlice(a, "\" />\n");

        try buf.appendSlice(a, "    <id>");
        try appendXmlEscaped(&buf, a, page.absolute_url);
        try buf.appendSlice(a, "</id>\n");

        if (page.meta.date) |date| {
            try buf.appendSlice(a, "    <updated>");
            try appendXmlEscaped(&buf, a, date);
            try buf.appendSlice(a, "</updated>\n");
        }

        if (page.meta.description) |summary| {
            try buf.appendSlice(a, "    <summary>");
            try appendXmlEscaped(&buf, a, summary);
            try buf.appendSlice(a, "</summary>\n");
        }

        // RFC 4287 recommended: <content type="html">
        if (rendered_content) |rc| {
            if (rc.get(page.source_path)) |html| {
                try buf.appendSlice(a, "    <content type=\"html\">");
                try appendXmlEscaped(&buf, a, html);
                try buf.appendSlice(a, "</content>\n");
            }
        }

        try buf.appendSlice(a, "  </entry>\n");
    }

    try buf.appendSlice(a, "</feed>\n");

    output_dir.makePath("feeds") catch {};
    const out_path = try std.fmt.allocPrint(a, "feeds/{s}.xml", .{feed_config.name});
    defer a.free(out_path);

    var f = try output_dir.createFile(out_path, .{});
    defer f.close();
    try f.writeAll(buf.items);
}

/// Generates sitemap.xml from all rendered pages.
pub fn generateSitemap(
    a: Allocator,
    pages: []const scanner_mod.PageEntry,
    output_dir: fs.Dir,
) !void {
    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(a);

    try buf.appendSlice(a, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n");
    try buf.appendSlice(a, "<urlset xmlns=\"http://www.sitemaps.org/schemas/sitemap/0.9\">\n");

    var indices = try a.alloc(usize, pages.len);
    defer a.free(indices);
    for (0..pages.len) |i| indices[i] = i;
    std.mem.sort(usize, indices, pages, struct {
        fn lessThan(ctx: []const scanner_mod.PageEntry, lhs: usize, rhs: usize) bool {
            return std.mem.order(u8, ctx[lhs].url_path, ctx[rhs].url_path) == .lt;
        }
    }.lessThan);

    for (indices) |i| {
        const page = &pages[i];
        try buf.appendSlice(a, "  <url>\n    <loc>");
        try appendXmlEscaped(&buf, a, page.absolute_url);
        try buf.appendSlice(a, "</loc>");
        if (page.meta.date) |date| {
            try buf.appendSlice(a, "\n    <lastmod>");
            try appendXmlEscaped(&buf, a, date);
            try buf.appendSlice(a, "</lastmod>");
        }
        try buf.appendSlice(a, "\n  </url>\n");
    }

    try buf.appendSlice(a, "</urlset>\n");

    var f = try output_dir.createFile("sitemap.xml", .{});
    defer f.close();
    try f.writeAll(buf.items);
}

fn matchesFeed(page: scanner_mod.PageEntry, feed_config: config_mod.FeedConfig) bool {
    if (feed_config.collection_path.len > 0) {
        return std.mem.eql(u8, page.collection_key, feed_config.collection_path);
    }
    for (page.meta.feeds) |feed_name| {
        if (std.mem.eql(u8, feed_name, feed_config.name)) return true;
    }
    return false;
}

fn appendXmlEscaped(buf: *std.ArrayListUnmanaged(u8), a: Allocator, text: []const u8) !void {
    for (text) |c| {
        switch (c) {
            '&' => try buf.appendSlice(a, "&amp;"),
            '<' => try buf.appendSlice(a, "&lt;"),
            '>' => try buf.appendSlice(a, "&gt;"),
            '"' => try buf.appendSlice(a, "&quot;"),
            else => try buf.append(a, c),
        }
    }
}

// ── Tests ───────────────────────────────────────────────────────────────

const testing = std.testing;
const toupee = @import("toupee");
const ValueMap = std.StringArrayHashMapUnmanaged(toupee.Value);

test "generateAtom: produces valid Atom XML" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var fm = ValueMap{};
    try fm.put(a, "title", .{ .string = "First Post" });
    try fm.put(a, "date", .{ .string = "2026-03-01" });

    const pages = [_]scanner_mod.PageEntry{
        .{
            .source_path = "posts/first.dj",
            .output_file = "posts/first/index.html",
            .url_path = "/posts/first/",
            .absolute_url = "https://example.com/posts/first/",
            .content_body = "",
            .extension = ".dj",
            .raw_frontmatter = .{ .map = fm },
            .collection_key = "pages.posts",
            .meta = .{ .title = "First Post", .date = "2026-03-01" },
        },
    };

    const feed_cfg = config_mod.FeedConfig{
        .name = "blog",
        .collection_path = "pages.posts",
        .title = "Blog Feed",
    };

    try generateAtom(a, feed_cfg, &pages, "https://example.com", "My Site", "My Site", tmp.dir, null);

    const content = try tmp.dir.readFileAlloc(a, "feeds/blog.xml", 64 * 1024);
    try testing.expect(std.mem.indexOf(u8, content, "<feed xmlns=") != null);
    try testing.expect(std.mem.indexOf(u8, content, "First Post") != null);
    try testing.expect(std.mem.indexOf(u8, content, "<updated>2026-03-01</updated>") != null);
    try testing.expect(std.mem.indexOf(u8, content, "<id>") != null);
}

test "generateAtom: filters by collection" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var fm1 = ValueMap{};
    try fm1.put(a, "title", .{ .string = "Post" });
    var fm2 = ValueMap{};
    try fm2.put(a, "title", .{ .string = "Tutorial" });

    const pages = [_]scanner_mod.PageEntry{
        .{
            .source_path = "posts/p.dj",
            .output_file = "posts/p/index.html",
            .url_path = "/posts/p/",
            .absolute_url = "https://example.com/posts/p/",
            .content_body = "",
            .extension = ".dj",
            .raw_frontmatter = .{ .map = fm1 },
            .collection_key = "pages.posts",
            .meta = .{ .title = "Post" },
        },
        .{
            .source_path = "tutorials/t.dj",
            .output_file = "tutorials/t/index.html",
            .url_path = "/tutorials/t/",
            .absolute_url = "https://example.com/tutorials/t/",
            .content_body = "",
            .extension = ".dj",
            .raw_frontmatter = .{ .map = fm2 },
            .collection_key = "pages.tutorials",
            .meta = .{ .title = "Tutorial" },
        },
    };

    const feed_cfg = config_mod.FeedConfig{
        .name = "blog",
        .collection_path = "pages.posts",
        .title = "Blog",
    };

    try generateAtom(a, feed_cfg, &pages, "https://example.com", "Site", "Site", tmp.dir, null);

    const content = try tmp.dir.readFileAlloc(a, "feeds/blog.xml", 64 * 1024);
    try testing.expect(std.mem.indexOf(u8, content, "Post") != null);
    try testing.expect(std.mem.indexOf(u8, content, "Tutorial") == null);
}

test "generateSitemap: produces valid XML" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var fm = ValueMap{};
    try fm.put(a, "title", .{ .string = "Page" });

    const pages = [_]scanner_mod.PageEntry{
        .{
            .source_path = "about.dj",
            .output_file = "about/index.html",
            .url_path = "/about/",
            .absolute_url = "https://example.com/about/",
            .content_body = "",
            .extension = ".dj",
            .raw_frontmatter = .{ .map = fm },
            .collection_key = "pages",
        },
    };

    try generateSitemap(a, &pages, tmp.dir);

    const content = try tmp.dir.readFileAlloc(a, "sitemap.xml", 64 * 1024);
    try testing.expect(std.mem.indexOf(u8, content, "<urlset xmlns=") != null);
    try testing.expect(std.mem.indexOf(u8, content, "https://example.com/about/") != null);
}

test "generateSitemap: empty pages" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try generateSitemap(a, &.{}, tmp.dir);

    const content = try tmp.dir.readFileAlloc(a, "sitemap.xml", 64 * 1024);
    defer a.free(content);
    try testing.expect(std.mem.indexOf(u8, content, "<urlset") != null);
    try testing.expect(std.mem.indexOf(u8, content, "</urlset>") != null);
}

test "appendXmlEscaped: escapes special chars" {
    const a = testing.allocator;
    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(a);

    try appendXmlEscaped(&buf, a, "a & b < c > d \"e\"");
    try testing.expectEqualStrings("a &amp; b &lt; c &gt; d &quot;e&quot;", buf.items);
}
