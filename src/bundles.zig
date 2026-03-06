const std = @import("std");
const toupee = @import("toupee");

const Allocator = std.mem.Allocator;

pub const BundleResult = struct {
    path: []const u8,
    hash: []const u8,
    content: []const u8,
};

/// Processes an asset bundle: expand globs, detect frontmatter,
/// render templates, concatenate, hash, write fingerprinted file.
pub fn processBundle(
    a: Allocator,
    style_name: []const u8,
    bundle_type: []const u8,
    bundle_name: []const u8,
    file_patterns: []const []const u8,
    styles_dir: []const u8,
    ctx: *const toupee.Context,
    output_dir: []const u8,
) !BundleResult {
    _ = a;
    _ = style_name;
    _ = bundle_type;
    _ = bundle_name;
    _ = file_patterns;
    _ = styles_dir;
    _ = ctx;
    _ = output_dir;
    return error.NotImplemented;
}

/// Expands a glob pattern relative to a base directory.
/// "compositions/*" -> sorted list of files in that directory.
pub fn expandGlob(a: Allocator, base_dir: []const u8, pattern: []const u8) ![][]const u8 {
    _ = a;
    _ = base_dir;
    _ = pattern;
    return error.NotImplemented;
}

test "bundles: placeholder" {
    // Populated in Phase 3
}
