const std = @import("std");
const scanner_mod = @import("scanner.zig");

const Allocator = std.mem.Allocator;

pub const PatternDoc = struct {
    name: []const u8,
    description: []const u8,
    custom_properties: []const []const u8,
    exceptions: []const []const u8,
    source_file: []const u8,
};

/// Parses CSS doc comments from a CSS file.
pub fn parseDocComments(a: Allocator, css_source: []const u8, source_file: []const u8) ![]PatternDoc {
    _ = a;
    _ = css_source;
    _ = source_file;
    return error.NotImplemented;
}

/// Generates virtual PageEntry structs for pattern library pages.
pub fn generatePages(a: Allocator, docs: []const PatternDoc, style_name: []const u8) ![]scanner_mod.PageEntry {
    _ = a;
    _ = docs;
    _ = style_name;
    return error.NotImplemented;
}

const NotImplemented = error{NotImplemented};

test "patterns: placeholder" {
    // Populated in Phase 9
}
