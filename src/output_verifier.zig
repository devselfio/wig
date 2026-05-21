//! Output verification for the wig spec test runner.
//! Compares build output against spec: file existence, content (with HTML normalization), and glob patterns.
//! Glob matching supports `*` only; not `**`, `?`, or character classes.

const std = @import("std");
const Allocator = std.mem.Allocator;
const comb = @import("comb");
const test_report = @import("test_report.zig");

const Reporter = test_report.Reporter;
const Failure = test_report.Failure;
const FailureKind = test_report.FailureKind;

/// Returns the key when entry.key is a string, else null.
fn getStringKey(entry: comb.Entry) ?[]const u8 {
    return switch (entry.key) {
        .string => |s| s,
        else => null,
    };
}

/// Verifies output directory against spec. Recursively checks files and glob patterns.
/// Glob patterns (keys containing `*`) support `*` only. Content is compared after HTML normalization.
pub fn verify(
    a: Allocator,
    io: std.Io,
    output_dir: std.Io.Dir,
    prefix: []const u8,
    spec: comb.Value,
    reporter: *Reporter,
) !void {
    const entries = switch (spec) {
        .object => |o| o,
        else => return,
    };

    for (entries) |entry| {
        const key = getStringKey(entry) orelse continue;

        const full_path = if (prefix.len > 0)
            try std.fmt.allocPrint(a, "{s}/{s}", .{ prefix, key })
        else
            try a.dupe(u8, key);

        if (std.mem.indexOf(u8, full_path, "*") != null) {
            try verifyGlobPath(a, io, output_dir, full_path, entry.value, reporter);
            continue;
        }

        switch (entry.value) {
            .string => |expected| {
                const actual = std.Io.Dir.readFileAlloc(output_dir, io, full_path, a, .limited(4 * 1024 * 1024)) catch {
                    reporter.failWithFailure(a, .{ .kind = .missing_file, .path = full_path });
                    continue;
                };

                if (!normalizedEql(a, actual, expected)) {
                    const exp_trimmed = std.mem.trim(u8, expected, " \t\r\n");
                    const act_trimmed = std.mem.trim(u8, actual, " \t\r\n");
                    reporter.failWithFailure(a, .{
                        .kind = .content_mismatch,
                        .path = full_path,
                        .expected = exp_trimmed,
                        .actual = act_trimmed,
                    });
                } else {
                    reporter.pass();
                }
            },
            .boolean => |b| {
                const exists = std.Io.Dir.access(output_dir, io, full_path, .{}) != error.FileNotFound;
                if (b and !exists) {
                    reporter.failWithFailure(a, .{ .kind = .file_should_exist, .path = full_path });
                } else if (!b and exists) {
                    reporter.failWithFailure(a, .{ .kind = .file_should_not_exist, .path = full_path });
                } else {
                    reporter.pass();
                }
            },
            .object => {
                try verify(a, io, output_dir, full_path, entry.value, reporter);
            },
            else => {},
        }
    }
}

fn verifyGlobPath(
    a: Allocator,
    io: std.Io,
    output_dir: std.Io.Dir,
    pattern: []const u8,
    value: comb.Value,
    reporter: *Reporter,
) !void {
    const dir_part = if (std.mem.lastIndexOfScalar(u8, pattern, '/')) |idx|
        pattern[0..idx]
    else
        ".";
    const file_pattern = if (std.mem.lastIndexOfScalar(u8, pattern, '/')) |idx|
        pattern[idx + 1 ..]
    else
        pattern;

    var sub_dir = std.Io.Dir.openDir(output_dir, io, dir_part, .{ .iterate = true }) catch {
        reporter.failWithFailure(a, .{ .kind = .glob_directory_not_found, .pattern = dir_part });
        return;
    };
    defer sub_dir.close(io);

    var it = sub_dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (globMatch(file_pattern, entry.name)) {
            switch (value) {
                .string => |expected| {
                    const actual = try std.Io.Dir.readFileAlloc(sub_dir, io, entry.name, a, .limited(4 * 1024 * 1024));
                    if (!normalizedEql(a, actual, expected)) {
                        const full = try std.fmt.allocPrint(a, "{s}/{s}", .{ dir_part, entry.name });
                        const exp_trimmed = std.mem.trim(u8, expected, " \t\r\n");
                        const act_trimmed = std.mem.trim(u8, actual, " \t\r\n");
                        reporter.failWithFailure(a, .{
                            .kind = .content_mismatch_glob,
                            .path = full,
                            .pattern = pattern,
                            .expected = exp_trimmed,
                            .actual = act_trimmed,
                        });
                    } else {
                        reporter.pass();
                    }
                },
                .boolean => |b| {
                    if (!b) {
                        reporter.failWithFailure(a, .{ .kind = .glob_expected_no_match, .pattern = pattern });
                    } else {
                        reporter.pass();
                    }
                },
                else => reporter.pass(),
            }
            return;
        }
    }

    switch (value) {
        .boolean => |b| {
            if (b) {
                reporter.failWithFailure(a, .{ .kind = .glob_no_match, .pattern = pattern });
            } else {
                reporter.pass();
            }
        },
        else => {
            reporter.failWithFailure(a, .{ .kind = .glob_no_match, .pattern = pattern });
        },
    }
}

/// Matches filename against pattern. Supports only `*`; not `**`, `?`, or character classes.
/// Future: add `**`, `?`, `[abc]` when needed.
fn globMatch(pattern: []const u8, name: []const u8) bool {
    var pi: usize = 0;
    var ni: usize = 0;
    var star_pi: ?usize = null;
    var star_ni: usize = 0;

    while (ni < name.len) {
        if (pi < pattern.len and pattern[pi] == '*') {
            star_pi = pi;
            star_ni = ni;
            pi += 1;
        } else if (pi < pattern.len and pattern[pi] == name[ni]) {
            pi += 1;
            ni += 1;
        } else if (star_pi) |sp| {
            pi = sp + 1;
            star_ni += 1;
            ni = star_ni;
        } else {
            return false;
        }
    }
    while (pi < pattern.len and pattern[pi] == '*') pi += 1;
    return pi == pattern.len;
}

const STACK_THRESHOLD = 4096;
const BUF_SIZE = 256 * 1024; // 256KB; outputs larger than this truncate in normalizeHtml

/// Compares actual and expected after HTML normalization. Uses stack for small inputs, allocates for large.
fn normalizedEql(a: Allocator, actual: []const u8, expected: []const u8) bool {
    if (actual.len <= STACK_THRESHOLD and expected.len <= STACK_THRESHOLD) {
        var a_buf: [STACK_THRESHOLD]u8 = undefined;
        var e_buf: [STACK_THRESHOLD]u8 = undefined;
        const a_norm = normalizeHtml(actual, &a_buf);
        const e_norm = normalizeHtml(expected, &e_buf);
        return std.mem.eql(u8, a_norm, e_norm);
    }
    const a_buf = a.alloc(u8, BUF_SIZE) catch return false;
    defer a.free(a_buf);
    const e_buf = a.alloc(u8, BUF_SIZE) catch return false;
    defer a.free(e_buf);
    const a_norm = normalizeHtml(actual, a_buf);
    const e_norm = normalizeHtml(expected, e_buf);
    return std.mem.eql(u8, a_norm, e_norm);
}

fn normalizeHtml(input: []const u8, buf: []u8) []const u8 {
    var len: usize = 0;
    var last_non_ws: u8 = 0;
    var in_ws = true;

    for (input) |c| {
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
            if (!in_ws) in_ws = true;
        } else {
            if (in_ws and len > 0) {
                if (last_non_ws != '>' and c != '<') {
                    if (len < buf.len) {
                        buf[len] = ' ';
                        len += 1;
                    }
                }
            }
            in_ws = false;
            if (len < buf.len) {
                buf[len] = c;
                len += 1;
            }
            last_non_ws = c;
        }
    }

    return buf[0..len];
}
