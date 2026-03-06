const std = @import("std");
const toupee = @import("toupee");

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
    var entries: std.ArrayListUnmanaged(TocEntry) = .{};

    var pos: usize = 0;
    while (pos < html.len) {
        if (html[pos] != '<') {
            pos += 1;
            continue;
        }

        if (matchSectionWithHeading(html, pos)) |result| {
            try entries.append(a, result.entry);
            pos = result.end;
            continue;
        }

        if (matchHeadingWithId(html, pos)) |result| {
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
fn matchSectionWithHeading(html: []const u8, start: usize) ?MatchResult {
    const section_prefix = "<section id=\"";
    if (start + section_prefix.len > html.len) return null;
    if (!std.mem.eql(u8, html[start .. start + section_prefix.len], section_prefix)) return null;

    const id_start = start + section_prefix.len;
    const id_end = std.mem.indexOfScalarPos(u8, html, id_start, '"') orelse return null;
    const id = html[id_start..id_end];

    const after_section = id_end + 2;
    return matchHeadingTag(html, after_section, id);
}

/// Matches `<hN id="...">text</hN>` pattern.
fn matchHeadingWithId(html: []const u8, start: usize) ?MatchResult {
    if (start + 4 > html.len) return null;
    if (html[start] != '<' or html[start + 1] != 'h') return null;
    const level = std.fmt.charToDigit(html[start + 2], 10) catch return null;
    if (level < 1 or level > 6) return null;
    if (html[start + 3] != ' ') return null;

    const id_marker = "id=\"";
    const tag_end = std.mem.indexOfScalarPos(u8, html, start + 3, '>') orelse return null;
    const attrs = html[start + 3 .. tag_end];

    const id_pos = std.mem.indexOf(u8, attrs, id_marker) orelse return null;
    const id_start = id_pos + id_marker.len;
    const id_end = std.mem.indexOfScalarPos(u8, attrs, id_start, '"') orelse return null;
    const id = attrs[id_start..id_end];

    const text_start = tag_end + 1;
    const close_tag_start = std.mem.indexOfPos(u8, html, text_start, "</h") orelse return null;
    const text = stripHtmlTags(html[text_start..close_tag_start]);
    const end = close_tag_start + 5;

    return .{
        .entry = .{ .level = level, .text = text, .id = id },
        .end = if (end <= html.len) end else html.len,
    };
}

/// Matches `<hN>text</hN>` at position, using a pre-extracted id.
fn matchHeadingTag(html: []const u8, pos: usize, id: []const u8) ?MatchResult {
    if (pos + 4 > html.len) return null;
    if (html[pos] != '<' or html[pos + 1] != 'h') return null;
    const level = std.fmt.charToDigit(html[pos + 2], 10) catch return null;
    if (level < 1 or level > 6) return null;
    if (html[pos + 3] != '>') return null;

    const text_start = pos + 4;
    const close_tag_start = std.mem.indexOfPos(u8, html, text_start, "</h") orelse return null;
    const text = stripHtmlTags(html[text_start..close_tag_start]);
    const end = close_tag_start + 5;

    return .{
        .entry = .{ .level = level, .text = text, .id = id },
        .end = if (end <= html.len) end else html.len,
    };
}

/// Strips inner HTML tags from heading text, returning only text content.
/// Operates on a slice of the input (no allocation).
fn stripHtmlTags(html: []const u8) []const u8 {
    var depth: usize = 0;
    for (html) |c| {
        if (c == '<') depth += 1;
        if (depth > 0) {
            if (c == '>') depth -= 1;
            continue;
        }
        break;
    }
    if (depth > 0) return html;
    return html;
}

/// Converts a ToC entry list to a Toupee Value list for template context.
pub fn toValue(a: Allocator, entries: []const TocEntry) !toupee.Value {
    const items = try a.alloc(toupee.Value, entries.len);
    for (entries, 0..) |entry, i| {
        var map = ValueMap{};
        try map.put(a, "level", .{ .integer = @intCast(entry.level) });
        try map.put(a, "text", .{ .string = entry.text });
        try map.put(a, "id", .{ .string = entry.id });
        items[i] = .{ .map = map };
    }
    return .{ .list = items };
}

// ── Tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

test "extract: section-wrapped headings (zjot pattern)" {
    const html =
        \\<section id="intro"><h2>Introduction</h2><p>text</p></section>
        \\<section id="details"><h3>Details</h3><p>more</p></section>
    ;

    const entries = try extract(testing.allocator, html);
    defer testing.allocator.free(entries);

    try testing.expectEqual(@as(usize, 2), entries.len);
    try testing.expectEqual(@as(u8, 2), entries[0].level);
    try testing.expectEqualStrings("Introduction", entries[0].text);
    try testing.expectEqualStrings("intro", entries[0].id);
    try testing.expectEqual(@as(u8, 3), entries[1].level);
    try testing.expectEqualStrings("Details", entries[1].text);
    try testing.expectEqualStrings("details", entries[1].id);
}

test "extract: heading with direct id" {
    const html = "<h1 id=\"title\">Page Title</h1><p>body</p>";

    const entries = try extract(testing.allocator, html);
    defer testing.allocator.free(entries);

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
    try testing.expectEqualStrings("first", first.get("id").?.string);
}
