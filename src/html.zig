const std = @import("std");

const Allocator = std.mem.Allocator;

/// Strips HTML tags and decodes common entities, returning plain text.
///
/// Used by excerpt extraction (pages.zig), ToC heading text (toc.zig),
/// and search index body content (search.zig).
pub fn stripTags(a: Allocator, html: []const u8) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(a);

    var i: usize = 0;
    while (i < html.len) {
        if (html[i] == '<') {
            const gt = std.mem.indexOfScalarPos(u8, html, i + 1, '>');
            if (gt) |pos| {
                i = pos + 1;
                continue;
            }
            // Unclosed tag: treat as literal
            while (i < html.len) {
                try buf.append(a, html[i]);
                i += 1;
            }
            break;
        }

        if (html[i] == '&') {
            if (decodeEntity(html, i)) |result| {
                try buf.append(a, result.char);
                i = result.end;
                continue;
            }
        }

        try buf.append(a, html[i]);
        i += 1;
    }

    return try a.dupe(u8, buf.items);
}

const EntityResult = struct { char: u8, end: usize };

fn decodeEntity(html: []const u8, start: usize) ?EntityResult {
    const entities = .{
        .{ "&amp;", '&' },
        .{ "&lt;", '<' },
        .{ "&gt;", '>' },
        .{ "&quot;", '"' },
        .{ "&apos;", '\'' },
        .{ "&#39;", '\'' },
    };
    inline for (entities) |pair| {
        if (start + pair[0].len <= html.len and
            std.mem.eql(u8, html[start .. start + pair[0].len], pair[0]))
        {
            return .{ .char = pair[1], .end = start + pair[0].len };
        }
    }
    return null;
}

// ── Tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

test "stripTags: removes tags" {
    const a = testing.allocator;
    const r = try stripTags(a, "<p>Hello <strong>world</strong>!</p>");
    defer a.free(r);
    try testing.expectEqualStrings("Hello world!", r);
}

test "stripTags: decodes common entities" {
    const a = testing.allocator;
    const r = try stripTags(a, "a &amp; b &lt; c &gt; d &quot;e&quot; f&apos;g");
    defer a.free(r);
    try testing.expectEqualStrings("a & b < c > d \"e\" f'g", r);
}

test "stripTags: plain text unchanged" {
    const a = testing.allocator;
    const r = try stripTags(a, "just plain text");
    defer a.free(r);
    try testing.expectEqualStrings("just plain text", r);
}

test "stripTags: empty input" {
    const a = testing.allocator;
    const r = try stripTags(a, "");
    defer a.free(r);
    try testing.expectEqualStrings("", r);
}

test "stripTags: nested tags" {
    const a = testing.allocator;
    const r = try stripTags(a, "<div><p><em>text</em></p></div>");
    defer a.free(r);
    try testing.expectEqualStrings("text", r);
}

test "stripTags: self-closing tags" {
    const a = testing.allocator;
    const r = try stripTags(a, "text<br/>more");
    defer a.free(r);
    try testing.expectEqualStrings("textmore", r);
}

test "stripTags: unclosed tag treated as literal" {
    const a = testing.allocator;
    const r = try stripTags(a, "text<div no close");
    defer a.free(r);
    try testing.expectEqualStrings("text<div no close", r);
}
