const std = @import("std");
const Allocator = std.mem.Allocator;
const html_mod = @import("html.zig");
const scanner_mod = @import("scanner.zig");
const handler_mod = @import("handler.zig");
const app_mod = @import("app.zig");
const bundles_mod = @import("bundles.zig");
const pages_mod = @import("pages.zig");
const toc_import = @import("toc.zig");
const feeds_mod = @import("feeds.zig");
const search_mod = @import("search.zig");
const scaffold_mod = @import("scaffold.zig");
const config_mod = @import("config.zig");
const context_mod = @import("context.zig");
const tokens_mod = @import("tokens.zig");
const colours_mod = @import("colours.zig");
const toupee = @import("toupee");
const comb = @import("comb");
const fs = std.fs;

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

const TestCase = struct {
    name: []const u8,
    sections: std.StringArrayHashMapUnmanaged([]const u8) = .{},
    expected_output: ?[]const u8 = null,
    expected_error: ?[]const u8 = null,
};

const Section = enum { none, named, out };

pub fn runTestFile(a: Allocator, dir: fs.Dir, filename: []const u8) !TestResults {
    const content = try dir.readFileAlloc(a, filename, 1024 * 1024);
    defer a.free(content);

    var results = TestResults{};
    var cases: std.ArrayListUnmanaged(TestCase) = .{};
    defer {
        for (cases.items) |*c| c.sections.deinit(a);
        cases.deinit(a);
    }

    try parseTestCases(a, content, &cases);

    for (cases.items) |*tc| {
        if (runOneCase(a, tc, filename)) {
            results.passed += 1;
        } else |_| {
            results.failed += 1;
        }
    }

    return results;
}

fn runOneCase(backing_a: Allocator, tc: *const TestCase, filename: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(backing_a);
    defer arena.deinit();
    const a = arena.allocator();

    if (tc.sections.get("html")) |html_input| {
        return runHtmlStripCase(a, tc, html_input);
    }

    if (tc.sections.get("path")) |path_input| {
        return runDotPathCase(a, tc, path_input);
    }

    if (tc.sections.get("source-path")) |source_path| {
        return runOutputPathCase(a, tc, source_path);
    }

    if (tc.sections.get("route")) |route_spec| {
        return runRouterCase(a, tc, route_spec);
    }

    if (tc.sections.get("middleware")) |_| {
        return runMiddlewareCase(a, tc);
    }

    if (tc.sections.get("pages-json")) |pages_json| {
        if (tc.sections.get("feed-config")) |_| {
            return runFeedCase(a, tc, pages_json);
        }
        if (tc.expected_output != null and tc.sections.get("sitemap") != null) {
            return runSitemapCase(a, tc, pages_json);
        }
        return runSearchCase(a, tc, pages_json);
    }

    if (tc.sections.get("scaffold-cmd")) |cmd| {
        return runScaffoldCase(a, tc, cmd);
    }

    if (tc.sections.get("tokens")) |_| {
        return runTokenCase(a, tc);
    }

    if (tc.sections.get("highlights")) |_| {
        return runColourCase(a, tc);
    }

    if (tc.sections.get("css-files")) |_| {
        return runBundleCase(a, tc);
    }

    if (tc.sections.get("scan-pages")) |_| {
        return runScanCase(a, tc);
    }

    if (tc.sections.get("page-content")) |_| {
        return runPageRenderCase(a, tc);
    }

    if (tc.sections.get("config")) |_| {
        return runConfigCase(a, tc);
    }

    if (tc.sections.get("comb-input")) |_| {
        return runContextCase(a, tc);
    }

    std.debug.print("    SKIP [{s}] in {s}: no recognized domain section\n", .{ tc.name, filename });
}

// ── Domain runners ──────────────────────────────────────────────────────

fn runHtmlStripCase(a: Allocator, tc: *const TestCase, input: []const u8) !void {
    const expected = tc.expected_output orelse return;
    const result = try html_mod.stripTags(a, input);
    if (!std.mem.eql(u8, result, expected)) {
        std.debug.print("    FAIL [{s}]: html.stripTags\n      expected: '{s}'\n      actual:   '{s}'\n", .{ tc.name, expected, result });
        return error.TestUnexpectedResult;
    }
}

fn runDotPathCase(a: Allocator, tc: *const TestCase, input: []const u8) !void {
    const expected = tc.expected_output orelse return;
    const result = try scanner_mod.dotPath(a, input);
    if (!std.mem.eql(u8, result, expected)) {
        std.debug.print("    FAIL [{s}]: dotPath\n      expected: '{s}'\n      actual:   '{s}'\n", .{ tc.name, expected, result });
        return error.TestUnexpectedResult;
    }
}

fn runOutputPathCase(a: Allocator, tc: *const TestCase, source_path: []const u8) !void {
    const expected = tc.expected_output orelse return;
    const result = try scanner_mod.deriveOutputPath(a, source_path);
    if (!std.mem.eql(u8, result, expected)) {
        std.debug.print("    FAIL [{s}]: deriveOutputPath\n      expected: '{s}'\n      actual:   '{s}'\n", .{ tc.name, expected, result });
        return error.TestUnexpectedResult;
    }
}

fn runRouterCase(a: Allocator, tc: *const TestCase, route_spec: []const u8) !void {
    const expected = tc.expected_output orelse return;
    const request = tc.sections.get("request") orelse return;

    const dummy = struct {
        fn handle(ctx: *handler_mod.Context) anyerror!void {
            if (ctx.params.len > 0) {
                var buf: std.ArrayListUnmanaged(u8) = .{};
                for (ctx.params) |p| {
                    if (buf.items.len > 0) buf.appendSlice(ctx.allocator, ",") catch {};
                    buf.appendSlice(ctx.allocator, p.name) catch {};
                    buf.appendSlice(ctx.allocator, "=") catch {};
                    buf.appendSlice(ctx.allocator, p.value) catch {};
                }
                try ctx.respond(buf.items, "text/plain");
            } else {
                try ctx.respond("matched", "text/plain");
            }
        }
    }.handle;

    var app = app_mod.App.init(a);
    defer app.deinit();

    var route_lines = std.mem.splitScalar(u8, route_spec, '\n');
    while (route_lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        var parts = std.mem.splitScalar(u8, trimmed, ' ');
        const method = parts.next() orelse continue;
        const path = parts.next() orelse continue;
        if (std.mem.eql(u8, method, "GET")) {
            try app.get(path, dummy);
        } else if (std.mem.eql(u8, method, "POST")) {
            try app.post(path, dummy);
        }
    }

    var req_parts = std.mem.splitScalar(u8, std.mem.trim(u8, request, " \t\r\n"), ' ');
    const req_method_str = req_parts.next() orelse return;
    const req_path = req_parts.next() orelse return;

    const method = handler_mod.Method.fromString(req_method_str) orelse .GET;
    var ctx = handler_mod.Context{
        .allocator = a,
        .method = method,
        .path = req_path,
    };
    try app.dispatch(&ctx);

    var result_buf: [256]u8 = undefined;
    const result = std.fmt.bufPrint(&result_buf, "{d} {s}", .{ ctx.response_status, ctx.response_body }) catch return;
    if (!std.mem.eql(u8, result, expected)) {
        std.debug.print("    FAIL [{s}]: router\n      expected: '{s}'\n      actual:   '{s}'\n", .{ tc.name, expected, result });
        return error.TestUnexpectedResult;
    }
}

fn runMiddlewareCase(a: Allocator, tc: *const TestCase) !void {
    const expected = tc.expected_output orelse return;
    const mw_spec = tc.sections.get("middleware") orelse return;

    const final = struct {
        fn handle(ctx: *handler_mod.Context) anyerror!void {
            const existing = ctx.response_body;
            const combined = try std.fmt.allocPrint(ctx.allocator, "{s}handler", .{existing});
            try ctx.respond(combined, "text/plain");
        }
    }.handle;

    var mw_list: std.ArrayListUnmanaged(handler_mod.MiddlewareFn) = .{};
    defer mw_list.deinit(a);

    var lines = std.mem.splitScalar(u8, mw_spec, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        if (std.mem.eql(u8, trimmed, "passthrough")) {
            try mw_list.append(a, struct {
                fn handle(ctx: *handler_mod.Context) anyerror!void {
                    const existing = ctx.response_body;
                    const combined = try std.fmt.allocPrint(ctx.allocator, "{s}mw>", .{existing});
                    ctx.response_body = combined;
                    try ctx.next();
                }
            }.handle);
        } else if (std.mem.eql(u8, trimmed, "block")) {
            try mw_list.append(a, struct {
                fn handle(ctx: *handler_mod.Context) anyerror!void {
                    try ctx.respond("blocked", "text/plain");
                }
            }.handle);
        }
    }

    var ctx = handler_mod.Context{
        .allocator = a,
        ._middleware = mw_list.items,
        ._final_handler = final,
    };
    try ctx.next();

    if (!std.mem.eql(u8, ctx.response_body, expected)) {
        std.debug.print("    FAIL [{s}]: middleware\n      expected: '{s}'\n      actual:   '{s}'\n", .{ tc.name, expected, ctx.response_body });
        return error.TestUnexpectedResult;
    }
}

fn runFeedCase(a: Allocator, tc: *const TestCase, pages_json: []const u8) !void {
    const expected = tc.expected_output orelse return;
    const feed_config_str = tc.sections.get("feed-config") orelse return;

    const pages = try parsePagesJson(a, pages_json);

    var fc_lines = std.mem.splitScalar(u8, feed_config_str, '\n');
    var feed_name: []const u8 = "feed";
    var feed_collection: []const u8 = "pages.posts";
    var feed_title: []const u8 = "Feed";
    while (fc_lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, trimmed, "name: ")) feed_name = trimmed["name: ".len..];
        if (std.mem.startsWith(u8, trimmed, "collection: ")) feed_collection = trimmed["collection: ".len..];
        if (std.mem.startsWith(u8, trimmed, "title: ")) feed_title = trimmed["title: ".len..];
    }

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const feed_cfg = config_mod.FeedConfig{
        .name = feed_name,
        .collection_path = feed_collection,
        .title = feed_title,
    };

    try feeds_mod.generateAtom(a, feed_cfg, pages, "https://example.com", "Test Site", tmp.dir);

    const out_path = try std.fmt.allocPrint(a, "{s}/feed.xml", .{feed_name});
    const content = try tmp.dir.readFileAlloc(a, out_path, 64 * 1024);

    if (!containsAll(content, expected)) {
        std.debug.print("    FAIL [{s}]: feed output missing expected content\n", .{tc.name});
        return error.TestUnexpectedResult;
    }
}

fn runSitemapCase(a: Allocator, tc: *const TestCase, pages_json: []const u8) !void {
    const expected = tc.expected_output orelse return;
    const pages = try parsePagesJson(a, pages_json);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try feeds_mod.generateSitemap(a, pages, tmp.dir);
    const content = try tmp.dir.readFileAlloc(a, "sitemap.xml", 64 * 1024);

    if (!containsAll(content, expected)) {
        std.debug.print("    FAIL [{s}]: sitemap output missing expected content\n", .{tc.name});
        return error.TestUnexpectedResult;
    }
}

fn runSearchCase(a: Allocator, tc: *const TestCase, pages_json: []const u8) !void {
    const expected = tc.expected_output orelse return;
    const pages = try parsePagesJson(a, pages_json);

    var entries: std.ArrayListUnmanaged(search_mod.SearchEntry) = .{};
    defer entries.deinit(a);
    for (pages) |page| {
        const title = getPageStr(page.frontmatter, "title") orelse "";
        const body = if (page.content_body.len > 0)
            (html_mod.stripTags(a, page.content_body) catch "")
        else
            "";
        try entries.append(a, .{
            .url = page.absolute_url,
            .title = title,
            .description = getPageStr(page.frontmatter, "description") orelse "",
            .body = body,
            .tags = &.{},
            .date = getPageStr(page.frontmatter, "date") orelse "",
        });
    }

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try search_mod.generate(a, entries.items, tmp.dir);
    const content = try tmp.dir.readFileAlloc(a, "search-index.json", 64 * 1024);

    if (!containsAll(content, expected)) {
        std.debug.print("    FAIL [{s}]: search index missing expected content\n", .{tc.name});
        return error.TestUnexpectedResult;
    }
}

fn runScaffoldCase(a: Allocator, tc: *const TestCase, cmd: []const u8) !void {
    const expected = tc.expected_output orelse return;
    const trimmed_cmd = std.mem.trim(u8, cmd, " \t\r\n");

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    if (std.mem.eql(u8, trimmed_cmd, "init")) {
        const proj = "project";
        try tmp.dir.makeDir(proj);
        const abs = try tmp.dir.realpathAlloc(a, proj);
        defer a.free(abs);
        try scaffold_mod.init(a, abs);

        const site_yaml = try tmp.dir.readFileAlloc(a, "project/data/site.yaml", 64 * 1024);
        if (!containsAll(site_yaml, expected)) {
            std.debug.print("    FAIL [{s}]: scaffold init output missing expected content\n", .{tc.name});
            return error.TestUnexpectedResult;
        }
    } else if (std.mem.startsWith(u8, trimmed_cmd, "add-style ")) {
        const name = trimmed_cmd["add-style ".len..];
        try tmp.dir.makeDir("styles");
        const abs = try tmp.dir.realpathAlloc(a, "styles");
        defer a.free(abs);
        try scaffold_mod.addStyle(a, abs, name);

        const manifest_path = try std.fmt.allocPrint(a, "styles/{s}/style.yaml", .{name});
        const content = try tmp.dir.readFileAlloc(a, manifest_path, 64 * 1024);
        if (!containsAll(content, expected)) {
            std.debug.print("    FAIL [{s}]: addStyle output missing expected content\n      expected fragment: '{s}'\n", .{ tc.name, expected });
            return error.TestUnexpectedResult;
        }
    } else if (std.mem.startsWith(u8, trimmed_cmd, "add-block ")) {
        const rest = trimmed_cmd["add-block ".len..];
        var parts = std.mem.splitScalar(u8, rest, ' ');
        const style = parts.next() orelse return;
        const block = parts.next() orelse return;

        try tmp.dir.makePath(try std.fmt.allocPrint(a, "styles/{s}", .{style}));
        const abs = try tmp.dir.realpathAlloc(a, "styles");
        defer a.free(abs);
        try scaffold_mod.addBlock(a, abs, style, block);

        const css_path = try std.fmt.allocPrint(a, "styles/{s}/{s}.css", .{ style, block });
        const content = try tmp.dir.readFileAlloc(a, css_path, 64 * 1024);
        if (!containsAll(content, expected)) {
            std.debug.print("    FAIL [{s}]: addBlock output missing expected content\n", .{tc.name});
            return error.TestUnexpectedResult;
        }
    }
}

fn runConfigCase(a: Allocator, tc: *const TestCase) !void {
    const expected = tc.expected_output orelse return;
    const config_yaml = tc.sections.get("config") orelse return;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("data");
    {
        var data_dir = try tmp.dir.openDir("data", .{});
        defer data_dir.close();
        var f = try data_dir.createFile("site.yaml", .{});
        defer f.close();
        try f.writeAll(config_yaml);
    }

    const abs = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(abs);

    var site_cfg = config_mod.loadSiteConfig(a, abs) catch |err| {
        if (tc.expected_error) |err_name| {
            if (std.mem.eql(u8, @errorName(err), err_name)) return;
            std.debug.print("    FAIL [{s}]: expected error '{s}' but got '{s}'\n", .{ tc.name, err_name, @errorName(err) });
            return error.TestWrongError;
        }
        return err;
    };
    defer site_cfg.deinit();

    var result_buf: std.ArrayListUnmanaged(u8) = .{};
    defer result_buf.deinit(a);

    try result_buf.appendSlice(a, try std.fmt.allocPrint(a, "url={s}", .{site_cfg.url}));
    if (site_cfg.title.len > 0)
        try result_buf.appendSlice(a, try std.fmt.allocPrint(a, " title={s}", .{site_cfg.title}));

    if (!containsAll(result_buf.items, expected)) {
        std.debug.print("    FAIL [{s}]: config\n      expected: '{s}'\n      actual:   '{s}'\n", .{ tc.name, expected, result_buf.items });
        return error.TestUnexpectedResult;
    }
}

fn runContextCase(a: Allocator, tc: *const TestCase) !void {
    const expected = tc.expected_output orelse return;
    const comb_input = tc.sections.get("comb-input") orelse return;

    var parsed = comb.parse(a, comb_input) catch {
        std.debug.print("    FAIL [{s}]: failed to parse YAML input\n", .{tc.name});
        return error.TestParseError;
    };
    defer parsed.deinit();

    const toupee_val = context_mod.combToToupee(a, parsed.value) catch {
        std.debug.print("    FAIL [{s}]: failed to convert comb->toupee\n", .{tc.name});
        return error.TestConversionError;
    };

    var result_buf: std.ArrayListUnmanaged(u8) = .{};
    defer result_buf.deinit(a);
    try serializeValue(&result_buf, a, toupee_val);

    if (!containsAll(result_buf.items, expected)) {
        std.debug.print("    FAIL [{s}]: context conversion\n      expected fragment: '{s}'\n      actual: '{s}'\n", .{ tc.name, expected, result_buf.items });
        return error.TestUnexpectedResult;
    }
}

fn runTokenCase(a: Allocator, tc: *const TestCase) !void {
    const expected = tc.expected_output orelse return;
    const tokens_yaml = tc.sections.get("tokens") orelse return;

    var parsed = comb.parse(a, tokens_yaml) catch {
        std.debug.print("    FAIL [{s}]: failed to parse token YAML\n", .{tc.name});
        return error.TestParseError;
    };
    defer parsed.deinit();

    const params = tokens_mod.extractParams(parsed.value, a) catch {
        std.debug.print("    FAIL [{s}]: failed to extract token params\n", .{tc.name});
        return error.TestParseError;
    };

    var result = tokens_mod.compute(a, params) catch {
        if (tc.expected_error) |err_name| {
            _ = err_name;
            return;
        }
        std.debug.print("    FAIL [{s}]: token computation failed\n", .{tc.name});
        return error.TestUnexpectedResult;
    };
    defer result.deinit();

    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(a);
    try serializeValue(&buf, a, result.value);

    if (!containsAll(buf.items, expected)) {
        std.debug.print("    FAIL [{s}]: tokens\n      expected fragments: '{s}'\n      actual: '{s}'\n", .{ tc.name, expected, buf.items });
        return error.TestUnexpectedResult;
    }
}

fn runColourCase(a: Allocator, tc: *const TestCase) !void {
    const expected = tc.expected_output orelse return;
    const highlights_yaml = tc.sections.get("highlights") orelse return;

    var hl_parsed = comb.parse(a, highlights_yaml) catch {
        std.debug.print("    FAIL [{s}]: failed to parse highlights YAML\n", .{tc.name});
        return error.TestParseError;
    };
    defer hl_parsed.deinit();

    var scheme_files: std.ArrayListUnmanaged(colours_mod.SchemeFile) = .{};
    defer scheme_files.deinit(a);

    var section_it = tc.sections.iterator();
    while (section_it.next()) |entry| {
        if (std.mem.startsWith(u8, entry.key_ptr.*, "scheme:")) {
            const name = std.mem.trim(u8, entry.key_ptr.*["scheme:".len..], " ");
            var scheme_parsed = comb.parse(a, entry.value_ptr.*) catch {
                std.debug.print("    FAIL [{s}]: failed to parse scheme '{s}'\n", .{ tc.name, name });
                return error.TestParseError;
            };
            defer scheme_parsed.deinit();
            try scheme_files.append(a, .{ .name = name, .data = scheme_parsed.value });
        }
    }

    var colour_result = colours_mod.resolve(a, hl_parsed.value, scheme_files.items) catch |err| {
        if (tc.expected_error) |err_name| {
            if (std.mem.eql(u8, @errorName(err), err_name)) return;
            std.debug.print("    FAIL [{s}]: expected error '{s}' but got '{s}'\n", .{ tc.name, err_name, @errorName(err) });
            return error.TestWrongError;
        }
        std.debug.print("    FAIL [{s}]: colour resolution failed: {s}\n", .{ tc.name, @errorName(err) });
        return err;
    };
    defer colour_result.deinit();

    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(a);
    try serializeValue(&buf, a, colour_result.value);

    if (!containsAll(buf.items, expected)) {
        std.debug.print("    FAIL [{s}]: colours\n      expected fragments: '{s}'\n      actual: '{s}'\n", .{ tc.name, expected, buf.items });
        return error.TestUnexpectedResult;
    }
}

fn runBundleCase(a: Allocator, tc: *const TestCase) !void {
    const expected = tc.expected_output orelse return;
    const file_spec = tc.sections.get("css-files") orelse return;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("styles");
    try tmp.dir.makePath("output");

    var file_list: std.ArrayListUnmanaged([]const u8) = .{};
    defer file_list.deinit(a);

    var lines = std.mem.splitScalar(u8, file_spec, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        if (std.mem.indexOf(u8, trimmed, ":")) |colon| {
            const name = std.mem.trim(u8, trimmed[0..colon], " ");
            const css_content = std.mem.trim(u8, trimmed[colon + 1 ..], " ");
            const path = try std.fmt.allocPrint(a, "styles/{s}", .{name});
            if (std.fs.path.dirname(path)) |dir| tmp.dir.makePath(dir) catch {};
            var f = try tmp.dir.createFile(path, .{});
            defer f.close();
            try f.writeAll(css_content);
            try file_list.append(a, name);
        }
    }

    var styles_dir = try tmp.dir.openDir("styles", .{ .iterate = true });
    defer styles_dir.close();
    var output_dir = try tmp.dir.openDir("output", .{});
    defer output_dir.close();

    var ctx = toupee.Context.init(a);
    const result = bundles_mod.processBundle(
        a,
        "test",
        "css",
        "bundle",
        file_list.items,
        styles_dir,
        &ctx,
        output_dir,
    ) catch |err| {
        std.debug.print("    FAIL [{s}]: bundle processing failed: {s}\n", .{ tc.name, @errorName(err) });
        return err;
    };

    if (!containsAll(result.content, expected)) {
        std.debug.print("    FAIL [{s}]: bundle content\n      expected fragment: '{s}'\n      actual: '{s}'\n", .{ tc.name, expected, result.content });
        return error.TestUnexpectedResult;
    }
}

fn runScanCase(a: Allocator, tc: *const TestCase) !void {
    const expected = tc.expected_output orelse return;
    const pages_spec = tc.sections.get("scan-pages") orelse return;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var lines = std.mem.splitScalar(u8, pages_spec, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        if (std.mem.indexOf(u8, trimmed, "|")) |sep| {
            const path = std.mem.trim(u8, trimmed[0..sep], " ");
            const raw_content = std.mem.trim(u8, trimmed[sep + 1 ..], " ");
            const content = try unescapeNewlines(a, raw_content);
            if (std.fs.path.dirname(path)) |dir| tmp.dir.makePath(dir) catch {};
            var f = try tmp.dir.createFile(path, .{});
            defer f.close();
            try f.writeAll(content);
        }
    }

    const draft_mode = tc.sections.get("draft-mode") != null;

    var pages_dir = tmp.dir.openDir(".", .{ .iterate = true }) catch {
        std.debug.print("    FAIL [{s}]: could not open scan dir\n", .{tc.name});
        return error.TestUnexpectedResult;
    };
    defer pages_dir.close();

    var result = scanner_mod.scan(a, pages_dir, "https://example.com", draft_mode, false, &.{}) catch |err| {
        if (tc.expected_error) |err_name| {
            if (std.mem.eql(u8, @errorName(err), err_name)) return;
            std.debug.print("    FAIL [{s}]: expected error '{s}' but got '{s}'\n", .{ tc.name, err_name, @errorName(err) });
            return error.TestWrongError;
        }
        return err;
    };
    defer result.deinit();

    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(a);

    for (result.pages) |page| {
        try buf.appendSlice(a, page.source_path);
        try buf.appendSlice(a, " -> ");
        try buf.appendSlice(a, page.collection_key);
        if (page.is_section) try buf.appendSlice(a, " [section]");
        try buf.appendSlice(a, "\n");
    }

    if (!containsAll(buf.items, expected)) {
        std.debug.print("    FAIL [{s}]: scanner\n      expected fragments: '{s}'\n      actual: '{s}'\n", .{ tc.name, expected, buf.items });
        return error.TestUnexpectedResult;
    }
}

fn runPageRenderCase(a: Allocator, tc: *const TestCase) !void {
    const expected = tc.expected_output orelse return;
    const page_content = tc.sections.get("page-content") orelse return;

    var engine = try toupee.Engine.init(a);
    defer engine.deinit();

    var section_it = tc.sections.iterator();
    while (section_it.next()) |entry| {
        if (std.mem.startsWith(u8, entry.key_ptr.*, "template:")) {
            const name = std.mem.trim(u8, entry.key_ptr.*["template:".len..], " ");
            try engine.addTemplate(name, entry.value_ptr.*);
        }
    }

    const fm_yaml = tc.sections.get("frontmatter") orelse "layout: default/page.html";

    var fm_parsed = comb.parse(a, fm_yaml) catch {
        std.debug.print("    FAIL [{s}]: failed to parse frontmatter YAML\n", .{tc.name});
        return error.TestParseError;
    };
    defer fm_parsed.deinit();
    const fm_val = try context_mod.combToToupee(a, fm_parsed.value);

    const layout_name = if (fm_val == .map)
        if (fm_val.map.get("layout")) |l| (if (l == .string) l.string else "default/page.html") else "default/page.html"
    else
        "default/page.html";

    const ext = tc.sections.get("extension") orelse ".html";

    var entry = scanner_mod.PageEntry{
        .source_path = "test-page.html",
        .output_file = "test-page/index.html",
        .url_path = "/test-page/",
        .absolute_url = "https://example.com/test-page/",
        .content_body = page_content,
        .extension = ext,
        .frontmatter = fm_val,
        .collection_key = "pages",
    };
    _ = &entry;

    const content_html = if (std.mem.eql(u8, ext, ".html")) try a.dupe(u8, page_content) else page_content;

    var base_ctx = toupee.Context.init(a);
    try base_ctx.putAt("page.title", if (fm_val == .map) fm_val.map.get("title") orelse .{ .string = "Test" } else .{ .string = "Test" });
    try base_ctx.putAt("page.path", .{ .string = "/test-page/" });
    try base_ctx.putAt("page.url", .{ .string = "https://example.com/test-page/" });

    if (fm_val == .map) {
        var fm_it = fm_val.map.iterator();
        while (fm_it.next()) |fm_entry| {
            const key = try std.fmt.allocPrint(a, "page.{s}", .{fm_entry.key_ptr.*});
            try base_ctx.putAt(key, fm_entry.value_ptr.*);
        }
    }

    const toc_entries = try toc_import.extract(a, content_html);

    if (tc.sections.get("check") != null and std.mem.eql(u8, tc.sections.get("check").?, "toc")) {
        var buf: std.ArrayListUnmanaged(u8) = .{};
        defer buf.deinit(a);
        for (toc_entries) |toc_entry| {
            try buf.appendSlice(a, try std.fmt.allocPrint(a, "h{d} {s} #{s}\n", .{ toc_entry.level, toc_entry.text, toc_entry.id }));
        }
        if (!containsAll(buf.items, expected)) {
            std.debug.print("    FAIL [{s}]: ToC\n      expected: '{s}'\n      actual: '{s}'\n", .{ tc.name, expected, buf.items });
            return error.TestUnexpectedResult;
        }
        return;
    }

    if (tc.sections.get("check") != null and std.mem.eql(u8, tc.sections.get("check").?, "excerpt")) {
        const excerpt = pages_mod.extractExcerptPublic(a, fm_val, content_html) orelse "";
        if (!std.mem.eql(u8, excerpt, expected)) {
            std.debug.print("    FAIL [{s}]: excerpt\n      expected: '{s}'\n      actual: '{s}'\n", .{ tc.name, expected, excerpt });
            return error.TestUnexpectedResult;
        }
        return;
    }

    const toc_value = try toc_import.toValue(a, toc_entries);
    try base_ctx.putAt("page.toc", toc_value);
    try base_ctx.setSlot("", content_html);

    var resolver: toupee.Resolver = .{};
    const rendered = engine.renderTemplate(a, layout_name, &base_ctx, resolver.loader(), .{}) catch |err| {
        if (tc.expected_error) |err_name| {
            if (std.mem.eql(u8, @errorName(err), err_name)) return;
        }
        std.debug.print("    FAIL [{s}]: render failed: {s}\n", .{ tc.name, @errorName(err) });
        return err;
    };

    if (!containsAll(rendered, expected)) {
        std.debug.print("    FAIL [{s}]: page render\n      expected fragment: '{s}'\n      actual: '{s}'\n", .{ tc.name, expected, rendered });
        return error.TestUnexpectedResult;
    }
}

// ── Helpers ─────────────────────────────────────────────────────────────

fn getPageStr(fm: toupee.Value, key: []const u8) ?[]const u8 {
    if (fm != .map) return null;
    const val = fm.map.get(key) orelse return null;
    if (val != .string) return null;
    return val.string;
}

fn containsAll(haystack: []const u8, needles: []const u8) bool {
    var lines = std.mem.splitScalar(u8, needles, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        if (std.mem.indexOf(u8, haystack, trimmed) == null) return false;
    }
    return true;
}

fn parsePagesJson(a: Allocator, json_str: []const u8) ![]const scanner_mod.PageEntry {
    const parsed = std.json.parseFromSlice(std.json.Value, a, json_str, .{
        .allocate = .alloc_always,
    }) catch return &.{};
    defer parsed.deinit();

    if (parsed.value != .array) return &.{};

    var entries: std.ArrayListUnmanaged(scanner_mod.PageEntry) = .{};
    for (parsed.value.array.items) |item| {
        if (item != .object) continue;
        const obj = item.object;

        var fm = std.StringArrayHashMapUnmanaged(toupee.Value){};
        if (obj.get("title")) |t| {
            if (t == .string) try fm.put(a, "title", .{ .string = try a.dupe(u8, t.string) });
        }
        if (obj.get("date")) |d| {
            if (d == .string) try fm.put(a, "date", .{ .string = try a.dupe(u8, d.string) });
        }
        if (obj.get("tags")) |tags_val| {
            if (tags_val == .array) {
                const tag_items = try a.alloc(toupee.Value, tags_val.array.items.len);
                for (tags_val.array.items, tag_items) |tv, *out| {
                    out.* = if (tv == .string) .{ .string = try a.dupe(u8, tv.string) } else .{ .string = "" };
                }
                try fm.put(a, "tags", .{ .list = tag_items });
            }
        }

        try entries.append(a, .{
            .source_path = try a.dupe(u8, if (obj.get("source")) |s| (if (s == .string) s.string else "page.dj") else "page.dj"),
            .output_file = try a.dupe(u8, if (obj.get("output")) |s| (if (s == .string) s.string else "index.html") else "index.html"),
            .url_path = try a.dupe(u8, if (obj.get("url_path")) |s| (if (s == .string) s.string else "/") else "/"),
            .absolute_url = try a.dupe(u8, if (obj.get("absolute_url")) |s| (if (s == .string) s.string else "https://example.com/") else "https://example.com/"),
            .content_body = try a.dupe(u8, if (obj.get("content")) |s| (if (s == .string) s.string else "") else ""),
            .extension = ".dj",
            .frontmatter = .{ .map = fm },
            .collection_key = try a.dupe(u8, if (obj.get("collection")) |s| (if (s == .string) s.string else "pages") else "pages"),
        });
    }

    return try entries.toOwnedSlice(a);
}

fn serializeValue(buf: *std.ArrayListUnmanaged(u8), a: Allocator, val: toupee.Value) !void {
    switch (val) {
        .string => |s| {
            try buf.appendSlice(a, "\"");
            try buf.appendSlice(a, s);
            try buf.appendSlice(a, "\"");
        },
        .integer => |i| {
            try buf.appendSlice(a, try std.fmt.allocPrint(a, "{d}", .{i}));
        },
        .boolean => |b| {
            try buf.appendSlice(a, if (b) "true" else "false");
        },
        .map => |m| {
            try buf.appendSlice(a, "{");
            var it = m.iterator();
            var first = true;
            while (it.next()) |entry| {
                if (!first) try buf.appendSlice(a, ",");
                first = false;
                try buf.appendSlice(a, entry.key_ptr.*);
                try buf.appendSlice(a, ":");
                try serializeValue(buf, a, entry.value_ptr.*);
            }
            try buf.appendSlice(a, "}");
        },
        .list => |items| {
            try buf.appendSlice(a, "[");
            for (items, 0..) |item, i| {
                if (i > 0) try buf.appendSlice(a, ",");
                try serializeValue(buf, a, item);
            }
            try buf.appendSlice(a, "]");
        },
        else => try buf.appendSlice(a, "null"),
    }
}

// ── Parser ──────────────────────────────────────────────────────────────

fn parseTestCases(a: Allocator, content: []const u8, cases: *std.ArrayListUnmanaged(TestCase)) !void {
    var current: ?*TestCase = null;
    var section_name: []const u8 = "";
    var section_state: Section = .none;
    var section_start: usize = 0;

    var i: usize = 0;
    while (i < content.len) {
        const line_start = i;
        const line_end = std.mem.indexOfScalarPos(u8, content, i, '\n') orelse content.len;
        const line = content[line_start..line_end];
        const trimmed = std.mem.trim(u8, line, " \t\r");

        if (std.mem.startsWith(u8, trimmed, "<!-- test: ")) {
            if (current) |c| finishSection(a, content, section_state, section_name, section_start, line_start, c);
            const after = "<!-- test: ".len;
            const end = std.mem.indexOf(u8, trimmed[after..], " -->") orelse trimmed.len - after;
            const tc = try cases.addOne(a);
            tc.* = .{ .name = trimmed[after .. after + end] };
            current = tc;
            section_state = .none;
        } else if (std.mem.eql(u8, trimmed, "<!-- out -->")) {
            if (current) |c| finishSection(a, content, section_state, section_name, section_start, line_start, c);
            section_state = .out;
            section_start = line_end + 1;
        } else if (std.mem.startsWith(u8, trimmed, "<!-- error: ")) {
            if (current) |c| {
                finishSection(a, content, section_state, section_name, section_start, line_start, c);
                const after = "<!-- error: ".len;
                const end = std.mem.indexOf(u8, trimmed[after..], " -->") orelse trimmed.len - after;
                c.expected_error = trimmed[after .. after + end];
            }
            section_state = .none;
        } else if (std.mem.startsWith(u8, trimmed, "<!-- ") and std.mem.endsWith(u8, trimmed, " -->")) {
            if (current) |c| finishSection(a, content, section_state, section_name, section_start, line_start, c);
            const inner = trimmed["<!-- ".len .. trimmed.len - " -->".len];
            section_name = inner;
            section_state = .named;
            section_start = line_end + 1;
        }

        i = if (line_end < content.len) line_end + 1 else content.len;
    }

    if (current) |c| finishSection(a, content, section_state, section_name, section_start, content.len, c);
}

fn finishSection(a: Allocator, content: []const u8, state: Section, name: []const u8, start: usize, end: usize, tc: *TestCase) void {
    if (state == .none) return;

    const clamped_end = @min(end, content.len);
    const trimmed = if (start > content.len or start >= clamped_end)
        ""
    else
        trimEnds(content[start..clamped_end]);

    switch (state) {
        .named => tc.sections.put(a, name, trimmed) catch {},
        .out => {
            if (trimmed.len > 0) tc.expected_output = trimmed;
        },
        .none => {},
    }
}

fn unescapeNewlines(a: Allocator, input: []const u8) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(a);
    var i: usize = 0;
    while (i < input.len) {
        if (i + 1 < input.len and input[i] == '\\' and input[i + 1] == 'n') {
            try buf.append(a, '\n');
            i += 2;
        } else {
            try buf.append(a, input[i]);
            i += 1;
        }
    }
    return try a.dupe(u8, buf.items);
}

fn trimEnds(s: []const u8) []const u8 {
    var start: usize = 0;
    if (start < s.len and s[start] == '\n') start += 1;
    var end = s.len;
    while (end > start and (s[end - 1] == '\n' or s[end - 1] == '\r' or
        s[end - 1] == ' ' or s[end - 1] == '\t')) : (end -= 1)
    {}
    return s[start..end];
}

// ── Test file list ──────────────────────────────────────────────────────

const test_file_names = [_][]const u8{
    "smoke.test",
    "html.test",
    "scanner.test",
    "web-framework.test",
    "post-build.test",
    "scaffold.test",
    "data-pipeline.test",
    "css-pipeline.test",
    "page-rendering.test",
};

test "wig integration test suite" {
    var test_dir = fs.cwd().openDir("test", .{}) catch |err| {
        std.debug.print("\nCould not open test directory: {}\n", .{err});
        return err;
    };
    defer test_dir.close();

    var total = TestResults{};
    var any_failed = false;

    for (test_file_names) |filename| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();

        const results = runTestFile(arena.allocator(), test_dir, filename) catch |err| {
            std.debug.print("  {s}: ERROR ({})\n", .{ filename, err });
            total.failed += 1;
            any_failed = true;
            continue;
        };

        const dot_pos = std.mem.lastIndexOfScalar(u8, filename, '.') orelse filename.len;
        const name = filename[0..dot_pos];
        std.debug.print("  {s}: {d}/{d} passed\n", .{ name, results.passed, results.total() });
        if (results.failed > 0) any_failed = true;
        total.add(results);
    }

    std.debug.print("\n  Total: {d}/{d} passed\n\n", .{ total.passed, total.total() });

    if (any_failed) return error.TestSuiteFailure;
}
