const std = @import("std");

const Allocator = std.mem.Allocator;

pub const SearchEntry = struct {
    url: []const u8,
    title: []const u8,
    description: []const u8,
    body: []const u8,
    tags: []const []const u8,
    date: []const u8,
};

/// Generates search-index.json from rendered page content.
pub fn generate(a: Allocator, entries: []const SearchEntry, output_path: []const u8) !void {
    _ = a;
    _ = entries;
    _ = output_path;
    return error.NotImplemented;
}

/// Strips HTML tags from content, decodes common entities.
pub fn stripHtml(a: Allocator, html: []const u8) ![]const u8 {
    _ = a;
    _ = html;
    return error.NotImplemented;
}

/// Extracts the first <p>...</p> from HTML as a plain text excerpt.
pub fn extractExcerpt(a: Allocator, html: []const u8) !?[]const u8 {
    _ = a;
    _ = html;
    return error.NotImplemented;
}

const NotImplemented = error{NotImplemented};

test "search: placeholder" {
    // Populated in Phase 7
}
