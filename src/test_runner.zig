const std = @import("std");
const Allocator = std.mem.Allocator;
const html_mod = @import("html.zig");
const scanner_mod = @import("scanner.zig");
const handler_mod = @import("handler.zig");
const app_mod = @import("app.zig");
const feeds_mod = @import("feeds.zig");
const search_mod = @import("search.zig");
const scaffold_mod = @import("scaffold.zig");
const config_mod = @import("config.zig");
const context_mod = @import("context.zig");
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

    var handler_response: []const u8 = "matched";
    _ = &handler_response;

    const dummy = struct {
        fn handle(ctx: *handler_mod.Context) anyerror!void {
            try ctx.respond("matched", "text/plain");
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
    if (start > content.len) return;
    const clamped_end = @min(end, content.len);
    if (start >= clamped_end) return;

    const raw = content[start..clamped_end];
    const trimmed = trimEnds(raw);

    switch (state) {
        .named => tc.sections.put(a, name, trimmed) catch {},
        .out => tc.expected_output = trimmed,
        .none => {},
    }
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
