const std = @import("std");
const scanner_mod = @import("scanner.zig");

const Allocator = std.mem.Allocator;

pub const FeedConfig = struct {
    name: []const u8,
    collection_path: []const u8,
    title: []const u8,
};

/// Generates Atom feed XML for a named feed from a collection.
pub fn generateAtom(
    a: Allocator,
    feed_config: FeedConfig,
    pages: []const scanner_mod.PageEntry,
    site_url: []const u8,
    output_path: []const u8,
) !void {
    _ = a;
    _ = feed_config;
    _ = pages;
    _ = site_url;
    _ = output_path;
    return error.NotImplemented;
}

/// Generates sitemap.xml from all rendered pages.
pub fn generateSitemap(
    a: Allocator,
    pages: []const scanner_mod.PageEntry,
    site_url: []const u8,
    output_path: []const u8,
) !void {
    _ = a;
    _ = pages;
    _ = site_url;
    _ = output_path;
    return error.NotImplemented;
}

const NotImplemented = error{NotImplemented};

test "feeds: placeholder" {
    // Populated in Phase 7
}
