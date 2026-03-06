const std = @import("std");
const toupee = @import("toupee");
const scanner_mod = @import("scanner.zig");

const Allocator = std.mem.Allocator;

/// Builds taxonomy reverse indexes from scanned page entries.
/// Returns a Toupee Value map: taxonomies.tags = { term -> [page, ...] }
pub fn buildIndex(
    a: Allocator,
    pages: []const scanner_mod.PageEntry,
    taxonomy_fields: []const []const u8,
) !toupee.Value {
    _ = a;
    _ = pages;
    _ = taxonomy_fields;
    return error.NotImplemented;
}

/// Slugifies a taxonomy term: lowercase, spaces to hyphens.
pub fn slugify(a: Allocator, term: []const u8) ![]const u8 {
    _ = a;
    _ = term;
    return error.NotImplemented;
}

const NotImplemented = error{NotImplemented};

test "taxonomies: placeholder" {
    // Populated in Phase 5
}
