const std = @import("std");
const Allocator = std.mem.Allocator;

/// Appends XML-escaped text to a buffer. Escapes &, <, >, and ".
pub fn appendXmlEscaped(buf: *std.ArrayListUnmanaged(u8), a: Allocator, text: []const u8) !void {
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

test "appendXmlEscaped: special chars" {
    const a = testing.allocator;
    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(a);

    try appendXmlEscaped(&buf, a, "a & b < c > d \"e\"");
    try testing.expectEqualStrings("a &amp; b &lt; c &gt; d &quot;e&quot;", buf.items);
}

test "appendXmlEscaped: plain text" {
    const a = testing.allocator;
    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(a);

    try appendXmlEscaped(&buf, a, "hello world");
    try testing.expectEqualStrings("hello world", buf.items);
}

test "appendXmlEscaped: empty" {
    const a = testing.allocator;
    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(a);

    try appendXmlEscaped(&buf, a, "");
    try testing.expectEqual(@as(usize, 0), buf.items.len);
}
