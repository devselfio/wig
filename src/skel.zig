//! Embedded skeleton archives (`src/skel/<term>.tar`) and pack/repack helpers.
//! Maintainer: run `zig build skel` after editing `skel/<term>/`, then commit the tarballs; `tar` on PATH.

const std = @import("std");
const fs = std.fs;

pub const terms = [_][]const u8{"site"};

/// Default skeleton used by `wig init` (must match an entry in `terms`).
pub const default_init_term = "site";

/// Returns true if `term` is a known skeleton name.
pub fn isValidTerm(term: []const u8) bool {
    for (terms) |t| {
        if (std.mem.eql(u8, term, t)) return true;
    }
    return false;
}

fn embeddedTarBytes(term: []const u8) error{UnknownTerm}![]const u8 {
    if (std.mem.eql(u8, term, "site")) {
        return @embedFile("skel/site.tar");
    }
    return error.UnknownTerm;
}

/// Extracts the embedded tarball for `term` into `target_path` (directory is created if needed).
pub fn unpack(a: std.mem.Allocator, term: []const u8, target_path: []const u8) !void {
    if (!isValidTerm(term)) return error.UnknownTerm;

    fs.cwd().makePath(target_path) catch {};
    const abs = try fs.realpathAlloc(a, target_path);
    defer a.free(abs);

    var dst = try fs.openDirAbsolute(abs, .{});
    defer dst.close();

    const bytes = try embeddedTarBytes(term);
    var reader: std.Io.Reader = .fixed(bytes);
    // Archive paths are `./pages/...`, `./data/...` (BSD/macOS `tar` prefix).
    try std.tar.pipeToFileSystem(dst, &reader, .{ .strip_components = 0 });
}

/// Creates `src/skel/<term>.tar` from `skel/<term>/`. `wig_root` must be the wig repository root (absolute).
pub fn pack(a: std.mem.Allocator, wig_root: []const u8, term: []const u8) !void {
    if (!isValidTerm(term)) return error.UnknownTerm;

    const out_rel = try std.fmt.allocPrint(a, "src/skel/{s}.tar", .{term});
    defer a.free(out_rel);
    const skel_rel = try std.fmt.allocPrint(a, "skel/{s}", .{term});
    defer a.free(skel_rel);

    var env = try std.process.getEnvMap(a);
    defer env.deinit();
    try env.put("COPYFILE_DISABLE", "1");

    var child = std.process.Child.init(&.{ "tar", "-cf", out_rel, "-C", skel_rel, "." }, a);
    child.cwd = wig_root;
    child.env_map = &env;

    const term_res = try child.spawnAndWait();
    switch (term_res) {
        .Exited => |code| {
            if (code != 0) return error.TarFailed;
        },
        else => return error.TarFailed,
    }
}

fn maxFileMtime(a: std.mem.Allocator, abs_dir: []const u8) !i128 {
    var dir = try fs.openDirAbsolute(abs_dir, .{ .iterate = true });
    defer dir.close();

    var max: i128 = 0;
    var walker = try dir.walk(a);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        const st = try entry.dir.statFile(entry.basename);
        if (st.mtime > max) max = st.mtime;
    }
    return max;
}

/// If `src/skel/<term>.tar` is missing or older than any file under `skel/<term>/`, delete the tarball and `pack`.
pub fn repack(a: std.mem.Allocator, wig_root: []const u8, term: []const u8) !void {
    if (!isValidTerm(term)) return error.UnknownTerm;

    const src_abs = try fs.path.join(a, &.{ wig_root, "skel", term });
    defer a.free(src_abs);
    const tar_abs = try std.fmt.allocPrint(a, "{s}/src/skel/{s}.tar", .{ wig_root, term });
    defer a.free(tar_abs);

    const src_max = maxFileMtime(a, src_abs) catch |err| switch (err) {
        error.FileNotFound => return error.EmptySourceTree,
        else => |e| return e,
    };

    const tar_st = blk: {
        const tf = fs.openFileAbsolute(tar_abs, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                try pack(a, wig_root, term);
                return;
            },
            else => |e| return e,
        };
        defer tf.close();
        break :blk try tf.stat();
    };

    if (src_max > tar_st.mtime) {
        fs.deleteFileAbsolute(tar_abs) catch {};
        try pack(a, wig_root, term);
    }
}
