const std = @import("std");

const Allocator = std.mem.Allocator;

/// Scaffolds a new Wig project at the given path.
pub fn init(a: Allocator, target_path: []const u8) !void {
    _ = a;
    _ = target_path;
    return error.NotImplemented;
}

/// Installs a style from wig-stand or a git URL.
pub fn install(a: Allocator, name_or_url: []const u8, target_path: []const u8, options: InstallOptions) !void {
    _ = a;
    _ = name_or_url;
    _ = target_path;
    _ = options;
    return error.NotImplemented;
}

pub const InstallOptions = struct {
    force: bool = false,
    include_pages: bool = false,
};

/// Creates a new empty style directory with a documented manifest.
pub fn addStyle(a: Allocator, styles_dir: []const u8, name: []const u8) !void {
    _ = a;
    _ = styles_dir;
    _ = name;
    return error.NotImplemented;
}

/// Creates a new block pattern (CSS + HTML template) in a style.
pub fn addBlock(a: Allocator, styles_dir: []const u8, style_name: []const u8, block_name: []const u8) !void {
    _ = a;
    _ = styles_dir;
    _ = style_name;
    _ = block_name;
    return error.NotImplemented;
}

test "scaffold: placeholder" {
    // Populated in Phase 12
}
