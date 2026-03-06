const std = @import("std");
const toupee = @import("toupee");

const Allocator = std.mem.Allocator;

pub const PageEntry = struct {
    source_path: []const u8,
    output_file: []const u8,
    url_path: []const u8,
    absolute_url: []const u8,
    content_body: []const u8,
    extension: []const u8,
    frontmatter: toupee.Value,
    is_section: bool = false,
    is_draft: bool = false,
    is_debug: bool = false,
};

pub const ScanResult = struct {
    pages: []const PageEntry,
    collections: toupee.Value.Map,
};

/// Walks the pages/ directory, parses frontmatter, builds collections,
/// detects sections, applies render gating, checks for path collisions.
pub fn scan(
    a: Allocator,
    pages_dir: []const u8,
    base_url: []const u8,
    site_draft: bool,
    site_debug: bool,
    registered_extensions: []const []const u8,
) !ScanResult {
    _ = a;
    _ = pages_dir;
    _ = base_url;
    _ = site_draft;
    _ = site_debug;
    _ = registered_extensions;
    return error.NotImplemented;
}

/// Derives the output file path from a source path using clean URL rules.
pub fn deriveOutputPath(a: Allocator, source_path: []const u8) ![]const u8 {
    _ = a;
    _ = source_path;
    return error.NotImplemented;
}

/// Derives the URL path from an output file path.
pub fn deriveUrlPath(output_file: []const u8) []const u8 {
    _ = output_file;
    return "/";
}

test "scanner: placeholder" {
    // Populated in Phase 4
}
