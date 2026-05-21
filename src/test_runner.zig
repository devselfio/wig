const std = @import("std");
const Allocator = std.mem.Allocator;
const comb = @import("comb");
const root = @import("root.zig");
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
    loadSpec: *const fn (a: Allocator, io: std.Io, test_dir: std.Io.Dir, filename: []const u8) anyerror!LoadedSpec,
};

fn loadSpecFromFile(a: Allocator, io: std.Io, test_dir: std.Io.Dir, filename: []const u8) !LoadedSpec {
    const content = try std.Io.Dir.readFileAlloc(test_dir, io, filename, a, .limited(1024 * 1024));
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

/// Parses WIG_TEST env format (e.g. "0", "34", "034", or "00,01,02") into a list of
/// decimal id strings. Matching against a spec file is **numeric** (`34` matches `034_*.yaml`).
/// Caller owns the returned Filter; call filter.deinit(a) when done.
fn parseFilter(a: Allocator, filter_str: ?[]const u8) !?Filter {
    const f = filter_str orelse return null;
    if (f.len == 0) return null;
    var list = std.ArrayListUnmanaged([]const u8).empty;
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

/// Filter for WIG_TEST env: list of decimal id strings; see `matchesSpecFilename`.
const Filter = struct {
    numbers: std.ArrayListUnmanaged([]const u8),

    fn deinit(self: *Filter, a: Allocator) void {
        for (self.numbers.items) |n| a.free(n);
        self.numbers.deinit(a);
    }

    fn matchesSpecFilename(self: Filter, filename: []const u8) bool {
        const pref = specNumericPrefix(filename) orelse return false;
        const file_id = parseSpecNumericId(pref) orelse return false;
        for (self.numbers.items) |n| {
            const want = parseSpecNumericId(n) orelse continue;
            if (want == file_id) return true;
        }
        return false;
    }
};

/// Leading decimal digits of a spec filename, if there are at least two digits and the
/// next character is `'_'` (e.g. `000` for `000_one_page.yaml`).
fn specNumericPrefix(filename: []const u8) ?[]const u8 {
    var end: usize = 0;
    while (end < filename.len and std.ascii.isDigit(filename[end])) : (end += 1) {}
    if (end < 2) return null;
    if (end >= filename.len or filename[end] != '_') return null;
    return filename[0..end];
}

fn parseSpecNumericId(digits: []const u8) ?usize {
    if (digits.len == 0) return null;
    return std.fmt.parseInt(usize, digits, 10) catch null;
}

fn specFilenameLessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
    const pl = specNumericPrefix(lhs) orelse return false;
    const pr = specNumericPrefix(rhs) orelse return true;
    const nl = parseSpecNumericId(pl) orelse return false;
    const nr = parseSpecNumericId(pr) orelse return true;
    if (nl != nr) return nl < nr;
    return std.mem.order(u8, lhs, rhs) == .lt;
}

/// Isolated workspace for a spec test run. Creates {workspace_dir}/{run_id}/ and manages cleanup.
const TestWorkspace = struct {
    allocator: Allocator,
    base_path: []const u8,
    io: std.Io,
    base_dir: std.Io.Dir,
    run_id: []const u8,
    workspace_dir: []const u8,
    closed: bool = false,

    fn init(a: Allocator, io: std.Io, run_id: []const u8, config: TestRunnerConfig) !TestWorkspace {
        const base_path = try std.fs.path.join(a, &.{ config.workspace_dir, run_id });
        std.Io.Dir.createDirPath(std.Io.Dir.cwd(), io, base_path) catch {};
        const base_dir = try std.Io.Dir.openDir(std.Io.Dir.cwd(), io, base_path, .{});
        return .{
            .allocator = a,
            .io = io,
            .base_path = base_path,
            .base_dir = base_dir,
            .run_id = run_id,
            .workspace_dir = config.workspace_dir,
        };
    }

    fn deinit(self: *TestWorkspace) void {
        if (!self.closed) self.base_dir.close(self.io);
        self.allocator.free(self.base_path);
    }

    /// Creates a subdirectory for one test and returns its absolute path. Caller owns the path; call a.free() when done.
    /// Returns the path string, not fs.Dir; caller opens the dir with fs.cwd().openDir(path, .{}).
    fn createTestDir(self: *TestWorkspace, test_name: []const u8) ![]const u8 {
        std.Io.Dir.createDirPath(self.base_dir, self.io, test_name) catch {};
        return std.fs.path.join(self.allocator, &.{ self.base_path, test_name });
    }

    fn deleteTestDir(self: *TestWorkspace, test_name: []const u8) void {
        std.Io.Dir.deleteTree(self.base_dir, self.io, test_name) catch |err| {
            std.debug.print("  warning: could not delete test dir {s}: {}\n", .{ test_name, err });
        };
    }

    fn deleteAll(self: *TestWorkspace) void {
        self.base_dir.close(self.io);
        self.closed = true;
        var parent = std.Io.Dir.openDir(std.Io.Dir.cwd(), self.io, self.workspace_dir, .{}) catch |err| {
            std.debug.print("  warning: could not open workspace dir for cleanup: {}\n", .{err});
            return;
        };
        defer parent.close(self.io);
        std.Io.Dir.deleteTree(parent, self.io, self.run_id) catch |err| {
            std.debug.print("  warning: could not delete run dir {s}: {}\n", .{ self.run_id, err });
        };
    }

    fn writeReport(self: *TestWorkspace, report: *Report) void {
        const report_path = std.fs.path.join(self.allocator, &.{ self.base_path, "report.txt" }) catch |err| {
            std.debug.print("  warning: could not build report path: {}\n", .{err});
            return;
        };
        defer self.allocator.free(report_path);
        var file = std.Io.Dir.createFileAbsolute(self.io, report_path, .{}) catch |err| {
            std.debug.print("  warning: could not create report file: {}\n", .{err});
            return;
        };
        file.writeStreamingAll(self.io, report.buffer.items) catch |err| {
            std.debug.print("  warning: could not write report: {}\n", .{err});
        };
        file.close(self.io);
    }
};

/// Discovers spec test filenames (`{digits}_{name}.yaml`, ≥2 leading digits) in test_dir,
/// sorted by **numeric** id then filename (so `100_` orders after `99_`).
/// Caller owns returned items; call a.free() on each and list.deinit(a).
fn discoverSpecTests(a: Allocator, io: std.Io, test_dir: std.Io.Dir) !std.ArrayListUnmanaged([]const u8) {
    var names = std.ArrayListUnmanaged([]const u8).empty;
    var it = test_dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".yaml")) continue;
        if (specNumericPrefix(entry.name) == null) continue;
        try names.append(a, try a.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, names.items, {}, specFilenameLessThan);
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

/// Scans test/ for `{digits}_*.yaml` (≥2 digit id), sorts by numeric id, runs each (or filtered subset).
/// If run_id_out is provided, fills it with the timestamp run id (YYYYMMDD-HHMMSS).
/// If config is null, uses default paths (zig-out/site, zig-out/test).
/// If loader is null, uses defaultSpecLoader.
/// If workspace_dir_out is non-null, sets it to the workspace dir used (for failure messages).
pub fn runSpecTests(
    a: Allocator,
    io: std.Io,
    test_dir: std.Io.Dir,
    filter: ?[]const u8,
    run_id_out: ?*[16]u8,
    config: ?TestRunnerConfig,
    loader: ?*const SpecLoader,
    workspace_dir_out: ?*[]const u8,
) !TestResults {
    const cfg = config orelse TestRunnerConfig{};
    _ = loader;
    if (workspace_dir_out) |out| out.* = cfg.workspace_dir;
    var total = TestResults{};
    var names = try discoverSpecTests(a, io, test_dir);
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

    var to_run = std.ArrayListUnmanaged([]const u8).empty;
    defer to_run.deinit(a);
    for (names.items) |filename| {
        if (filter_parsed) |*f| {
            if (!f.matchesSpecFilename(filename)) continue;
        }
        try to_run.append(a, filename);
    }
    report.writeHeader(run_id, to_run.items);

    var workspace = try TestWorkspace.init(a, io, run_id, cfg);
    defer workspace.deinit();

    for (to_run.items) |filename| {
        const dot_pos = std.mem.lastIndexOfScalar(u8, filename, '.') orelse filename.len;
        const test_name = filename[0..dot_pos];

        const results = runOneSpecTest(a, io, test_dir, filename, &workspace, &report, cfg.output_dir) catch |err| {
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

fn runOneSpecTest(a: Allocator, io: std.Io, test_dir: std.Io.Dir, filename: []const u8, workspace: *TestWorkspace, report: *Report, output_dir_path: []const u8) !TestResults {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const ba = arena.allocator();

    var reporter = Reporter.init(null, report, filename);
    const content = std.Io.Dir.readFileAlloc(test_dir, io, filename, ba, .limited(1024 * 1024)) catch {
        reporter.failWithFailure(ba, .{ .kind = .yaml_parse_error });
        return error.ParseFailed;
    };

    var parsed = comb.parseAll(ba, content, .{}) catch {
        reporter.failWithFailure(ba, .{ .kind = .yaml_parse_error });
        return error.ParseFailed;
    };
    defer parsed.deinit();

    const documents = parsed.value;
    if (documents.len == 0) {
        reporter.failWithFailure(ba, .{ .kind = .yaml_parse_error });
        return error.ParseFailed;
    }

    var total = TestResults{};
    for (documents, 0..) |doc, doc_idx| {
        const sub = try runOneSubSpec(ba, a, io, doc, doc_idx, filename, workspace, report, output_dir_path);
        total.add(sub);
    }
    return total;
}

fn runOneSubSpec(ba: Allocator, parent_a: Allocator, io: std.Io, doc: comb.Value, doc_idx: usize, filename: []const u8, workspace: *TestWorkspace, report: *Report, output_dir_path: []const u8) !TestResults {
    var reporter = Reporter.init(null, report, filename);

    const spec = parseSpecTest(ba, doc) catch {
        reporter.failWithFailure(ba, .{ .kind = .yaml_parse_error });
        return error.ParseFailed;
    };

    const dot_pos = std.mem.lastIndexOfScalar(u8, filename, '.') orelse filename.len;
    const base_name = filename[0..dot_pos];
    const test_name = if (doc_idx == 0)
        base_name
    else
        try std.fmt.allocPrint(ba, "{s}_doc{d}", .{ base_name, doc_idx });

    const work_path = try workspace.createTestDir(test_name);
    defer parent_a.free(work_path);
    var work = try std.Io.Dir.openDir(std.Io.Dir.cwd(), io, work_path, .{});
    defer work.close(io);

    try setupWorkDir(ba, io, work, spec);

    if (spec.action.command == .check) {
        const check_result = try runCheck(ba, io, work, spec.output_exit == 1, &reporter);
        switch (check_result) {
            .failure => return error.BuildFailed,
            .expected_failure, .ok => |diags| {
                var results = TestResults{};
                var verify_reporter = Reporter.init(&results, report, filename);
                if (spec.output_diagnostics) |expected_diags| {
                    try verifyCheckDiagnostics(ba, diags, expected_diags, &verify_reporter);
                }
                if (results.failed == 0) results.passed += 1;
                return results;
            },
        }
    }

    const expect_fail = spec.output_exit == 1;
    const result = try runBuild(ba, io, work, expect_fail, &reporter, output_dir_path, spec.action);
    switch (result) {
        .expected_failure => return TestResults{ .passed = 1 },
        .failure => return error.BuildFailed,
        .output => |out| {
            var mut_dir = out.dir;
            defer mut_dir.close(io);
            const has_diag_errors = out.diagnostics.hasErrors();

            if (has_diag_errors and expect_fail) {
                var results = TestResults{};
                var verify_reporter = Reporter.init(&results, report, filename);
                if (spec.output_diagnostics) |expected_diags| {
                    try verifyDiagnostics(ba, out.diagnostics, expected_diags, &verify_reporter);
                }
                if (results.failed == 0) results.passed += 1;
                return results;
            }

            if (has_diag_errors and !expect_fail) {
                reporter.failWithFailure(ba, .{ .kind = .build_failed, .err = error.BuildFailed });
                return error.BuildFailed;
            }

            if (!has_diag_errors and expect_fail) {
                reporter.failWithFailure(ba, .{ .kind = .expected_fail_but_succeeded });
                return error.BuildFailed;
            }

            var results = TestResults{};
            var verify_reporter = Reporter.init(&results, report, filename);
            if (spec.output_files) |files| {
                try output_verifier.verify(ba, io, mut_dir, "", files, &verify_reporter);
            }
            if (spec.output_diagnostics) |expected_diags| {
                try verifyDiagnostics(ba, out.diagnostics, expected_diags, &verify_reporter);
            }
            if (results.passed == 0 and results.failed == 0) {
                results.passed = 1;
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

/// Parsed action flags from `test.action.wig` (e.g. `"build --draft --pretty"` or `"check"`).
const ActionFlags = struct {
    command: Command = .build,
    draft: bool = false,
    pretty: bool = false,
    strict_links: bool = false,

    const Command = enum { build, check };
};

/// Parsed spec test: input file tree, expected exit code, optional output file
/// expectations, optional diagnostic assertions, and action flags.
const SpecTest = struct {
    input_files: comb.Value,
    output_exit: u8,
    output_files: ?comb.Value,
    output_diagnostics: ?comb.Value = null,
    action: ActionFlags = .{},
};

fn parseActionFlags(top: comb.Value) ActionFlags {
    const action_val = getNested(top, "test.action.wig") orelse return .{};
    if (action_val != .string) return .{};
    var flags = ActionFlags{};
    var iter = std.mem.splitScalar(u8, action_val.string, ' ');
    while (iter.next()) |token| {
        if (std.mem.eql(u8, token, "check")) flags.command = .check;
        if (std.mem.eql(u8, token, "--draft")) flags.draft = true;
        if (std.mem.eql(u8, token, "--pretty")) flags.pretty = true;
        if (std.mem.eql(u8, token, "--strict-links")) flags.strict_links = true;
    }
    return flags;
}

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

    var output_diagnostics: ?comb.Value = null;
    if (getKey(top, "output")) |output_obj| {
        output_diagnostics = getKey(output_obj, "diagnostics");
    }

    return .{
        .input_files = input_files,
        .output_exit = output_exit,
        .output_files = output_files,
        .output_diagnostics = output_diagnostics,
        .action = parseActionFlags(top),
    };
}

// ── Setup ────────────────────────────────────────────────────────────────

/// Writes input files from spec to the work directory.
fn setupWorkDir(a: Allocator, io: std.Io, work: std.Io.Dir, spec: SpecTest) !void {
    for (spec.input_files.object) |entry| {
        const key = getStringKey(entry) orelse continue;
        try writeFileTree(a, io, work, key, entry.value);
    }
}

const diagnostics_mod = @import("diagnostics.zig");

/// Result of runBuild: output dir + diagnostics on success, or expected_failure/failure.
const RunResult = union(enum) {
    output: struct { dir: std.Io.Dir, diagnostics: diagnostics_mod.Collector },
    expected_failure,
    failure,
};

/// Runs Site.init + buildAll. Returns output dir on success.
fn runBuild(a: Allocator, io: std.Io, work: std.Io.Dir, expect_fail: bool, reporter: *Reporter, output_dir_path: []const u8, action: ActionFlags) !RunResult {
    const abs_root = try std.Io.Dir.realPathFileAlloc(work, io, ".", a);

    var site = root.Site.init(a, io, .{ .root = abs_root, .draft = action.draft }) catch |err| {
        if (expect_fail) return .expected_failure;
        reporter.failWithFailure(a, .{ .kind = .site_init_failed, .err = err });
        return .failure;
    };
    defer site.deinit();

    const build_result = site.buildAll(.{ .clean = true, .pretty = action.pretty, .strict_links = action.strict_links }) catch |err| {
        if (expect_fail) return .expected_failure;
        reporter.failWithFailure(a, .{ .kind = .build_failed, .err = err });
        return .failure;
    };

    const dir = std.Io.Dir.openDir(work, io, output_dir_path, .{ .iterate = true }) catch {
        if (expect_fail) return .expected_failure;
        reporter.failWithFailure(a, .{ .kind = .output_dir_missing });
        return .failure;
    };
    return .{ .output = .{ .dir = dir, .diagnostics = build_result.diagnostics } };
}

const CheckResult = union(enum) {
    ok: []const root.Diagnostic,
    expected_failure: []const root.Diagnostic,
    failure,
};

fn runCheck(a: Allocator, io: std.Io, work: std.Io.Dir, expect_fail: bool, reporter: *Reporter) !CheckResult {
    const abs_root = try std.Io.Dir.realPathFileAlloc(work, io, ".", a);

    var site = root.Site.init(a, io, .{ .root = abs_root }) catch |err| {
        if (expect_fail) return .{ .expected_failure = &.{} };
        reporter.failWithFailure(a, .{ .kind = .site_init_failed, .err = err });
        return .failure;
    };
    defer site.deinit();

    const diags = site.check(.{}) catch |err| {
        if (expect_fail) return .{ .expected_failure = &.{} };
        reporter.failWithFailure(a, .{ .kind = .build_failed, .err = err });
        return .failure;
    };

    const has_errors = for (diags) |d| {
        if (d.kind == .err) break true;
    } else false;

    if (has_errors and expect_fail) return .{ .expected_failure = diags };
    if (has_errors and !expect_fail) {
        reporter.failWithFailure(a, .{ .kind = .build_failed, .err = error.ValidationFailed });
        return .failure;
    }
    if (!has_errors and expect_fail) {
        reporter.failWithFailure(a, .{ .kind = .expected_fail_but_succeeded });
        return .failure;
    }
    return .{ .ok = diags };
}

/// Verifies that expected diagnostics match actual build diagnostics.
/// Each expected entry must have `kind` (warning/error) and `contains` (substring match).
fn verifyDiagnostics(a: Allocator, actual: diagnostics_mod.Collector, expected: comb.Value, reporter: *Reporter) !void {
    if (expected != .array) return;

    for (expected.array) |entry| {
        if (entry != .object) continue;
        const kind_val = getKey(entry, "kind") orelse continue;
        const contains_val = getKey(entry, "contains") orelse continue;
        if (kind_val != .string or contains_val != .string) continue;

        const expected_kind: diagnostics_mod.Diagnostic.Kind = if (std.mem.eql(u8, kind_val.string, "warning"))
            .warning
        else if (std.mem.eql(u8, kind_val.string, "error"))
            .err
        else
            continue;

        const found = for (actual.items.items) |d| {
            if (d.kind == expected_kind and std.mem.indexOf(u8, d.message, contains_val.string) != null)
                break true;
        } else false;

        if (!found) {
            const msg = std.fmt.allocPrint(a, "expected diagnostic ({s}) containing \"{s}\" not found", .{ kind_val.string, contains_val.string }) catch "diagnostic assertion failed";
            reporter.failWithFailure(a, .{ .kind = .content_mismatch, .path = "diagnostics", .expected = msg, .actual = "no matching diagnostic" });
        }
    }
}

/// Verifies expected diagnostics against check-command diagnostics ([]const root.Diagnostic).
fn verifyCheckDiagnostics(a: Allocator, actual: []const root.Diagnostic, expected: comb.Value, reporter: *Reporter) !void {
    if (expected != .array) return;

    for (expected.array) |entry| {
        if (entry != .object) continue;
        const kind_val = getKey(entry, "kind") orelse continue;
        const contains_val = getKey(entry, "contains") orelse continue;
        if (kind_val != .string or contains_val != .string) continue;

        const expected_kind: root.Diagnostic.Kind = if (std.mem.eql(u8, kind_val.string, "warning"))
            .warning
        else if (std.mem.eql(u8, kind_val.string, "error"))
            .err
        else
            continue;

        const found = for (actual) |d| {
            if (d.kind == expected_kind and std.mem.indexOf(u8, d.message, contains_val.string) != null)
                break true;
        } else false;

        if (!found) {
            const msg = std.fmt.allocPrint(a, "expected diagnostic ({s}) containing \"{s}\" not found", .{ kind_val.string, contains_val.string }) catch "diagnostic assertion failed";
            reporter.failWithFailure(a, .{ .kind = .content_mismatch, .path = "diagnostics", .expected = msg, .actual = "no matching diagnostic" });
        }
    }
}

/// Writes file tree; keys are path segments as on disk (e.g. `templates` / `layouts` / `page.html`).
fn writeFileTree(a: Allocator, io: std.Io, dir: std.Io.Dir, name: []const u8, value: comb.Value) !void {
    const dir_name = name;

    switch (value) {
        .string => |file_content| {
            if (std.fs.path.dirname(dir_name)) |parent| {
                std.Io.Dir.createDirPath(dir, io, parent) catch {};
            }
            var f = try std.Io.Dir.createFile(dir, io, dir_name, .{});
            defer f.close(io);
            try f.writeStreamingAll(io, file_content);
        },
        .object => |entries| {
            std.Io.Dir.createDirPath(dir, io, dir_name) catch {};
            var sub_dir = try std.Io.Dir.openDir(dir, io, dir_name, .{});
            defer sub_dir.close(io);
            for (entries) |entry| {
                const key = getStringKey(entry) orelse continue;
                try writeFileTree(a, io, sub_dir, key, entry.value);
            }
        },
        .boolean => |b| {
            if (b) {
                if (std.fs.path.dirname(dir_name)) |parent| {
                    std.Io.Dir.createDirPath(dir, io, parent) catch {};
                }
                var f = try std.Io.Dir.createFile(dir, io, dir_name, .{});
                f.close(io);
            }
        },
        else => {},
    }
}

// ── Test ──────────────────────────────────────────────────────────────────

test "specNumericPrefix and WIG_TEST numeric match" {
    const testing = std.testing;
    try testing.expectEqualStrings("000", specNumericPrefix("000_one_page.yaml").?);
    try testing.expectEqualStrings("34", specNumericPrefix("34_blog.yaml").?);
    try testing.expect(specNumericPrefix("9_bad.yaml") == null);
    try testing.expect(specNumericPrefix("no_digits.yaml") == null);

    var f = Filter{ .numbers = .{} };
    defer f.deinit(testing.allocator);
    try f.numbers.append(testing.allocator, try testing.allocator.dupe(u8, "34"));
    try testing.expect(f.matchesSpecFilename("034_blog_e2e.yaml"));
    try testing.expect(f.matchesSpecFilename("34_blog_e2e.yaml"));
    try testing.expect(!f.matchesSpecFilename("033_tags.yaml"));
}

test "wig integration test suite" {
    const io = std.testing.io;
    var test_dir = std.Io.Dir.openDir(std.Io.Dir.cwd(), io, "test", .{ .iterate = true }) catch |err| {
        std.debug.print("\nCould not open test directory: {}\n", .{err});
        return err;
    };
    defer test_dir.close(io);

    const filter = std.posix.getenv("WIG_TEST");
    var run_id_buf: [16]u8 = undefined;
    var ws_dir: []const u8 = undefined;

    const total = runSpecTests(std.testing.allocator, io, test_dir, filter, &run_id_buf, null, null, &ws_dir) catch |err| {
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
