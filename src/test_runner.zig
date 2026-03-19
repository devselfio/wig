const std = @import("std");
const Allocator = std.mem.Allocator;
const comb = @import("comb");
const root = @import("root.zig");
const fs = std.fs;
const epoch = std.time.epoch;

const TestResults = struct {
    passed: usize = 0,
    failed: usize = 0,

    fn total(self: TestResults) usize {
        return self.passed + self.failed;
    }

    fn add(self: *TestResults, other: TestResults) void {
        self.passed += other.passed;
        self.failed += other.failed;
    }
};

// ── Entry ────────────────────────────────────────────────────────────────

/// Returns YYYYMMDD-HHMMSS for the current time (UTC).
fn timestampRunId(buf: []u8) ![]const u8 {
    const secs = std.time.timestamp();
    const es = epoch.EpochSeconds{ .secs = @intCast(@max(0, secs)) };
    const epoch_day = es.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_secs = es.getDaySeconds();
    const day = month_day.day_index + 1;
    const hour = day_secs.getHoursIntoDay();
    const min = day_secs.getMinutesIntoHour();
    const sec = day_secs.getSecondsIntoMinute();
    return std.fmt.bufPrint(buf, "{d:0>4}{d:0>2}{d:0>2}-{d:0>2}{d:0>2}{d:0>2}", .{
        year_day.year,
        @intFromEnum(month_day.month),
        day,
        hour,
        min,
        sec,
    });
}

/// Scans test/ for NN_*.yaml, sorts by number, runs each (or filtered subset).
/// If run_id_out is provided, fills it with the timestamp run id (YYYYMMDD-HHMMSS).
pub fn runSpecTests(a: Allocator, test_dir: fs.Dir, filter: ?[]const u8, run_id_out: ?*[16]u8) !TestResults {
    var total = TestResults{};
    var names = std.ArrayListUnmanaged([]const u8){};
    defer {
        for (names.items) |name| a.free(name);
        names.deinit(a);
    }

    var it = test_dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".yaml")) continue;
        if (entry.name.len >= 2 and std.ascii.isDigit(entry.name[0]) and std.ascii.isDigit(entry.name[1])) {
            try names.append(a, try a.dupe(u8, entry.name));
        }
    }

    std.mem.sort([]const u8, names.items, {}, struct {
        fn cmp(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.order(u8, lhs, rhs) == .lt;
        }
    }.cmp);

    var run_id_buf: [16]u8 = undefined;
    const run_id = try timestampRunId(&run_id_buf);
    if (run_id_out) |out| @memcpy(out[0..run_id.len], run_id);
    const test_base = try fs.path.join(a, &.{ "zig-out", "test", run_id });
    defer a.free(test_base);
    fs.cwd().makePath(test_base) catch {};

    var report = Report.init(a);
    defer report.deinit();

    var base_dir = fs.cwd().openDir(test_base, .{}) catch return total;

    for (names.items) |filename| {
        const num = filename[0..2];
        if (filter) |f| {
            var iter = std.mem.splitScalar(u8, f, ',');
            var found = false;
            while (iter.next()) |n| {
                const trimmed = std.mem.trim(u8, n, " \t");
                if (std.mem.eql(u8, trimmed, num)) {
                    found = true;
                    break;
                }
            }
            if (!found) continue;
        }

        const dot_pos = std.mem.lastIndexOfScalar(u8, filename, '.') orelse filename.len;
        const test_name = filename[0..dot_pos];

        const results = runOneSpecTest(a, test_dir, filename, test_base, &report) catch |err| {
            std.debug.print("  {s}: ERROR ({})\n", .{ filename, err });
            total.failed += 1;
            continue;
        };

        const status = if (results.failed > 0) "FAIL" else "ok";
        std.debug.print("  {s}: {s} {d}/{d}\n", .{ test_name, status, results.passed, results.total() });
        total.add(results);

        if (results.failed == 0) {
            base_dir.deleteTree(test_name) catch {};
        }
    }

    base_dir.close();

    if (total.failed > 0) {
        const report_path = try fs.path.join(a, &.{ test_base, "report.txt" });
        defer a.free(report_path);
        var report_file = fs.cwd().createFile(report_path, .{}) catch return total;
        defer report_file.close();
        report_file.writeAll(report.buffer.items) catch {};
    } else {
        var test_parent = fs.cwd().openDir("zig-out/test", .{}) catch return total;
        defer test_parent.close();
        test_parent.deleteTree(run_id) catch {};
    }

    return total;
}

fn runOneSpecTest(a: Allocator, test_dir: fs.Dir, filename: []const u8, test_base: []const u8, report: *Report) !TestResults {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const ba = arena.allocator();

    const content = try test_dir.readFileAlloc(ba, filename, 1024 * 1024);
    var parsed = comb.parse(ba, content) catch {
        std.debug.print("    FAIL [{s}]: YAML parse error\n", .{filename});
        report.append("FAIL [{s}]: YAML parse error\n", .{filename});
        return error.ParseFailed;
    };
    defer parsed.deinit();

    const spec = try parseSpecTest(ba, parsed.value);
    const dot_pos = std.mem.lastIndexOfScalar(u8, filename, '.') orelse filename.len;
    const test_name = filename[0..dot_pos];

    const work_dir = try fs.path.join(ba, &.{ test_base, test_name });
    fs.cwd().makePath(work_dir) catch {};
    var work = try fs.cwd().openDir(work_dir, .{});
    defer work.close();

    for (spec.input_files.object) |entry| {
        const key = switch (entry.key) {
            .string => |s| s,
            else => continue,
        };
        try writeFileTree(ba, work, key, entry.value);
    }

    const abs_root = try work.realpathAlloc(ba, ".");
    const expect_fail = spec.output_exit == 1;

    var site = root.Site.init(ba, .{ .root = abs_root }) catch |err| {
        if (expect_fail) {
            return TestResults{ .passed = 1 };
        }
        std.debug.print("    FAIL [{s}]: Site.init failed: {}\n", .{ filename, err });
        report.append("FAIL [{s}]: Site.init failed: {}\n", .{ filename, err });
        return error.BuildFailed;
    };
    defer site.deinit();

    site.buildAll(.{ .clean = true }) catch |err| {
        if (expect_fail) {
            return TestResults{ .passed = 1 };
        }
        std.debug.print("    FAIL [{s}]: buildAll failed: {}\n", .{ filename, err });
        report.append("FAIL [{s}]: buildAll failed: {}\n", .{ filename, err });
        return error.BuildFailed;
    };

    if (expect_fail) {
        std.debug.print("    FAIL [{s}]: expected build to fail but it succeeded\n", .{filename});
        report.append("FAIL [{s}]: expected build to fail but it succeeded\n", .{filename});
        return error.UnexpectedSuccess;
    }

    var output_dir = work.openDir("zig-out/site", .{ .iterate = true }) catch {
        std.debug.print("    FAIL [{s}]: could not open zig-out/site\n", .{filename});
        report.append("FAIL [{s}]: could not open zig-out/site\n", .{filename});
        return error.OutputMissing;
    };
    defer output_dir.close();

    var results = TestResults{};
    if (spec.output_files) |files| {
        try verifyOutput(ba, output_dir, "", files, &results, filename, report);
    }
    return results;
}

// ── Parse ────────────────────────────────────────────────────────────────

const SpecTest = struct {
    input_files: comb.Value,
    output_exit: u8,
    output_files: ?comb.Value,
};

fn parseSpecTest(_: Allocator, top: comb.Value) !SpecTest {
    if (top != .object) return error.InvalidFormat;

    var input_files: ?comb.Value = null;
    var output_exit: u8 = 0;
    var output_files: ?comb.Value = null;

    for (top.object) |entry| {
        const key = switch (entry.key) {
            .string => |s| s,
            else => continue,
        };
        if (std.mem.eql(u8, key, "input")) {
            if (entry.value == .object) {
                for (entry.value.object) |e| {
                    const k = switch (e.key) {
                        .string => |x| x,
                        else => continue,
                    };
                    if (std.mem.eql(u8, k, "files")) {
                        input_files = e.value;
                        break;
                    }
                }
            }
        } else if (std.mem.eql(u8, key, "output")) {
            if (entry.value == .object) {
                for (entry.value.object) |e| {
                    const k = switch (e.key) {
                        .string => |x| x,
                        else => continue,
                    };
                    if (std.mem.eql(u8, k, "exit")) {
                        if (e.value == .integer) output_exit = @intCast(@min(255, e.value.integer));
                    } else if (std.mem.eql(u8, k, "files")) {
                        output_files = e.value;
                    }
                }
            }
        }
    }

    const files = input_files orelse return error.MissingInputFiles;
    return .{
        .input_files = files,
        .output_exit = output_exit,
        .output_files = output_files,
    };
}

// ── Setup ────────────────────────────────────────────────────────────────

/// Maps "templates" -> "layouts" and "blocks" -> "includes" so loader finds them.
fn writeFileTree(a: Allocator, dir: fs.Dir, name: []const u8, value: comb.Value) !void {
    const dir_name = if (std.mem.eql(u8, name, "templates"))
        "layouts"
    else if (std.mem.eql(u8, name, "blocks"))
        "includes"
    else
        name;

    switch (value) {
        .string => |content| {
            if (std.fs.path.dirname(dir_name)) |parent| {
                dir.makePath(parent) catch {};
            }
            var f = try dir.createFile(dir_name, .{});
            defer f.close();
            try f.writeAll(content);
        },
        .object => |entries| {
            dir.makePath(dir_name) catch {};
            var sub_dir = try dir.openDir(dir_name, .{});
            defer sub_dir.close();
            for (entries) |entry| {
                const key = switch (entry.key) {
                    .string => |s| s,
                    else => continue,
                };
                try writeFileTree(a, sub_dir, key, entry.value);
            }
        },
        .boolean => |b| {
            if (b) {
                if (std.fs.path.dirname(dir_name)) |parent| {
                    dir.makePath(parent) catch {};
                }
                var f = try dir.createFile(dir_name, .{});
                f.close();
            }
        },
        else => {},
    }
}

// ── Report ───────────────────────────────────────────────────────────────

const Report = struct {
    allocator: Allocator,
    buffer: std.ArrayListUnmanaged(u8) = .{},

    fn init(a: Allocator) Report {
        return .{ .allocator = a };
    }
    fn deinit(self: *Report) void {
        self.buffer.deinit(self.allocator);
    }
    fn append(self: *Report, comptime fmt: []const u8, args: anytype) void {
        const str = std.fmt.allocPrint(self.allocator, fmt, args) catch return;
        defer self.allocator.free(str);
        self.buffer.appendSlice(self.allocator, str) catch {};
    }
};

// ── Verify ───────────────────────────────────────────────────────────────

fn verifyOutput(
    a: Allocator,
    output_dir: fs.Dir,
    prefix: []const u8,
    spec: comb.Value,
    results: *TestResults,
    test_name: []const u8,
    report: *Report,
) !void {
    const entries = switch (spec) {
        .object => |o| o,
        else => return,
    };

    for (entries) |entry| {
        const key = switch (entry.key) {
            .string => |s| s,
            else => continue,
        };

        const full_path = if (prefix.len > 0)
            try std.fmt.allocPrint(a, "{s}/{s}", .{ prefix, key })
        else
            try a.dupe(u8, key);

        if (std.mem.indexOf(u8, full_path, "*") != null) {
            try verifyGlobPath(a, output_dir, full_path, entry.value, results, test_name, report);
            continue;
        }

        switch (entry.value) {
            .string => |expected| {
                const actual = output_dir.readFileAlloc(a, full_path, 4 * 1024 * 1024) catch {
                    std.debug.print("    FAIL [{s}]: output file missing: {s}\n", .{ test_name, full_path });
                    report.append("FAIL [{s}]: output file missing: {s}\n", .{ test_name, full_path });
                    results.failed += 1;
                    continue;
                };

                if (!normalizedEql(actual, expected)) {
                    std.debug.print("    FAIL [{s}]: {s} content mismatch\n", .{ test_name, full_path });
                    report.append("FAIL [{s}]: content mismatch for {s}\n  expected: '{s}'\n  actual:   '{s}'\n", .{
                        test_name,
                        full_path,
                        std.mem.trim(u8, expected, " \t\r\n"),
                        std.mem.trim(u8, actual, " \t\r\n"),
                    });
                    results.failed += 1;
                } else {
                    results.passed += 1;
                }
            },
            .boolean => |b| {
                const exists = output_dir.access(full_path, .{}) != error.FileNotFound;
                if (b and !exists) {
                    std.debug.print("    FAIL [{s}]: expected file to exist: {s}\n", .{ test_name, full_path });
                    report.append("FAIL [{s}]: expected file to exist: {s}\n", .{ test_name, full_path });
                    results.failed += 1;
                } else if (!b and exists) {
                    std.debug.print("    FAIL [{s}]: expected file to NOT exist: {s}\n", .{ test_name, full_path });
                    report.append("FAIL [{s}]: expected file to NOT exist: {s}\n", .{ test_name, full_path });
                    results.failed += 1;
                } else {
                    results.passed += 1;
                }
            },
            .object => {
                try verifyOutput(a, output_dir, full_path, entry.value, results, test_name, report);
            },
            else => {},
        }
    }
}

fn verifyGlobPath(
    a: Allocator,
    output_dir: fs.Dir,
    pattern: []const u8,
    value: comb.Value,
    results: *TestResults,
    test_name: []const u8,
    report: *Report,
) !void {
    const dir_part = if (std.mem.lastIndexOfScalar(u8, pattern, '/')) |idx|
        pattern[0..idx]
    else
        ".";
    const file_pattern = if (std.mem.lastIndexOfScalar(u8, pattern, '/')) |idx|
        pattern[idx + 1 ..]
    else
        pattern;

    var sub_dir = output_dir.openDir(dir_part, .{ .iterate = true }) catch {
        std.debug.print("    FAIL [{s}]: glob directory not found: {s}\n", .{ test_name, dir_part });
        report.append("FAIL [{s}]: glob directory not found: {s}\n", .{ test_name, dir_part });
        results.failed += 1;
        return;
    };
    defer sub_dir.close();

    var it = sub_dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (globMatch(file_pattern, entry.name)) {
            switch (value) {
                .string => |expected| {
                    const actual = try sub_dir.readFileAlloc(a, entry.name, 4 * 1024 * 1024);
                    if (!normalizedEql(actual, expected)) {
                        const full = try std.fmt.allocPrint(a, "{s}/{s}", .{ dir_part, entry.name });
                        std.debug.print("    FAIL [{s}]: {s} content mismatch\n", .{ test_name, full });
                        report.append("FAIL [{s}]: content mismatch for {s} (matched {s})\n  expected: '{s}'\n  actual:   '{s}'\n", .{
                            test_name,
                            full,
                            pattern,
                            std.mem.trim(u8, expected, " \t\r\n"),
                            std.mem.trim(u8, actual, " \t\r\n"),
                        });
                        results.failed += 1;
                    } else {
                        results.passed += 1;
                    }
                },
                .boolean => |b| {
                    if (!b) {
                        std.debug.print("    FAIL [{s}]: expected no match for glob {s}\n", .{ test_name, pattern });
                        report.append("FAIL [{s}]: expected no match for glob {s}\n", .{ test_name, pattern });
                        results.failed += 1;
                    } else {
                        results.passed += 1;
                    }
                },
                else => results.passed += 1,
            }
            return;
        }
    }

    switch (value) {
        .boolean => |b| {
            if (b) {
                std.debug.print("    FAIL [{s}]: no file matching glob: {s}\n", .{ test_name, pattern });
                report.append("FAIL [{s}]: no file matching glob: {s}\n", .{ test_name, pattern });
                results.failed += 1;
            } else {
                results.passed += 1;
            }
        },
        else => {
            std.debug.print("    FAIL [{s}]: no file matching glob: {s}\n", .{ test_name, pattern });
            report.append("FAIL [{s}]: no file matching glob: {s}\n", .{ test_name, pattern });
            results.failed += 1;
        },
    }
}

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

fn normalizedEql(actual: []const u8, expected: []const u8) bool {
    var a_buf: [64 * 1024]u8 = undefined;
    var e_buf: [64 * 1024]u8 = undefined;
    const a_norm = normalizeHtml(actual, &a_buf);
    const e_norm = normalizeHtml(expected, &e_buf);
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

// ── Test ──────────────────────────────────────────────────────────────────

test "wig integration test suite" {
    var test_dir = fs.cwd().openDir("test", .{}) catch |err| {
        std.debug.print("\nCould not open test directory: {}\n", .{err});
        return err;
    };
    defer test_dir.close();

    const filter = std.posix.getenv("WIG_TEST");
    var run_id_buf: [16]u8 = undefined;

    const total = runSpecTests(std.testing.allocator, test_dir, filter, &run_id_buf) catch |err| {
        std.debug.print("\nSpec test runner failed: {}\n", .{err});
        return err;
    };

    std.debug.print("\n  Spec Total: {d}/{d} passed\n", .{ total.passed, total.total() });

    if (total.failed > 0) {
        std.debug.print("  Test files written to: zig-out/test/{s}\n", .{run_id_buf[0..15]});
        std.debug.print("  Total failures: {d}\n\n", .{total.failed});
        return error.SpecTestFailures;
    }
    std.debug.print("\n", .{});
}
