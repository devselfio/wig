const std = @import("std");

const Allocator = std.mem.Allocator;
const fs = std.fs;

pub const SearchEntry = struct {
    url: []const u8,
    title: []const u8,
    description: []const u8,
    body: []const u8,
    tags: []const []const u8,
    date: []const u8,
};

/// Generates `search-index.json` from rendered page content.
pub fn generate(a: Allocator, entries: []const SearchEntry, output_dir: fs.Dir) !void {
    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(a);

    try buf.appendSlice(a, "[\n");
    for (entries, 0..) |entry, i| {
        if (i > 0) try buf.appendSlice(a, ",\n");
        try buf.appendSlice(a, "  {");
        try writeJsonField(&buf, a, "url", entry.url, true);
        try writeJsonField(&buf, a, "title", entry.title, false);
        try writeJsonField(&buf, a, "description", entry.description, false);
        try writeJsonField(&buf, a, "body", entry.body, false);
        try writeJsonField(&buf, a, "date", entry.date, false);
        try buf.appendSlice(a, ", \"tags\": [");
        for (entry.tags, 0..) |tag, j| {
            if (j > 0) try buf.appendSlice(a, ", ");
            try writeJsonString(&buf, a, tag);
        }
        try buf.appendSlice(a, "]}");
    }
    try buf.appendSlice(a, "\n]\n");

    var f = try output_dir.createFile("search-index.json", .{});
    defer f.close();
    try f.writeAll(buf.items);
}

fn writeJsonField(buf: *std.ArrayListUnmanaged(u8), a: Allocator, key: []const u8, val: []const u8, first: bool) !void {
    if (!first) try buf.appendSlice(a, ", ");
    try buf.append(a, '"');
    try buf.appendSlice(a, key);
    try buf.appendSlice(a, "\": ");
    try writeJsonString(buf, a, val);
}

fn writeJsonString(buf: *std.ArrayListUnmanaged(u8), a: Allocator, s: []const u8) !void {
    try buf.append(a, '"');
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(a, "\\\""),
            '\\' => try buf.appendSlice(a, "\\\\"),
            '\n' => try buf.appendSlice(a, "\\n"),
            '\r' => try buf.appendSlice(a, "\\r"),
            '\t' => try buf.appendSlice(a, "\\t"),
            else => {
                if (c < 0x20) {
                    try buf.appendSlice(a, "\\u00");
                    const hex = "0123456789abcdef";
                    try buf.append(a, hex[c >> 4]);
                    try buf.append(a, hex[c & 0xf]);
                } else {
                    try buf.append(a, c);
                }
            },
        }
    }
    try buf.append(a, '"');
}

/// Strips HTML tags from content and decodes common entities.
pub fn stripHtml(a: Allocator, html: []const u8) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(a);

    var in_tag = false;
    var i: usize = 0;
    while (i < html.len) {
        if (html[i] == '<') {
            in_tag = true;
            i += 1;
            continue;
        }
        if (html[i] == '>') {
            in_tag = false;
            i += 1;
            continue;
        }
        if (in_tag) {
            i += 1;
            continue;
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

test "stripHtml: removes tags" {
    const a = testing.allocator;
    const r = try stripHtml(a, "<p>Hello <strong>world</strong>!</p>");
    defer a.free(r);
    try testing.expectEqualStrings("Hello world!", r);
}

test "stripHtml: decodes common entities" {
    const a = testing.allocator;
    const r = try stripHtml(a, "a &amp; b &lt; c &gt; d &quot;e&quot; f&apos;g");
    defer a.free(r);
    try testing.expectEqualStrings("a & b < c > d \"e\" f'g", r);
}

test "stripHtml: plain text unchanged" {
    const a = testing.allocator;
    const r = try stripHtml(a, "just plain text");
    defer a.free(r);
    try testing.expectEqualStrings("just plain text", r);
}

test "stripHtml: empty input" {
    const a = testing.allocator;
    const r = try stripHtml(a, "");
    defer a.free(r);
    try testing.expectEqualStrings("", r);
}

test "generate: produces valid JSON" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const tags = [_][]const u8{ "zig", "web" };
    const entries = [_]SearchEntry{
        .{
            .url = "https://example.com/hello/",
            .title = "Hello",
            .description = "A test post",
            .body = "Body text here.",
            .tags = &tags,
            .date = "2026-03-01",
        },
    };

    try generate(a, &entries, tmp.dir);

    const content = try tmp.dir.readFileAlloc(a, "search-index.json", 64 * 1024);
    defer a.free(content);

    try testing.expect(std.mem.indexOf(u8, content, "\"Hello\"") != null);
    try testing.expect(std.mem.indexOf(u8, content, "\"zig\"") != null);
    try testing.expect(std.mem.indexOf(u8, content, "\"web\"") != null);
}

test "generate: escapes special characters" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const entries = [_]SearchEntry{
        .{
            .url = "https://example.com/",
            .title = "He said \"hello\"",
            .description = "line1\nline2",
            .body = "a\\b",
            .tags = &.{},
            .date = "",
        },
    };

    try generate(a, &entries, tmp.dir);

    const content = try tmp.dir.readFileAlloc(a, "search-index.json", 64 * 1024);
    defer a.free(content);

    try testing.expect(std.mem.indexOf(u8, content, "\\\"hello\\\"") != null);
    try testing.expect(std.mem.indexOf(u8, content, "\\n") != null);
}
