const std = @import("std");
const toupee = @import("toupee");
const scanner_mod = @import("scanner.zig");
const toc_mod = @import("toc.zig");
const context_mod = @import("context.zig");
const html = @import("html.zig");

const Allocator = std.mem.Allocator;
const ValueMap = std.StringArrayHashMapUnmanaged(toupee.Value);
const fs = std.fs;

pub const ContentParser = *const fn (Allocator, []const u8) anyerror![]const u8;

pub const ContentParserEntry = struct {
    extension: []const u8,
    parse: ContentParser,
};

pub const RenderResult = struct {
    output_html: []const u8,
    search_content: []const u8,
};

/// Renders a single page through the full pipeline:
///   1. Content parsing (dispatch by extension, .html = pass-through)
///   2. Shortcode rendering (Toupee pass on content HTML)
///   3. ToC extraction from rendered content
///   4. Excerpt extraction (first <p> or frontmatter description:)
///   5. Context building (data cascade + page.* + toc + excerpt)
///   6. Layout rendering through Toupee Engine (content as slot)
///
/// Returns the final HTML and the raw content HTML (for search indexing).
pub fn renderOne(
    a: Allocator,
    entry: *const scanner_mod.PageEntry,
    engine: *const toupee.Engine,
    base_ctx: *const toupee.Context,
    loader: toupee.Loader,
    content_parsers: []const ContentParserEntry,
) !RenderResult {
    const content_html = try parseContent(a, entry.content_body, entry.extension, content_parsers);
    const search_content = try a.dupe(u8, content_html);

    var resolver: toupee.Resolver = .{};
    const shortcoded = toupee.render(a, content_html, base_ctx, resolver.loader(), .{}) catch content_html;

    const toc_entries = try toc_mod.extract(a, shortcoded);
    const toc_value = try toc_mod.toValue(a, toc_entries);
    const excerpt = extractExcerpt(a, entry.frontmatter, shortcoded);

    var ctx = try toupee.Context.initFrom(a, base_ctx);
    try ctx.putAt("page.path", .{ .string = entry.url_path });
    try ctx.putAt("page.url", .{ .string = entry.absolute_url });
    try ctx.putAt("page.toc", toc_value);
    if (excerpt) |e| try ctx.putAt("page.excerpt", .{ .string = e });

    if (entry.frontmatter == .map) {
        var fm_it = entry.frontmatter.map.iterator();
        while (fm_it.next()) |fm_entry| {
            const key = try std.fmt.allocPrint(a, "page.{s}", .{fm_entry.key_ptr.*});
            try ctx.putAt(key, fm_entry.value_ptr.*);
        }
    }

    try ctx.setSlot("", shortcoded);

    const layout_name = getLayoutName(entry.frontmatter) orelse "default/page.html";
    const output_html = engine.renderTemplate(a, layout_name, &ctx, loader, .{}) catch |err| switch (err) {
        error.TemplateNotFound => return error.MissingTemplate,
        else => return err,
    };

    return .{
        .output_html = output_html,
        .search_content = search_content,
    };
}

/// Renders all pages sequentially. Parallel rendering (thread pool)
/// is deferred to a later step.
pub fn renderAll(
    a: Allocator,
    pages: []const scanner_mod.PageEntry,
    engine: *const toupee.Engine,
    base_ctx: *const toupee.Context,
    loader: toupee.Loader,
    content_parsers: []const ContentParserEntry,
    output_dir: fs.Dir,
) ![]RenderResult {
    const results = try a.alloc(RenderResult, pages.len);

    for (pages, 0..) |*page, i| {
        const result = try renderOne(a, page, engine, base_ctx, loader, content_parsers);

        output_dir.makePath(std.fs.path.dirname(page.output_file) orelse ".") catch {};
        var f = try output_dir.createFile(page.output_file, .{});
        defer f.close();
        try f.writeAll(result.output_html);

        results[i] = result;
    }

    return results;
}

/// Dispatches content to the appropriate parser by file extension.
/// `.html` files are pass-through (no parsing).
fn parseContent(
    a: Allocator,
    content: []const u8,
    extension: []const u8,
    parsers: []const ContentParserEntry,
) ![]const u8 {
    if (std.mem.eql(u8, extension, ".html")) return try a.dupe(u8, content);

    for (parsers) |parser| {
        if (std.mem.eql(u8, extension, parser.extension)) {
            return try parser.parse(a, content);
        }
    }

    return error.UnrecognisedExtension;
}

/// Extracts excerpt: frontmatter `description:` overrides, otherwise
/// first `<p>...</p>` from content HTML with inner tags stripped.
pub fn extractExcerptPublic(a: Allocator, fm: toupee.Value, content: []const u8) ?[]const u8 {
    return extractExcerpt(a, fm, content);
}

fn extractExcerpt(a: Allocator, fm: toupee.Value, content: []const u8) ?[]const u8 {
    if (fm == .map) {
        if (fm.map.get("description")) |desc| {
            if (desc == .string) return desc.string;
        }
    }

    const p_start = std.mem.indexOf(u8, content, "<p>") orelse return null;
    const text_start = p_start + 3;
    const p_end = std.mem.indexOfPos(u8, content, text_start, "</p>") orelse return null;
    return html.stripTags(a, content[text_start..p_end]) catch return null;
}

/// Splits a collection into paginated chunks and builds pagination context.
/// Returns one PaginationChunk per page (at least one, even for empty collections).
pub fn paginate(
    a: Allocator,
    items: []const toupee.Value,
    page_size: usize,
    base_path: []const u8,
    path_prefix: []const u8,
) ![]PaginationChunk {
    const size = if (page_size == 0) items.len else page_size;
    const total_pages = if (items.len == 0) 1 else (items.len + size - 1) / size;

    const chunks = try a.alloc(PaginationChunk, total_pages);
    for (0..total_pages) |i| {
        const start = i * size;
        const end = @min(start + size, items.len);
        const page_items = if (start < items.len) items[start..end] else &[_]toupee.Value{};
        const page_num = i + 1;

        const page_path = if (i == 0)
            try a.dupe(u8, base_path)
        else
            try std.fmt.allocPrint(a, "{s}{s}/{d}/", .{ base_path, path_prefix, page_num });

        var ctx_map = ValueMap{};
        try ctx_map.put(a, "items", .{ .list = page_items });
        try ctx_map.put(a, "page", .{ .integer = @intCast(page_num) });
        try ctx_map.put(a, "total_pages", .{ .integer = @intCast(total_pages) });

        if (i > 0) {
            var prev = ValueMap{};
            const prev_path = if (i == 1)
                try a.dupe(u8, base_path)
            else
                try std.fmt.allocPrint(a, "{s}{s}/{d}/", .{ base_path, path_prefix, i });
            try prev.put(a, "url", .{ .string = prev_path });
            try prev.put(a, "page", .{ .integer = @intCast(i) });
            try ctx_map.put(a, "previous", .{ .map = prev });
        }

        if (i < total_pages - 1) {
            var next = ValueMap{};
            const next_path = try std.fmt.allocPrint(a, "{s}{s}/{d}/", .{ base_path, path_prefix, page_num + 1 });
            try next.put(a, "url", .{ .string = next_path });
            try next.put(a, "page", .{ .integer = @intCast(page_num + 1) });
            try ctx_map.put(a, "next", .{ .map = next });
        }

        chunks[i] = .{
            .items = page_items,
            .context = .{ .map = ctx_map },
            .output_path = page_path,
        };
    }

    return chunks;
}

pub const PaginationChunk = struct {
    items: []const toupee.Value,
    context: toupee.Value,
    output_path: []const u8,
};

fn getLayoutName(fm: toupee.Value) ?[]const u8 {
    if (fm != .map) return null;
    const val = fm.map.get("layout") orelse return null;
    if (val != .string) return null;
    return val.string;
}

// ── Tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

fn mockParser(_: Allocator, source: []const u8) anyerror![]const u8 {
    return source;
}

test "parseContent: html pass-through" {
    const a = testing.allocator;
    const result = try parseContent(a, "<p>Hello</p>", ".html", &.{});
    defer a.free(result);
    try testing.expectEqualStrings("<p>Hello</p>", result);
}

test "parseContent: dispatches to registered parser" {
    const a = testing.allocator;
    const parsers = [_]ContentParserEntry{
        .{ .extension = ".dj", .parse = mockParser },
    };
    const result = try parseContent(a, "djot content", ".dj", &parsers);
    try testing.expectEqualStrings("djot content", result);
}

test "parseContent: unrecognised extension" {
    const result = parseContent(testing.allocator, "content", ".rst", &.{});
    try testing.expectError(error.UnrecognisedExtension, result);
}

test "extractExcerpt: from first paragraph" {
    const a = testing.allocator;
    const fm_empty: ValueMap = .{};
    const excerpt = extractExcerpt(a, .{ .map = fm_empty }, "<h1>Title</h1><p>First paragraph.</p><p>Second.</p>");
    defer a.free(excerpt.?);
    try testing.expectEqualStrings("First paragraph.", excerpt.?);
}

test "extractExcerpt: strips inner tags from paragraph" {
    const a = testing.allocator;
    const fm_empty: ValueMap = .{};
    const excerpt = extractExcerpt(a, .{ .map = fm_empty }, "<h1>Title</h1><p>Hello <em>world</em></p>");
    defer a.free(excerpt.?);
    try testing.expectEqualStrings("Hello world", excerpt.?);
}

test "extractExcerpt: frontmatter description overrides" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var map: ValueMap = .{};
    try map.put(a, "description", .{ .string = "Custom description" });

    const excerpt = extractExcerpt(a, .{ .map = map }, "<p>Ignored.</p>");
    try testing.expectEqualStrings("Custom description", excerpt.?);
}

test "extractExcerpt: no paragraphs returns null" {
    const fm_empty: ValueMap = .{};
    const excerpt = extractExcerpt(testing.allocator, .{ .map = fm_empty }, "<h1>Title only</h1>");
    try testing.expect(excerpt == null);
}

test "getLayoutName: from frontmatter" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var map: ValueMap = .{};
    try map.put(a, "layout", .{ .string = "default/post.html" });
    try testing.expectEqualStrings("default/post.html", getLayoutName(.{ .map = map }).?);
}

test "getLayoutName: missing returns null" {
    const map: ValueMap = .{};
    try testing.expect(getLayoutName(.{ .map = map }) == null);
}

test "paginate: splits into correct chunks" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const items = [_]toupee.Value{
        .{ .string = "a" }, .{ .string = "b" }, .{ .string = "c" },
        .{ .string = "d" }, .{ .string = "e" },
    };

    const chunks = try paginate(a, &items, 2, "/posts/", "page");
    try testing.expectEqual(@as(usize, 3), chunks.len);

    try testing.expectEqual(@as(usize, 2), chunks[0].items.len);
    try testing.expectEqual(@as(usize, 2), chunks[1].items.len);
    try testing.expectEqual(@as(usize, 1), chunks[2].items.len);

    try testing.expectEqual(@as(i64, 1), chunks[0].context.map.get("page").?.integer);
    try testing.expectEqual(@as(i64, 3), chunks[0].context.map.get("total_pages").?.integer);
}

test "paginate: empty collection produces 1 page" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const chunks = try paginate(a, &.{}, 5, "/posts/", "page");
    try testing.expectEqual(@as(usize, 1), chunks.len);
    try testing.expectEqual(@as(usize, 0), chunks[0].items.len);
    try testing.expectEqual(@as(i64, 1), chunks[0].context.map.get("total_pages").?.integer);
}

test "paginate: previous/next links" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const items = [_]toupee.Value{
        .{ .string = "a" }, .{ .string = "b" }, .{ .string = "c" },
    };

    const chunks = try paginate(a, &items, 1, "/posts/", "page");
    try testing.expectEqual(@as(usize, 3), chunks.len);

    try testing.expect(chunks[0].context.map.get("previous") == null);
    try testing.expect(chunks[0].context.map.get("next") != null);

    try testing.expect(chunks[1].context.map.get("previous") != null);
    try testing.expect(chunks[1].context.map.get("next") != null);

    try testing.expect(chunks[2].context.map.get("previous") != null);
    try testing.expect(chunks[2].context.map.get("next") == null);
}

test "paginate: first page uses base path" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const items = [_]toupee.Value{ .{ .string = "a" }, .{ .string = "b" } };
    const chunks = try paginate(a, &items, 1, "/posts/", "page");

    try testing.expectEqualStrings("/posts/", chunks[0].output_path);
    try testing.expectEqualStrings("/posts/page/2/", chunks[1].output_path);
}
