const std = @import("std");
const html = @import("html.zig");

const Allocator = std.mem.Allocator;
const fs = std.fs;

pub const SearchEntry = struct {
    url: []const u8,
    title: []const u8,
    content: []const u8,
    excerpt: []const u8,
    tags: []const []const u8,
    date: ?[]const u8,
    section: ?[]const u8,
};

/// Generates `search.json` in spec format (multi-line, 4-space field indent).
pub fn generateSearchJson(a: Allocator, entries: []const SearchEntry, output_dir: fs.Dir) !void {
    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(a);

    try buf.appendSlice(a, "[\n");
    for (entries, 0..) |entry, i| {
        if (i > 0) try buf.appendSlice(a, ",\n");
        try buf.appendSlice(a, "  {\n");
        try writeJsonObjectFieldLine(&buf, a, "    ", "url", entry.url);
        try writeJsonObjectFieldLine(&buf, a, "    ", "title", entry.title);
        try writeJsonObjectFieldLine(&buf, a, "    ", "content", entry.content);
        try writeJsonObjectFieldLine(&buf, a, "    ", "excerpt", entry.excerpt);
        try buf.appendSlice(a, "    \"tags\": [");
        for (entry.tags, 0..) |tag, j| {
            if (j > 0) try buf.appendSlice(a, ", ");
            try writeJsonString(&buf, a, tag);
        }
        try buf.appendSlice(a, "],\n");
        try buf.appendSlice(a, "    \"date\": ");
        if (entry.date) |d| try writeJsonString(&buf, a, d) else try buf.appendSlice(a, "null");
        try buf.appendSlice(a, ",\n    \"section\": ");
        if (entry.section) |s| try writeJsonString(&buf, a, s) else try buf.appendSlice(a, "null");
        try buf.appendSlice(a, "\n  }");
    }
    try buf.appendSlice(a, "\n]\n");

    var f = try output_dir.createFile("search.json", .{});
    defer f.close();
    try f.writeAll(buf.items);
}

fn writeJsonObjectFieldLine(buf: *std.ArrayListUnmanaged(u8), a: Allocator, indent: []const u8, key: []const u8, val: []const u8) !void {
    try buf.appendSlice(a, indent);
    try buf.append(a, '"');
    try buf.appendSlice(a, key);
    try buf.appendSlice(a, "\": ");
    try writeJsonString(buf, a, val);
    try buf.appendSlice(a, ",\n");
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
pub const stripHtml = html.stripTags;

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

