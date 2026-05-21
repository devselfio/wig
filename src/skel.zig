//! Embedded skeleton archives (`src/skel/<term>.tar`) and pack/repack helpers.
//! Maintainer: run `zig build skel` after editing `skel/<term>/`, then commit the tarballs; `tar` on PATH.

const std = @import("std");

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
pub fn unpack(a: std.mem.Allocator, io: std.Io, term: []const u8, target_path: []const u8) !void {
    if (!isValidTerm(term)) return error.UnknownTerm;

    std.Io.Dir.createDirPath(std.Io.Dir.cwd(), io, target_path) catch {};
    const abs = try std.Io.Dir.realPathFileAlloc(std.Io.Dir.cwd(), io, target_path, a);
    defer a.free(abs);

    var dst = try std.Io.Dir.openDirAbsolute(io, abs, .{});
    defer dst.close(io);

    const bytes = try embeddedTarBytes(term);
    var reader: std.Io.Reader = .fixed(bytes);
    // Archive paths are `./pages/...`, `./data/...` (BSD/macOS `tar` prefix).
    try std.tar.extract(io, dst, &reader, .{ .strip_components = 0 });
}

/// Creates `src/skel/<term>.tar` from `skel/<term>/`. `wig_root` must be the wig repository root (absolute).
pub fn pack(a: std.mem.Allocator, io: std.Io, wig_root: []const u8, term: []const u8) !void {
    if (!isValidTerm(term)) return error.UnknownTerm;

    const out_rel = try std.fmt.allocPrint(a, "src/skel/{s}.tar", .{term});
    defer a.free(out_rel);
    const skel_rel = try std.fmt.allocPrint(a, "skel/{s}", .{term});
    defer a.free(skel_rel);

    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("COPYFILE_DISABLE", "1");

    var child = try std.process.spawn(io, .{
        .argv = &.{ "tar", "-cf", out_rel, "-C", skel_rel, "." },
        .cwd = .{ .path = wig_root },
        .environ_map = &env,
    });
    const term_res = try child.wait(io);
    switch (term_res) {
        .exited => |code| {
            if (code != 0) return error.TarFailed;
        },
        else => return error.TarFailed,
    }
}

fn maxFileMtime(a: std.mem.Allocator, io: std.Io, abs_dir: []const u8) !std.Io.Timestamp {
    var dir = try std.Io.Dir.openDirAbsolute(io, abs_dir, .{ .iterate = true });
    defer dir.close(io);

    var max: std.Io.Timestamp = .{ .nanoseconds = 0 };
    var walker = try dir.walk(a);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const st = try std.Io.Dir.statFile(entry.dir, io, entry.basename, .{});
        if (st.mtime.nanoseconds > max.nanoseconds) max = st.mtime;
    }
    return max;
}

/// If `src/skel/<term>.tar` is missing or older than any file under `skel/<term>/`, delete the tarball and `pack`.
pub fn repack(a: std.mem.Allocator, io: std.Io, wig_root: []const u8, term: []const u8) !void {
    if (!isValidTerm(term)) return error.UnknownTerm;

    const src_abs = try std.fs.path.join(a, &.{ wig_root, "skel", term });
    defer a.free(src_abs);
    const tar_abs = try std.fmt.allocPrint(a, "{s}/src/skel/{s}.tar", .{ wig_root, term });
    defer a.free(tar_abs);

    const src_max = maxFileMtime(a, io, src_abs) catch |err| switch (err) {
        error.FileNotFound => return error.EmptySourceTree,
        else => |e| return e,
    };

    const tar_st = blk: {
        const tf = std.Io.Dir.openFileAbsolute(io, tar_abs, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                try pack(a, io, wig_root, term);
                return;
            },
            else => |e| return e,
        };
        defer tf.close(io);
        break :blk try tf.stat(io);
    };

    if (src_max.nanoseconds > tar_st.mtime.nanoseconds) {
        std.Io.Dir.deleteFileAbsolute(io, tar_abs) catch {};
        try pack(a, io, wig_root, term);
    }
}
