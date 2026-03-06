const std = @import("std");
const toupee = @import("toupee");

const Allocator = std.mem.Allocator;

pub const TocEntry = struct {
    level: u8,
    text: []const u8,
    id: []const u8,
};

/// Extracts table of contents from rendered HTML.
/// zjot puts id attributes on <section> elements wrapping headings.
/// Pattern: <section id="..."><hN>text</hN>
pub fn extract(a: Allocator, html: []const u8) ![]TocEntry {
    _ = a;
    _ = html;
    return error.NotImplemented;
}

/// Converts a ToC entry list to a Toupee Value list for template context.
pub fn toValue(a: Allocator, entries: []const TocEntry) !toupee.Value {
    _ = a;
    _ = entries;
    return error.NotImplemented;
}

test "toc: placeholder" {
    // Populated in Phase 6
}
