//! Single source of truth for build output locations under the site root.
//!
//! Convention: static site output lives at `<site_root>/zig-out/site/`. The parent
//! `zig-out/` exists for Zig's install layout and spec-test workspace paths.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Directory name directly under the site root for Zig build/install artifacts.
pub const zig_out_dir_name = "zig-out";

/// Directory name under `zig_out_dir_name` where HTML, assets, and bundles are written.
pub const site_output_dir_name = "site";

/// Default relative path from site root to the built site (for CLI/spec defaults).
pub const default_site_output_rel = zig_out_dir_name ++ "/" ++ site_output_dir_name;

/// Default relative path for spec test workspace files under the site root.
pub const default_test_workspace_rel = zig_out_dir_name ++ "/test";

/// Returns owned path `<abs_site_root>/zig-out`. Caller frees with `allocator`.
pub fn joinZigOutDirAbs(allocator: Allocator, abs_site_root: []const u8) ![]const u8 {
    return std.fs.path.join(allocator, &.{ abs_site_root, zig_out_dir_name });
}

/// Returns owned path `<abs_site_root>/zig-out/site`. Caller frees with `allocator`.
pub fn joinSiteOutputDirAbs(allocator: Allocator, abs_site_root: []const u8) ![]const u8 {
    return std.fs.path.join(allocator, &.{ abs_site_root, zig_out_dir_name, site_output_dir_name });
}

/// Ensures `zig-out/` and `zig-out/site/` exist under `abs_site_root`.
/// If `clean`, deletes the site output tree first (full rebuild of output).
/// Returns an open handle to `zig-out/site`. Caller must `close()` it.
pub fn prepareSiteOutput(allocator: Allocator, io: std.Io, abs_site_root: []const u8, clean: bool) !std.Io.Dir {
    const site_path = try joinSiteOutputDirAbs(allocator, abs_site_root);
    defer allocator.free(site_path);
    const parent_path = try joinZigOutDirAbs(allocator, abs_site_root);
    defer allocator.free(parent_path);

    if (clean) {
        std.Io.Dir.deleteTree(std.Io.Dir.cwd(), io, site_path) catch {};
    }

    std.Io.Dir.createDirAbsolute(io, parent_path, .default_dir) catch {};
    std.Io.Dir.createDirAbsolute(io, site_path, .default_dir) catch {};

    return try std.Io.Dir.openDirAbsolute(io, site_path, .{ .iterate = true });
}

test "output_paths join absolute paths" {
    const a = std.testing.allocator;
    const site = try joinSiteOutputDirAbs(a, "/tmp/wig-fixture");
    defer a.free(site);
    try std.testing.expect(std.mem.endsWith(u8, site, "site"));
    try std.testing.expect(std.mem.indexOf(u8, site, "zig-out") != null);
    const zig_out = try joinZigOutDirAbs(a, "/tmp/wig-fixture");
    defer a.free(zig_out);
    try std.testing.expect(std.mem.endsWith(u8, zig_out, "zig-out"));
}
