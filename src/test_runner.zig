const std = @import("std");
const Allocator = std.mem.Allocator;
const comb = @import("comb");
const root = @import("root.zig");
const fs = std.fs;
const epoch = std.time.epoch;
const test_report = @import("test_report.zig");
const output_verifier = @import("output_verifier.zig");
const output_paths = @import("output_paths.zig");

const TestResults = test_report.TestResults;
const Report = test_report.Report;
const Reporter = test_report.Reporter;

/// Configurable paths for the test runner. Defaults preserve current behavior.
pub const TestRunnerConfig = struct {
    output_dir: []const u8 = output_paths.default_site_output_rel,
    workspace_dir: []const u8 = output_paths.default_test_workspace_rel,
};

/// Result of loading a spec. Call deinit when done.
pub const LoadedSpec = struct {
    content: []const u8,
    value: comb.Value,
    _parsed: comb.Parsed(comb.Value),

    pub fn deinit(self: *LoadedSpec) void {
        self._parsed.deinit();
    }
};

/// Loads a spec from a file. Default implementation reads YAML and parses with Comb.
/// Allows future formats (e.g. fixtures from zip) by swapping the loader.
pub const SpecLoader = struct {
    loadSpec: *const fn (a: Allocator, test_dir: fs.Dir, filename: []const u8) anyerror!LoadedSpec,
};

fn loadSpecFromFile(a: Allocator, test_dir: fs.Dir, filename: []const u8) !LoadedSpec {
    const content = try test_dir.readFileAlloc(a, filename, 1024 * 1024);
    const parsed = try comb.parse(a, content);
    return .{
        .content = content,
        .value = parsed.value,
        ._parsed = parsed,
    };
}

/// Default spec loader: reads YAML from test_dir and parses with Comb.
pub const defaultSpecLoader = SpecLoader{
    .loadSpec = loadSpecFromFile,
};

// ── Entry ────────────────────────────────────────────────────────────────

/// Parses WIG_TEST env format (e.g. "00" or "00,01,02") into a list of test numbers.
/// Caller owns the returned Filter; call filter.deinit(a) when done.
fn parseFilter(a: Allocator, filter_str: ?[]const u8) !?Filter {
    const f = filter_str orelse return null;
    if (f.len == 0) return null;
    var list = std.ArrayListUnmanaged([]const u8){};
    var iter = std.mem.splitScalar(u8, f, ',');
    while (iter.next()) |n| {
        const trimmed = std.mem.trim(u8, n, " \t");
        if (trimmed.len > 0) {
            try list.append(a, try a.dupe(u8, trimmed));
        }
    }
    if (list.items.len == 0) return null;
    return Filter{ .numbers = list };
}

/// Filter for WIG_TEST env: list of test numbers to run (e.g. "00", "01").
const Filter = struct {
    numbers: std.ArrayListUnmanaged([]const u8),

    fn deinit(self: *Filter, a: Allocator) void {
        for (self.numbers.items) |n| a.free(n);
        self.numbers.deinit(a);
    }

    fn matches(self: Filter, num: []const u8) bool {
        for (self.numbers.items) |n| {
            if (std.mem.eql(u8, n, num)) return true;
        }
        return false;
    }
};

/// Isolated workspace for a spec test run. Creates {workspace_dir}/{run_id}/ and manages cleanup.
const TestWorkspace = struct {
    allocator: Allocator,
    base_path: []const u8,
    base_dir: fs.Dir,
    run_id: []const u8,
    workspace_dir: []const u8,
    closed: bool = false,

    fn init(a: Allocator, run_id: []const u8, config: TestRunnerConfig) !TestWorkspace {
        const base_path = try fs.path.join(a, &.{ config.workspace_dir, run_id });
        fs.cwd().makePath(base_path) catch {};
        const base_dir = try fs.cwd().openDir(base_path, .{});
        return .{
            .allocator = a,
            .base_path = base_path,
            .base_dir = base_dir,
            .run_id = run_id,
            .workspace_dir = config.workspace_dir,
        };
    }

    fn deinit(self: *TestWorkspace) void {
        if (!self.closed) self.base_dir.close();
        self.allocator.free(self.base_path);
    }

    /// Creates a subdirectory for one test and returns its absolute path. Caller owns the path; call a.free() when done.
    /// Returns the path string, not fs.Dir; caller opens the dir with fs.cwd().openDir(path, .{}).
    fn createTestDir(self: *TestWorkspace, test_name: []const u8) ![]const u8 {
        self.base_dir.makePath(test_name) catch {};
        return fs.path.join(self.allocator, &.{ self.base_path, test_name });
    }

    fn deleteTestDir(self: *TestWorkspace, test_name: []const u8) void {
        self.base_dir.deleteTree(test_name) catch |err| {
            std.debug.print("  warning: could not delete test dir {s}: {}\n", .{ test_name, err });
        };
    }

    fn deleteAll(self: *TestWorkspace) void {
        self.base_dir.close();
        self.closed = true;
        var parent = fs.cwd().openDir(self.workspace_dir, .{}) catch |err| {
            std.debug.print("  warning: could not open workspace dir for cleanup: {}\n", .{err});
            return;
        };
        defer parent.close();
        parent.deleteTree(self.run_id) catch |err| {
            std.debug.print("  warning: could not delete run dir {s}: {}\n", .{ self.run_id, err });
        };
    }

    fn writeReport(self: *TestWorkspace, report: *Report) void {
        const report_path = fs.path.join(self.allocator, &.{ self.base_path, "report.txt" }) catch |err| {
            std.debug.print("  warning: could not build report path: {}\n", .{err});
            return;
        };
        defer self.allocator.free(report_path);
        var file = fs.cwd().createFile(report_path, .{}) catch |err| {
            std.debug.print("  warning: could not create report file: {}\n", .{err});
            return;
        };
        file.writeAll(report.buffer.items) catch |err| {
            std.debug.print("  warning: could not write report: {}\n", .{err});
        };
        file.close();
    }
};

/// Discovers spec test filenames (NN_*.yaml) in test_dir, sorted by number.
/// Caller owns returned items; call a.free() on each and list.deinit(a).
fn discoverSpecTests(a: Allocator, test_dir: fs.Dir) !std.ArrayListUnmanaged([]const u8) {
    var names = std.ArrayListUnmanaged([]const u8){};
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
    return names;
}

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
/// If config is null, uses default paths (zig-out/site, zig-out/test).
/// If loader is null, uses defaultSpecLoader.
/// If workspace_dir_out is non-null, sets it to the workspace dir used (for failure messages).
pub fn runSpecTests(
    a: Allocator,
    test_dir: fs.Dir,
    filter: ?[]const u8,
    run_id_out: ?*[16]u8,
    config: ?TestRunnerConfig,
    loader: ?*const SpecLoader,
    workspace_dir_out: ?*[]const u8,
) !TestResults {
    const cfg = config orelse TestRunnerConfig{};
    const ld = loader orelse &defaultSpecLoader;
    if (workspace_dir_out) |out| out.* = cfg.workspace_dir;
    var total = TestResults{};
    var names = try discoverSpecTests(a, test_dir);
    defer {
        for (names.items) |name| a.free(name);
        names.deinit(a);
    }

    var run_id_buf: [16]u8 = undefined;
    const run_id = try timestampRunId(&run_id_buf);
    if (run_id_out) |out| @memcpy(out[0..run_id.len], run_id);

    var report = Report.init(a);
    defer report.deinit();

    var filter_parsed = try parseFilter(a, filter);
    defer if (filter_parsed) |*f| f.deinit(a);

    var to_run = std.ArrayListUnmanaged([]const u8){};
    defer to_run.deinit(a);
    for (names.items) |filename| {
        const num = filename[0..2];
        if (filter_parsed) |*f| {
            if (!f.matches(num)) continue;
        }
        try to_run.append(a, filename);
    }
    report.writeHeader(run_id, to_run.items);

    var workspace = try TestWorkspace.init(a, run_id, cfg);
    defer workspace.deinit();

    for (to_run.items) |filename| {
        const dot_pos = std.mem.lastIndexOfScalar(u8, filename, '.') orelse filename.len;
        const test_name = filename[0..dot_pos];

        const results = runOneSpecTest(a, test_dir, filename, &workspace, &report, cfg.output_dir, ld) catch |err| {
            std.debug.print("  {s}: ERROR ({})\n", .{ filename, err });
            total.failed += 1;
            continue;
        };

        const status = if (results.failed > 0) "FAIL" else "ok";
        std.debug.print("  {s}: {s} {d}/{d}\n", .{ test_name, status, results.passed, results.total() });
        total.add(results);

        if (results.failed == 0) {
            workspace.deleteTestDir(test_name);
        }
    }

    if (total.failed > 0) {
        workspace.writeReport(&report);
    } else {
        workspace.deleteAll();
    }

    return total;
}

fn runOneSpecTest(a: Allocator, test_dir: fs.Dir, filename: []const u8, workspace: *TestWorkspace, report: *Report, output_dir_path: []const u8, loader: *const SpecLoader) !TestResults {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const ba = arena.allocator();

    var reporter = Reporter.init(null, report, filename);
    var loaded = loader.loadSpec(ba, test_dir, filename) catch {
        reporter.failWithFailure(ba, .{ .kind = .yaml_parse_error });
        return error.ParseFailed;
    };
    defer loaded.deinit();

    const spec = try parseSpecTest(ba, loaded.value);
    const dot_pos = std.mem.lastIndexOfScalar(u8, filename, '.') orelse filename.len;
    const test_name = filename[0..dot_pos];

    const work_path = try workspace.createTestDir(test_name);
    defer a.free(work_path);
    var work = try fs.cwd().openDir(work_path, .{});
    defer work.close();

    try setupWorkDir(ba, work, spec);

    const result = try runBuild(ba, work, spec.output_exit == 1, &reporter, output_dir_path);
    switch (result) {
        .expected_failure => return TestResults{ .passed = 1 },
        .failure => return error.BuildFailed,
        .output => |output_dir| {
            var mut_dir = output_dir;
            defer mut_dir.close();
            var results = TestResults{};
            var verify_reporter = Reporter.init(&results, report, filename);
            if (spec.output_files) |files| {
                try output_verifier.verify(ba, mut_dir, "", files, &verify_reporter);
            }
            return results;
        },
    }
}

// ── Parse ────────────────────────────────────────────────────────────────

/// Returns the key when entry.key is a string, else null.
fn getStringKey(entry: comb.Entry) ?[]const u8 {
    return switch (entry.key) {
        .string => |s| s,
        else => null,
    };
}

/// Returns the value for the matching string key in obj, or null.
fn getKey(obj: comb.Value, key: []const u8) ?comb.Value {
    if (obj != .object) return null;
    for (obj.object) |entry| {
        const k = getStringKey(entry) orelse continue;
        if (std.mem.eql(u8, k, key)) return entry.value;
    }
    return null;
}

/// Walks path (e.g. "input.files") and returns the value, or null.
fn getNested(top: comb.Value, path: []const u8) ?comb.Value {
    var current = top;
    var iter = std.mem.splitScalar(u8, path, '.');
    while (iter.next()) |segment| {
        if (current != .object) return null;
        current = getKey(current, segment) orelse return null;
    }
    return current;
}

/// Parsed spec test: input file tree, expected exit code, and optional output file expectations.
const SpecTest = struct {
    input_files: comb.Value,
    output_exit: u8,
    output_files: ?comb.Value,
};

fn parseSpecTest(_: Allocator, top: comb.Value) !SpecTest {
    if (top != .object) return error.InvalidFormat;

    const input_files = getNested(top, "input.files") orelse return error.MissingInputFiles;

    var output_exit: u8 = 0;
    var output_files: ?comb.Value = null;
    if (getKey(top, "output")) |output_obj| {
        if (getKey(output_obj, "exit")) |exit_val| {
            if (exit_val == .integer) output_exit = @intCast(@min(255, exit_val.integer));
        }
        output_files = getKey(output_obj, "files");
    }

    return .{
        .input_files = input_files,
        .output_exit = output_exit,
        .output_files = output_files,
    };
}

// ── Setup ────────────────────────────────────────────────────────────────

/// Writes input files from spec to the work directory.
fn setupWorkDir(a: Allocator, work: fs.Dir, spec: SpecTest) !void {
    for (spec.input_files.object) |entry| {
        const key = getStringKey(entry) orelse continue;
        try writeFileTree(a, work, key, entry.value);
    }
}

/// Result of runBuild: output dir on success, or expected_failure/failure.
const RunResult = union(enum) {
    output: fs.Dir,
    expected_failure,
    failure,
};

/// Runs Site.init + buildAll. Returns output dir on success.
fn runBuild(a: Allocator, work: fs.Dir, expect_fail: bool, reporter: *Reporter, output_dir_path: []const u8) !RunResult {
    const abs_root = try work.realpathAlloc(a, ".");

    var site = root.Site.init(a, .{ .root = abs_root }) catch |err| {
        if (expect_fail) return .expected_failure;
        reporter.failWithFailure(a, .{ .kind = .site_init_failed, .err = err });
        return .failure;
    };
    defer site.deinit();

    site.buildAll(.{ .clean = true }) catch |err| {
        if (expect_fail) return .expected_failure;
        reporter.failWithFailure(a, .{ .kind = .build_failed, .err = err });
        return .failure;
    };

    if (expect_fail) {
        reporter.failWithFailure(a, .{ .kind = .expected_fail_but_succeeded });
        return .failure;
    }

    const dir = work.openDir(output_dir_path, .{ .iterate = true }) catch {
        reporter.failWithFailure(a, .{ .kind = .output_dir_missing });
        return .failure;
    };
    return .{ .output = dir };
}

const KEY_MAP = [_][2][]const u8{
    .{ "templates", "templates" },
    .{ "layouts", "templates/layouts" },
    .{ "blocks", "templates/blocks" },
};

/// Maps spec keys to directory names: "layouts" -> "templates/layouts", "blocks" -> "templates/blocks".
fn resolveDirName(name: []const u8) []const u8 {
    for (KEY_MAP) |pair| {
        if (std.mem.eql(u8, pair[0], name)) return pair[1];
    }
    return name;
}

/// Writes file tree; resolveDirName maps spec keys to CUBE paths (layouts→templates/layouts, blocks→templates/blocks).
fn writeFileTree(a: Allocator, dir: fs.Dir, name: []const u8, value: comb.Value) !void {
    const dir_name = resolveDirName(name);

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
                const key = getStringKey(entry) orelse continue;
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

// ── Test ──────────────────────────────────────────────────────────────────

test "wig integration test suite" {
    var test_dir = fs.cwd().openDir("test", .{}) catch |err| {
        std.debug.print("\nCould not open test directory: {}\n", .{err});
        return err;
    };
    defer test_dir.close();

    const filter = std.posix.getenv("WIG_TEST");
    var run_id_buf: [16]u8 = undefined;
    var ws_dir: []const u8 = undefined;

    const total = runSpecTests(std.testing.allocator, test_dir, filter, &run_id_buf, null, null, &ws_dir) catch |err| {
        std.debug.print("\nSpec test runner failed: {}\n", .{err});
        return err;
    };

    std.debug.print("\n  Spec Total: {d}/{d} passed\n", .{ total.passed, total.total() });

    if (total.failed > 0) {
        std.debug.print("  Test files written to: {s}/{s}\n", .{ ws_dir, run_id_buf[0..15] });
        std.debug.print("  Total failures: {d}\n\n", .{total.failed});
        return error.SpecTestFailures;
    }
    std.debug.print("\n", .{});
}
