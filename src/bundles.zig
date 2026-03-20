const std = @import("std");
const toupee = @import("toupee");
const comb = @import("comb");
const frontmatter = @import("frontmatter.zig");
const context_mod = @import("context.zig");

const Allocator = std.mem.Allocator;
const fs = std.fs;

const ValueMap = std.StringArrayHashMapUnmanaged(toupee.Value);

pub const BundleResult = struct {
    path: []const u8,
    hash: []const u8,
    content: []const u8,
};

/// Processes a single asset bundle from a style manifest.
///
/// Expands globs, detects frontmatter in each file, renders files that have
/// frontmatter through Toupee (merging file-level frontmatter data into the
/// style context), passes through files without frontmatter, concatenates
/// in manifest order, content-hashes with SHA-256 (truncated to 8 hex chars),
/// and writes the fingerprinted file to `output_dir`.
///
/// Processes a single bundle file and writes to an exact output path (no hash).
/// Used for `bundles: [ "css/tokens.css" ]` array format.
/// `output_path` is the path relative to output_dir (e.g. "css/tokens.css").
/// `template_rel` is the path within the style dir (e.g. "css/tokens.css").
pub fn processBundleToPath(
    a: Allocator,
    style_name: []const u8,
    output_path: []const u8,
    template_rel: []const u8,
    styles_dir: fs.Dir,
    style_ctx: *const toupee.Context,
    output_dir: fs.Dir,
) !BundleResult {
    const full_template_path = try std.fmt.allocPrint(a, "{s}/{s}", .{ style_name, template_rel });
    defer a.free(full_template_path);

    const content = try processFile(a, styles_dir, full_template_path, style_ctx);

    output_dir.makePath(std.fs.path.dirname(output_path) orelse ".") catch {};
    var out_file = try output_dir.createFile(output_path, .{});
    defer out_file.close();
    try out_file.writeAll(content);

    return .{
        .path = try a.dupe(u8, output_path),
        .hash = "",
        .content = content,
    };
}

/// Returns the fingerprinted path, hash, and full content string.
pub fn processBundle(
    a: Allocator,
    style_name: []const u8,
    bundle_type: []const u8,
    bundle_name: []const u8,
    file_patterns: []const []const u8,
    styles_dir: fs.Dir,
    style_ctx: *const toupee.Context,
    output_dir: fs.Dir,
) !BundleResult {
    var parts: std.ArrayListUnmanaged([]const u8) = .{};
    defer parts.deinit(a);

    for (file_patterns) |pattern| {
        const files = try expandGlob(a, styles_dir, pattern);
        defer {
            for (files) |f| a.free(f);
            a.free(files);
        }
        for (files) |rel_path| {
            const chunk = try processFile(a, styles_dir, rel_path, style_ctx);
            try parts.append(a, chunk);
        }
    }

    const content = try std.mem.join(a, "\n", parts.items);

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(content);
    const digest = hasher.finalResult();
    const hex = std.fmt.bytesToHex(digest[0..4].*, .lower);
    const hash = try a.dupe(u8, &hex);

    const filename = try std.fmt.allocPrint(a, "{s}.{s}.{s}", .{ bundle_name, hash, bundle_type });
    defer a.free(filename);

    const out_subdir = try std.fmt.allocPrint(a, "{s}/{s}", .{ bundle_type, style_name });
    defer a.free(out_subdir);

    output_dir.makePath(out_subdir) catch {};

    const out_path = try std.fmt.allocPrint(a, "{s}/{s}", .{ out_subdir, filename });
    defer a.free(out_path);

    var out_file = try output_dir.createFile(out_path, .{});
    defer out_file.close();
    try out_file.writeAll(content);

    const path = try std.fmt.allocPrint(a, "{s}/{s}/{s}", .{ bundle_type, style_name, filename });

    return .{
        .path = path,
        .hash = hash,
        .content = content,
    };
}

/// Reads a single file, optionally rendering through Toupee if frontmatter
/// is detected. Files with `---` frontmatter have their YAML data merged
/// into the style context before rendering. Files without frontmatter are
/// returned as-is.
fn processFile(
    a: Allocator,
    styles_dir: fs.Dir,
    rel_path: []const u8,
    style_ctx: *const toupee.Context,
) ![]const u8 {
    const source = try styles_dir.readFileAlloc(a, rel_path, 4 * 1024 * 1024);
    defer a.free(source);

    var fm_result = try frontmatter.parse(a, source);
    if (fm_result) |*fm| {
        defer fm.deinit();

        var work_arena = std.heap.ArenaAllocator.init(a);
        defer work_arena.deinit();
        const wa = work_arena.allocator();

        var ctx = try toupee.Context.initFrom(wa, style_ctx);

        const fm_toupee = try context_mod.combToToupee(wa, fm.data);
        if (fm_toupee == .map) {
            var it = fm_toupee.map.iterator();
            while (it.next()) |entry| {
                try ctx.put(entry.key_ptr.*, entry.value_ptr.*);
            }
        }

        var resolver: toupee.Resolver = .{};
        const rendered = try toupee.render(wa, fm.content, &ctx, resolver.loader(), .{});
        return try a.dupe(u8, rendered);
    }

    return try a.dupe(u8, source);
}

/// Expands a glob-like pattern relative to a styles directory.
///
/// Supported patterns:
///   - `path/to/dir/*` -- all files in the directory, sorted alphabetically
///   - `path/to/dir/*.css` -- files matching the extension, sorted
///   - `path/to/file.css` -- literal file path (returned as-is)
///
/// Returns owned slice of owned path strings. Caller frees both.
pub fn expandGlob(a: Allocator, base_dir: fs.Dir, pattern: []const u8) ![][]const u8 {
    if (!std.mem.endsWith(u8, pattern, "/*") and !hasExtGlob(pattern)) {
        const single = try a.dupe(u8, pattern);
        const result = try a.alloc([]const u8, 1);
        result[0] = single;
        return result;
    }

    const star_pos = std.mem.lastIndexOfScalar(u8, pattern, '*') orelse unreachable;
    const dir_path = if (star_pos > 0 and pattern[star_pos - 1] == '/')
        pattern[0 .. star_pos - 1]
    else
        pattern[0..star_pos];

    const ext_filter: ?[]const u8 = blk: {
        if (star_pos + 1 < pattern.len) {
            break :blk pattern[star_pos + 1 ..];
        }
        break :blk null;
    };

    var sub_dir = base_dir.openDir(dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return try a.alloc([]const u8, 0),
        else => return err,
    };
    defer sub_dir.close();

    var names: std.ArrayListUnmanaged([]const u8) = .{};
    defer names.deinit(a);

    var it = sub_dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;

        if (ext_filter) |ext| {
            if (!std.mem.endsWith(u8, entry.name, ext)) continue;
        }

        const full = try std.fmt.allocPrint(a, "{s}/{s}", .{ dir_path, entry.name });
        try names.append(a, full);
    }

    std.mem.sort([]const u8, names.items, {}, struct {
        fn cmp(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.order(u8, lhs, rhs) == .lt;
        }
    }.cmp);

    return try a.dupe([]const u8, names.items);
}

/// Checks if the pattern has an extension glob (e.g. `*.css`).
fn hasExtGlob(pattern: []const u8) bool {
    if (std.mem.lastIndexOfScalar(u8, pattern, '*')) |pos| {
        return pos + 1 < pattern.len and pattern[pos + 1] == '.';
    }
    return false;
}

/// Builds the asset context map from processed bundle results.
/// Produces: `{ style_name: { bundle_type: { bundle_name: { path, hash, content } } } }`
pub fn buildAssetContext(a: Allocator, results: []const AssetEntry) !toupee.Value {
    var root = ValueMap{};

    for (results) |entry| {
        var style_map = if (root.get(entry.style_name)) |v| switch (v) {
            .map => |m| m,
            else => ValueMap{},
        } else ValueMap{};

        var type_map = if (style_map.get(entry.bundle_type)) |v| switch (v) {
            .map => |m| m,
            else => ValueMap{},
        } else ValueMap{};

        var bundle_map = ValueMap{};
        try bundle_map.put(a, "path", .{ .string = entry.result.path });
        try bundle_map.put(a, "hash", .{ .string = entry.result.hash });
        try bundle_map.put(a, "content", .{ .string = entry.result.content });

        try type_map.put(a, entry.bundle_name, .{ .map = bundle_map });
        try style_map.put(a, entry.bundle_type, .{ .map = type_map });
        try root.put(a, entry.style_name, .{ .map = style_map });
    }

    return .{ .map = root };
}

pub const AssetEntry = struct {
    style_name: []const u8,
    bundle_type: []const u8,
    bundle_name: []const u8,
    result: BundleResult,
};

// ── Tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

test "expandGlob: literal path returns single entry" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var f = try tmp.dir.createFile("reset.css", .{});
    f.close();

    const result = try expandGlob(testing.allocator, tmp.dir, "reset.css");
    defer {
        for (result) |r| testing.allocator.free(r);
        testing.allocator.free(result);
    }

    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expectEqualStrings("reset.css", result[0]);
}

test "expandGlob: wildcard lists directory sorted" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("compositions");
    var dir = try tmp.dir.openDir("compositions", .{});
    defer dir.close();

    var c = try dir.createFile("cluster.css", .{});
    c.close();
    var f = try dir.createFile("flow.css", .{});
    f.close();
    var w = try dir.createFile("wrapper.css", .{});
    w.close();

    const result = try expandGlob(testing.allocator, tmp.dir, "compositions/*");
    defer {
        for (result) |r| testing.allocator.free(r);
        testing.allocator.free(result);
    }

    try testing.expectEqual(@as(usize, 3), result.len);
    try testing.expectEqualStrings("compositions/cluster.css", result[0]);
    try testing.expectEqualStrings("compositions/flow.css", result[1]);
    try testing.expectEqualStrings("compositions/wrapper.css", result[2]);
}

test "expandGlob: extension filter" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("js");
    var dir = try tmp.dir.openDir("js", .{});
    defer dir.close();

    var a_f = try dir.createFile("app.js", .{});
    a_f.close();
    var r_f = try dir.createFile("readme.txt", .{});
    r_f.close();

    const result = try expandGlob(testing.allocator, tmp.dir, "js/*.js");
    defer {
        for (result) |r| testing.allocator.free(r);
        testing.allocator.free(result);
    }

    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expectEqualStrings("js/app.js", result[0]);
}

test "expandGlob: missing directory returns empty" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const result = try expandGlob(testing.allocator, tmp.dir, "nonexistent/*");
    defer testing.allocator.free(result);

    try testing.expectEqual(@as(usize, 0), result.len);
}

test "expandGlob: skips subdirectories" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("styles/subdir");
    var dir = try tmp.dir.openDir("styles", .{});
    defer dir.close();
    var f = try dir.createFile("main.css", .{});
    f.close();

    const result = try expandGlob(testing.allocator, tmp.dir, "styles/*");
    defer {
        for (result) |r| testing.allocator.free(r);
        testing.allocator.free(result);
    }

    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expectEqualStrings("styles/main.css", result[0]);
}

test "buildAssetContext: produces correct structure" {
    const a = testing.allocator;
    const entries = [_]AssetEntry{
        .{
            .style_name = "default",
            .bundle_type = "css",
            .bundle_name = "layout",
            .result = .{
                .path = "css/default/layout.a1b2c3d4.css",
                .hash = "a1b2c3d4",
                .content = "body { margin: 0; }",
            },
        },
    };

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try buildAssetContext(alloc, &entries);

    const default_map = result.map.get("default").?.map;
    const css_map = default_map.get("css").?.map;
    const layout_map = css_map.get("layout").?.map;

    try testing.expectEqualStrings("css/default/layout.a1b2c3d4.css", layout_map.get("path").?.string);
    try testing.expectEqualStrings("a1b2c3d4", layout_map.get("hash").?.string);
    try testing.expectEqualStrings("body { margin: 0; }", layout_map.get("content").?.string);
}

test "buildAssetContext: multiple bundles" {
    const a = testing.allocator;
    const entries = [_]AssetEntry{
        .{
            .style_name = "default",
            .bundle_type = "css",
            .bundle_name = "layout",
            .result = .{ .path = "css/default/layout.abc.css", .hash = "abc", .content = "a" },
        },
        .{
            .style_name = "default",
            .bundle_type = "js",
            .bundle_name = "main",
            .result = .{ .path = "js/default/main.def.js", .hash = "def", .content = "b" },
        },
    };

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try buildAssetContext(alloc, &entries);
    const default_map = result.map.get("default").?.map;

    try testing.expect(default_map.get("css") != null);
    try testing.expect(default_map.get("js") != null);

    const js_main = default_map.get("js").?.map.get("main").?.map;
    try testing.expectEqualStrings("def", js_main.get("hash").?.string);
}

test "processFile: plain file without frontmatter" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var f = try tmp.dir.createFile("plain.css", .{});
    try f.writeAll("body { margin: 0; }");
    f.close();

    var ctx = toupee.Context.init(testing.allocator);
    defer ctx.deinit();

    const result = try processFile(testing.allocator, tmp.dir, "plain.css", &ctx);
    defer testing.allocator.free(result);

    try testing.expectEqualStrings("body { margin: 0; }", result);
}

test "processFile: file with frontmatter is rendered" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var f = try tmp.dir.createFile("template.css", .{});
    try f.writeAll("---\ncolor: red\n---\n.text { color: <t-raw name=\"color\" />; }");
    f.close();

    var ctx = toupee.Context.init(testing.allocator);
    defer ctx.deinit();

    const result = try processFile(testing.allocator, tmp.dir, "template.css", &ctx);
    defer testing.allocator.free(result);

    try testing.expectEqualStrings(".text { color: red; }", result);
}

test "processFile: frontmatter data merges with style context" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var f = try tmp.dir.createFile("vars.css", .{});
    try f.writeAll("---\nlocal_var: blue\n---\n.link { color: <t-raw name=\"local_var\" />; bg: <t-raw name=\"global_var\" />; }");
    f.close();

    var ctx = toupee.Context.init(testing.allocator);
    defer ctx.deinit();
    try ctx.put("global_var", .{ .string = "white" });

    const result = try processFile(testing.allocator, tmp.dir, "vars.css", &ctx);
    defer testing.allocator.free(result);

    try testing.expectEqualStrings(".link { color: blue; bg: white; }", result);
}
