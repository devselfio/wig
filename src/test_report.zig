//! Test report types and formatting for the wig spec test runner.
//! Provides Report, Reporter, Failure, and related types used by test_runner and output_verifier.

const std = @import("std");
const Allocator = std.mem.Allocator;
const epoch = std.time.epoch;

/// Aggregated pass/fail counts for a test run.
pub const TestResults = struct {
    passed: usize = 0,
    failed: usize = 0,

    pub fn total(self: TestResults) usize {
        return self.passed + self.failed;
    }

    pub fn add(self: *TestResults, other: TestResults) void {
        self.passed += other.passed;
        self.failed += other.failed;
    }
};

/// Kind of verification or build failure for consistent formatting.
pub const FailureKind = enum {
    yaml_parse_error,
    site_init_failed,
    build_failed,
    expected_fail_but_succeeded,
    output_dir_missing,
    missing_file,
    content_mismatch,
    content_mismatch_glob,
    file_should_exist,
    file_should_not_exist,
    glob_directory_not_found,
    glob_no_match,
    glob_expected_no_match,
};

/// Structured failure with optional path, pattern, expected/actual, or error.
pub const Failure = struct {
    kind: FailureKind,
    path: ?[]const u8 = null,
    pattern: ?[]const u8 = null,
    expected: ?[]const u8 = null,
    actual: ?[]const u8 = null,
    err: ?anyerror = null,
};

/// Accumulates failure details for the report file. Best-effort; append failures are logged but not fatal.
pub const Report = struct {
    allocator: Allocator,
    buffer: std.ArrayListUnmanaged(u8) = .{},
    last_test_name: ?[]const u8 = null,
    header_written: bool = false,

    /// Creates a new report. Call deinit when done.
    pub fn init(a: Allocator) Report {
        return .{ .allocator = a };
    }
    /// Frees the report buffer.
    pub fn deinit(self: *Report) void {
        self.buffer.deinit(self.allocator);
    }

    /// Writes the report header with run ID, timestamp, and test list. Call once before any failures.
    pub fn writeHeader(self: *Report, run_id: []const u8, test_names: []const []const u8) void {
        if (self.header_written) return;
        self.header_written = true;
        self.append("=== Wig spec test run ===\n", .{});
        self.append("Run ID: {s}\n", .{run_id});
        var buf: [32]u8 = undefined;
        const ts = timestampIso8601(&buf) catch run_id;
        self.append("Timestamp: {s}\n", .{ts});
        if (test_names.len > 0) {
            self.append("Tests:", .{});
            for (test_names) |name| {
                const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse name.len;
                self.append(" {s}", .{name[0..dot]});
            }
            self.append("\n\n", .{});
        } else {
            self.append("Tests: (none)\n\n", .{});
        }
    }

    /// Appends formatted text to the report. Best-effort; logs to stderr on failure.
    pub fn append(self: *Report, comptime fmt: []const u8, args: anytype) void {
        const str = std.fmt.allocPrint(self.allocator, fmt, args) catch {
            std.debug.print("Report.append failed: format error\n", .{});
            return;
        };
        defer self.allocator.free(str);
        self.buffer.appendSlice(self.allocator, str) catch {
            std.debug.print("Report.append failed: buffer full\n", .{});
        };
    }

    /// Appends a failure with optional section header when test name changes.
    pub fn appendFailure(self: *Report, test_name: []const u8, comptime fmt: []const u8, args: anytype) void {
        if (self.last_test_name == null or !std.mem.eql(u8, self.last_test_name.?, test_name)) {
            self.last_test_name = test_name;
            self.append("--- {s} ---\n", .{test_name});
        }
        self.append(fmt, args);
    }
};

/// Centralized failure recording: prints compact line to stdout, appends full detail to report.
pub fn recordFailure(
    results: ?*TestResults,
    report: *Report,
    test_name: []const u8,
    short: []const u8,
    comptime report_fmt: []const u8,
    report_args: anytype,
) void {
    if (results) |r| r.failed += 1;
    std.debug.print("    FAIL [{s}]: {s}\n", .{ test_name, short });
    report.appendFailure(test_name, report_fmt, report_args);
}

/// Records a passing assertion. Increments results.passed.
pub fn recordPass(results: *TestResults) void {
    results.passed += 1;
}

/// Encapsulates result recording for a single test. Holds results, report, and test name.
pub const Reporter = struct {
    results: ?*TestResults,
    report: *Report,
    test_name: []const u8,

    pub fn init(results: ?*TestResults, report: *Report, test_name: []const u8) Reporter {
        return .{ .results = results, .report = report, .test_name = test_name };
    }

    pub fn failWithFailure(self: *Reporter, a: Allocator, f: Failure) void {
        const short = self.formatFailureShort(a, f);
        switch (f.kind) {
            .yaml_parse_error => recordFailure(self.results, self.report, self.test_name, short, "FAIL [{s}]: YAML parse error\n", .{self.test_name}),
            .site_init_failed => recordFailure(self.results, self.report, self.test_name, short, "FAIL [{s}]: Site.init failed: {}\n", .{ self.test_name, f.err.? }),
            .build_failed => recordFailure(self.results, self.report, self.test_name, short, "FAIL [{s}]: buildAll failed: {}\n", .{ self.test_name, f.err.? }),
            .expected_fail_but_succeeded => recordFailure(self.results, self.report, self.test_name, short, "FAIL [{s}]: expected build to fail but it succeeded\n", .{self.test_name}),
            .output_dir_missing => recordFailure(self.results, self.report, self.test_name, short, "FAIL [{s}]: could not open zig-out/site\n", .{self.test_name}),
            .missing_file => recordFailure(self.results, self.report, self.test_name, short, "FAIL [{s}]: output file missing: {s}\n", .{ self.test_name, f.path.? }),
            .content_mismatch => {
                const diff = formatUnifiedDiff(a, f.expected.?, f.actual.?) catch "  (could not generate diff)\n";
                defer a.free(diff);
                recordFailure(self.results, self.report, self.test_name, short, "FAIL [{s}]: content mismatch for {s}\n{s}\n", .{ self.test_name, f.path.?, diff });
            },
            .content_mismatch_glob => {
                const diff = formatUnifiedDiff(a, f.expected.?, f.actual.?) catch "  (could not generate diff)\n";
                defer a.free(diff);
                recordFailure(self.results, self.report, self.test_name, short, "FAIL [{s}]: content mismatch for {s} (matched {s})\n{s}\n", .{ self.test_name, f.path.?, f.pattern.?, diff });
            },
            .file_should_exist => recordFailure(self.results, self.report, self.test_name, short, "FAIL [{s}]: expected file to exist: {s}\n", .{ self.test_name, f.path.? }),
            .file_should_not_exist => recordFailure(self.results, self.report, self.test_name, short, "FAIL [{s}]: expected file to NOT exist: {s}\n", .{ self.test_name, f.path.? }),
            .glob_directory_not_found => recordFailure(self.results, self.report, self.test_name, short, "FAIL [{s}]: glob directory not found: {s}\n", .{ self.test_name, f.pattern.? }),
            .glob_no_match => recordFailure(self.results, self.report, self.test_name, short, "FAIL [{s}]: no file matching glob: {s}\n", .{ self.test_name, f.pattern.? }),
            .glob_expected_no_match => recordFailure(self.results, self.report, self.test_name, short, "FAIL [{s}]: expected no match for glob {s}\n", .{ self.test_name, f.pattern.? }),
        }
    }

    fn formatFailureShort(self: *Reporter, a: Allocator, f: Failure) []const u8 {
        _ = self;
        return switch (f.kind) {
            .yaml_parse_error => "YAML parse error",
            .site_init_failed => if (f.err) |e| std.fmt.allocPrint(a, "Site.init failed: {}", .{e}) catch "Site.init failed" else "Site.init failed",
            .build_failed => if (f.err) |e| std.fmt.allocPrint(a, "buildAll failed: {}", .{e}) catch "buildAll failed" else "buildAll failed",
            .expected_fail_but_succeeded => "expected build to fail but it succeeded",
            .output_dir_missing => "could not open zig-out/site",
            .missing_file => std.fmt.allocPrint(a, "output file missing: {s}", .{f.path.?}) catch "output file missing",
            .content_mismatch, .content_mismatch_glob => formatOneLineDiff(a, f.expected.?, f.actual.?),
            .file_should_exist => std.fmt.allocPrint(a, "expected file to exist: {s}", .{f.path.?}) catch "expected file to exist",
            .file_should_not_exist => std.fmt.allocPrint(a, "expected file to NOT exist: {s}", .{f.path.?}) catch "expected file to NOT exist",
            .glob_directory_not_found => std.fmt.allocPrint(a, "glob directory not found: {s}", .{f.pattern.?}) catch "glob directory not found",
            .glob_no_match => std.fmt.allocPrint(a, "no file matching glob: {s}", .{f.pattern.?}) catch "no file matching glob",
            .glob_expected_no_match => std.fmt.allocPrint(a, "expected no match for glob {s}", .{f.pattern.?}) catch "expected no match for glob",
        };
    }

    pub fn pass(self: *Reporter) void {
        if (self.results) |r| recordPass(r);
    }
};

fn formatUnifiedDiff(a: Allocator, expected: []const u8, actual: []const u8) ![]const u8 {
    var list = std.ArrayListUnmanaged(u8){};
    defer list.deinit(a);
    try list.appendSlice(a, "--- expected\n");
    try list.appendSlice(a, "+++ actual\n");
    var exp_iter = std.mem.splitScalar(u8, expected, '\n');
    var act_iter = std.mem.splitScalar(u8, actual, '\n');
    var exp_line = exp_iter.next();
    var act_line = act_iter.next();
    var exp_ln: usize = 1;
    var act_ln: usize = 1;
    var hunk = std.ArrayListUnmanaged(u8){};
    defer hunk.deinit(a);
    var hunk_exp_count: usize = 0;
    var hunk_act_count: usize = 0;
    var hunk_start_exp: usize = 1;
    var hunk_start_act: usize = 1;
    var in_hunk = false;
    while (exp_line != null or act_line != null) {
        const exp = exp_line orelse "";
        const act = act_line orelse "";
        const match = std.mem.eql(u8, exp, act);
        if (!match) {
            if (!in_hunk) {
                hunk_start_exp = exp_ln;
                hunk_start_act = act_ln;
                hunk_exp_count = 0;
                hunk_act_count = 0;
                hunk.clearRetainingCapacity();
                in_hunk = true;
            }
            if (exp_line != null) {
                try hunk.writer(a).print("-{s}\n", .{exp});
                hunk_exp_count += 1;
            }
            if (act_line != null) {
                try hunk.writer(a).print("+{s}\n", .{act});
                hunk_act_count += 1;
            }
        } else {
            if (in_hunk) {
                try list.writer(a).print("@@ -{d},{d} +{d},{d} @@\n", .{ hunk_start_exp, hunk_exp_count, hunk_start_act, hunk_act_count });
                try list.appendSlice(a, hunk.items);
                in_hunk = false;
            }
            try list.writer(a).print(" {s}\n", .{exp});
        }
        if (exp_line != null) {
            exp_ln += 1;
            exp_line = exp_iter.next();
        }
        if (act_line != null) {
            act_ln += 1;
            act_line = act_iter.next();
        }
    }
    if (in_hunk) {
        try list.writer(a).print("@@ -{d},{d} +{d},{d} @@\n", .{ hunk_start_exp, hunk_exp_count, hunk_start_act, hunk_act_count });
        try list.appendSlice(a, hunk.items);
    }
    return list.toOwnedSlice(a);
}

/// Returns a compact one-line diff for console output. Caller owns the returned slice (arena).
pub fn formatOneLineDiff(a: Allocator, expected: []const u8, actual: []const u8) []const u8 {
    const max_snip: usize = 35;
    var i: usize = 0;
    while (i < expected.len and i < actual.len and expected[i] == actual[i]) : (i += 1) {}
    const exp_start = if (i >= expected.len) expected.len else i;
    const act_start = if (i >= actual.len) actual.len else i;
    const exp_len = @min(expected.len - exp_start, max_snip);
    const act_len = @min(actual.len - act_start, max_snip);
    const exp_snip = if (exp_start < expected.len) expected[exp_start..][0..exp_len] else "";
    const act_snip = if (act_start < actual.len) actual[act_start..][0..act_len] else "";
    return std.fmt.allocPrint(a, "at byte {d}: expected \"{s}\" got \"{s}\"", .{
        i,
        exp_snip,
        act_snip,
    }) catch "content mismatch";
}

fn timestampIso8601(buf: []u8) ![]const u8 {
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
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        year_day.year,
        @intFromEnum(month_day.month),
        day,
        hour,
        min,
        sec,
    });
}
