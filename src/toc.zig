const std = @import("std");
const toupee = @import("toupee");
const html_mod = @import("html.zig");

const Allocator = std.mem.Allocator;
const ValueMap = std.StringArrayHashMapUnmanaged(toupee.Value);

pub const TocEntry = struct {
    level: u8,
    text: []const u8,
    id: []const u8,
};

/// Extracts table of contents from rendered HTML.
///
/// zjot puts `id` attributes on `<section>` elements wrapping headings.
/// Pattern: `<section id="..."><hN>text</hN>`
///
/// Also handles direct heading IDs: `<hN id="...">text</hN>`.
///
/// Returned entries borrow strings from `html`.
pub fn extract(a: Allocator, html: []const u8) ![]TocEntry {
    var entries: std.ArrayListUnmanaged(TocEntry) = .empty;

    var pos: usize = 0;
    while (pos < html.len) {
        if (html[pos] != '<') {
            pos += 1;
            continue;
        }

        if (try matchSectionWithHeading(a, html, pos)) |result| {
            try entries.append(a, result.entry);
            pos = result.end;
            continue;
        }

        if (try matchHeadingWithId(a, html, pos)) |result| {
            try entries.append(a, result.entry);
            pos = result.end;
            continue;
        }

        pos += 1;
    }

    return try entries.toOwnedSlice(a);
}

const MatchResult = struct {
    entry: TocEntry,
    end: usize,
};

/// Matches `<section id="..."><hN>text</hN>` pattern.
fn matchSectionWithHeading(a: Allocator, src: []const u8, start: usize) !?MatchResult {
    const section_prefix = "<section id=\"";
    if (start + section_prefix.len > src.len) return null;
    if (!std.mem.eql(u8, src[start .. start + section_prefix.len], section_prefix)) return null;

    const id_start = start + section_prefix.len;
    const id_end = std.mem.indexOfScalarPos(u8, src, id_start, '"') orelse return null;
    const id = src[id_start..id_end];

    // zjot renders `<section ...>\n<h1>` — allow whitespace between `>` and heading.
    var after_section = id_end + 2;
    while (after_section < src.len) : (after_section += 1) {
        switch (src[after_section]) {
            ' ', '\t', '\n', '\r' => continue,
            else => break,
        }
    }
    return try matchHeadingTag(a, src, after_section, id);
}

/// Matches `<hN id="...">text</hN>` pattern.
fn matchHeadingWithId(a: Allocator, src: []const u8, start: usize) !?MatchResult {
    if (start + 4 > src.len) return null;
    if (src[start] != '<' or src[start + 1] != 'h') return null;
    const level = std.fmt.charToDigit(src[start + 2], 10) catch return null;
    if (level < 1 or level > 6) return null;
    if (src[start + 3] != ' ') return null;

    const id_marker = "id=\"";
    const tag_end = std.mem.indexOfScalarPos(u8, src, start + 3, '>') orelse return null;
    const attrs = src[start + 3 .. tag_end];

    const id_pos = std.mem.indexOf(u8, attrs, id_marker) orelse return null;
    const id_start = id_pos + id_marker.len;
    const id_end = std.mem.indexOfScalarPos(u8, attrs, id_start, '"') orelse return null;
    const id = attrs[id_start..id_end];

    const text_start = tag_end + 1;
    const close_tag_start = std.mem.indexOfPos(u8, src, text_start, "</h") orelse return null;
    const text = try html_mod.stripTags(a, src[text_start..close_tag_start]);
    const end = close_tag_start + 5;

    return .{
        .entry = .{ .level = level, .text = text, .id = id },
        .end = if (end <= src.len) end else src.len,
    };
}

/// Matches `<hN>text</hN>` at position, using a pre-extracted id.
fn matchHeadingTag(a: Allocator, src: []const u8, pos: usize, id: []const u8) !?MatchResult {
    if (pos + 4 > src.len) return null;
    if (src[pos] != '<' or src[pos + 1] != 'h') return null;
    const level = std.fmt.charToDigit(src[pos + 2], 10) catch return null;
    if (level < 1 or level > 6) return null;
    if (src[pos + 3] != '>') return null;

    const text_start = pos + 4;
    const close_tag_start = std.mem.indexOfPos(u8, src, text_start, "</h") orelse return null;
    const text = try html_mod.stripTags(a, src[text_start..close_tag_start]);
    const end = close_tag_start + 5;

    return .{
        .entry = .{ .level = level, .text = text, .id = id },
        .end = if (end <= src.len) end else src.len,
    };
}

/// Converts a ToC entry list to a Toupee Value list for template context.
pub fn toValue(a: Allocator, entries: []const TocEntry) !toupee.Value {
    const items = try a.alloc(toupee.Value, entries.len);
    for (entries, 0..) |entry, i| {
        var map = ValueMap{};
        try map.put(a, "level", .{ .integer = @intCast(entry.level) });
        try map.put(a, "text", .{ .string = entry.text });
        // Fragment for <a href="…"> (HTML id attribute is bare; links use #id)
        const href_id = if (std.mem.startsWith(u8, entry.id, "#"))
            try a.dupe(u8, entry.id)
        else
            try std.fmt.allocPrint(a, "#{s}", .{entry.id});
        try map.put(a, "id", .{ .string = href_id });
        items[i] = .{ .map = map };
    }
    return .{ .list = items };
}

// ── Tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

test "extract: section-wrapped headings (zjot pattern)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src =
        \\<section id="intro"><h2>Introduction</h2><p>text</p></section>
        \\<section id="details"><h3>Details</h3><p>more</p></section>
    ;

    const entries = try extract(a, src);
    try testing.expectEqual(@as(usize, 2), entries.len);
    try testing.expectEqual(@as(u8, 2), entries[0].level);
    try testing.expectEqualStrings("Introduction", entries[0].text);
    try testing.expectEqualStrings("intro", entries[0].id);
    try testing.expectEqual(@as(u8, 3), entries[1].level);
    try testing.expectEqualStrings("Details", entries[1].text);
    try testing.expectEqualStrings("details", entries[1].id);
}

test "extract: heading with direct id" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src = "<h1 id=\"title\">Page Title</h1><p>body</p>";
    const entries = try extract(a, src);
    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqual(@as(u8, 1), entries[0].level);
    try testing.expectEqualStrings("Page Title", entries[0].text);
    try testing.expectEqualStrings("title", entries[0].id);
}

test "extract: no headings" {
    const entries = try extract(testing.allocator, "<p>No headings here.</p>");
    defer testing.allocator.free(entries);
    try testing.expectEqual(@as(usize, 0), entries.len);
}

test "extract: empty input" {
    const entries = try extract(testing.allocator, "");
    defer testing.allocator.free(entries);
    try testing.expectEqual(@as(usize, 0), entries.len);
}

test "extract: strips inner HTML tags from heading text" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src = "<h2 id=\"intro\">Hello <code>world</code></h2>";
    const entries = try extract(a, src);
    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqualStrings("Hello world", entries[0].text);
    try testing.expectEqualStrings("intro", entries[0].id);
}

test "toValue: converts entries to toupee list" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const entries = [_]TocEntry{
        .{ .level = 2, .text = "First", .id = "first" },
        .{ .level = 3, .text = "Second", .id = "second" },
    };

    const val = try toValue(a, &entries);
    try testing.expectEqual(@as(usize, 2), val.list.len);

    const first = val.list[0].map;
    try testing.expectEqual(@as(i64, 2), first.get("level").?.integer);
    try testing.expectEqualStrings("First", first.get("text").?.string);
    try testing.expectEqualStrings("#first", first.get("id").?.string);

    const second = val.list[1].map;
    try testing.expectEqualStrings("#second", second.get("id").?.string);
}
