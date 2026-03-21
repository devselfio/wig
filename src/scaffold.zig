const std = @import("std");

const Allocator = std.mem.Allocator;
const fs = std.fs;

const project_dirs = [_][]const u8{ "data", "pages", "styles", "assets" };

/// CUBE-aligned subdirs under styles/{name}: templates, css, patterns.
const style_subdirs = [_][]const u8{
    "templates/layouts",
    "templates/blocks",
    "css/compositions",
    "css/blocks",
    "css/fonts",
    "css/globals",
    "css/utilities",
    "css/exceptions",
    "patterns/blocks",
    "patterns/compositions",
    "patterns/utilities",
    "patterns/exceptions",
    "patterns/fonts",
    "patterns/globals",
};

/// Copies `wig/skel/site` (resolved next to the wig binary or from cwd) into `dst_abs`.
fn copyTree(a: Allocator, src_abs: []const u8, dst_abs: []const u8) !void {
    var src_root = try fs.openDirAbsolute(src_abs, .{ .iterate = true });
    defer src_root.close();
    var dst_root = try fs.openDirAbsolute(dst_abs, .{});
    defer dst_root.close();

    var walker = try src_root.walk(a);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        switch (entry.kind) {
            .directory => {},
            .file => {
                if (fs.path.dirname(entry.path)) |d| {
                    try dst_root.makePath(d);
                }
                const content = try src_root.readFileAlloc(a, entry.path, 10 * 1024 * 1024);
                defer a.free(content);
                var out = try dst_root.createFile(entry.path, .{});
                defer out.close();
                try out.writeAll(content);
            },
            else => {},
        }
    }
}

fn fallBackCwdSkel(a: Allocator) ![]const u8 {
    const cwd = try fs.cwd().realpathAlloc(a, ".");
    defer a.free(cwd);
    const p = try fs.path.join(a, &.{ cwd, "skel", "site" });
    try fs.accessAbsolute(p, .{});
    return p;
}

/// Resolves the skeleton site directory (`skel/site` under the wig repo).
pub fn resolveSkelSiteDir(a: Allocator) ![]const u8 {
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe = fs.selfExePath(&exe_buf) catch return try fallBackCwdSkel(a);
    const exe_dir = fs.path.dirname(exe) orelse return try fallBackCwdSkel(a);
    const candidate = try fs.path.join(a, &.{ exe_dir, "..", "skel", "site" });
    defer a.free(candidate);
    const resolved = try fs.path.resolve(a, &.{candidate});
    fs.accessAbsolute(resolved, .{}) catch {
        a.free(resolved);
        return try fallBackCwdSkel(a);
    };
    return resolved;
}

/// Scaffolds a new Wig project by copying `skel/site` (see `resolveSkelSiteDir`).
pub fn init(a: Allocator, target_path: []const u8) !void {
    fs.cwd().makePath(target_path) catch {};
    const abs = try fs.realpathAlloc(a, target_path);
    defer a.free(abs);

    const skel = try resolveSkelSiteDir(a);
    defer a.free(skel);

    try copyTree(a, skel, abs);
}

/// Installs a style from wig-stand or a git URL.
///
/// **Deferred:** Requires HTTP client and tar/zip extraction, which depend
/// on external networking not yet integrated. Currently returns
/// `error.NotImplemented`.
pub fn install(_: Allocator, _: []const u8, _: []const u8, _: InstallOptions) !void {
    return error.NotImplemented;
}

pub const InstallOptions = struct {
    force: bool = false,
    include_pages: bool = false,
};

/// Creates a new empty style directory with a documented manifest.
///
/// Writes `styles/{name}/style.yaml` with example content showing the
/// expected manifest structure.
pub fn addStyle(a: Allocator, styles_dir: []const u8, name: []const u8) !void {
    const style_path = try fs.path.join(a, &.{ styles_dir, name });
    defer a.free(style_path);
    try fs.makeDirAbsolute(style_path);

    const manifest_path = try fs.path.join(a, &.{ style_path, "style.yaml" });
    defer a.free(manifest_path);
    {
        var f = try fs.createFileAbsolute(manifest_path, .{});
        defer f.close();
        const content = try std.fmt.allocPrint(a,
            \\# Style: {s}
            \\#
            \\# Tokens, color schemes, and asset bundles for this style.
            \\
            \\viewport:
            \\  min: 320
            \\  max: 1240
            \\
            \\typography:
            \\  base:
            \\    min: 18
            \\    max: 20
            \\  scale:
            \\    min: 1.2
            \\    max: 1.25
            \\  steps:
            \\    above: 2
            \\    below: 1
            \\
        , .{name});
        defer a.free(content);
        try f.writeAll(content);
    }
}

/// Creates a new block pattern (CSS + HTML template) in a style.
///
/// Writes `css/blocks/{block}.css`, `templates/blocks/{block}.html`, and
/// `patterns/blocks/{block}.html` under the style directory (CUBE convention).
pub fn addBlock(a: Allocator, styles_dir: []const u8, style_name: []const u8, block_name: []const u8) !void {
    const style_path = try fs.path.join(a, &.{ styles_dir, style_name });
    defer a.free(style_path);

    // css/blocks/NAME.css
    var style_dir = try fs.openDirAbsolute(style_path, .{});
    defer style_dir.close();
    try style_dir.makePath("css/blocks");
    const css_dir = try fs.path.join(a, &.{ style_path, "css", "blocks" });
    defer a.free(css_dir);
    const css_filename = try std.fmt.allocPrint(a, "{s}.css", .{block_name});
    defer a.free(css_filename);
    const css_path = try fs.path.join(a, &.{ css_dir, css_filename });
    defer a.free(css_path);
    {
        var f = try fs.createFileAbsolute(css_path, .{});
        defer f.close();
        const header = try std.fmt.allocPrint(a,
            \\/* {s}
            \\ *
            \\ * Custom properties:
            \\ *   (none yet)
            \\ *
            \\ * Exceptions:
            \\ *   (none yet)
            \\ */
            \\.{s} {{}}
            \\
        , .{ block_name, block_name });
        defer a.free(header);
        try f.writeAll(header);
    }

    // templates/blocks/NAME.html
    try style_dir.makePath("templates/blocks");
    const tmpl_dir = try fs.path.join(a, &.{ style_path, "templates", "blocks" });
    defer a.free(tmpl_dir);
    const html_filename = try std.fmt.allocPrint(a, "{s}.html", .{block_name});
    defer a.free(html_filename);
    const html_path = try fs.path.join(a, &.{ tmpl_dir, html_filename });
    defer a.free(html_path);
    {
        var f = try fs.createFileAbsolute(html_path, .{});
        defer f.close();
        const content = try std.fmt.allocPrint(a,
            \\<div class="{s}">
            \\  <t-slot />
            \\</div>
            \\
        , .{block_name});
        defer a.free(content);
        try f.writeAll(content);
    }

    // patterns/blocks/NAME.html
    try style_dir.makePath("patterns/blocks");
    const pat_dir = try fs.path.join(a, &.{ style_path, "patterns", "blocks" });
    defer a.free(pat_dir);
    const pat_filename = try std.fmt.allocPrint(a, "{s}.html", .{block_name});
    defer a.free(pat_filename);
    const pat_path = try fs.path.join(a, &.{ pat_dir, pat_filename });
    defer a.free(pat_path);
    {
        var f = try fs.createFileAbsolute(pat_path, .{});
        defer f.close();
        const content = try std.fmt.allocPrint(a,
            \\<div class="{s}">
            \\  Example content
            \\</div>
            \\
        , .{block_name});
        defer a.free(content);
        try f.writeAll(content);
    }
}

// ── Tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

test "init: creates project directories and CUBE style structure" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const proj_name = "my-site";
    try tmp.dir.makeDir(proj_name);

    const abs = try tmp.dir.realpathAlloc(testing.allocator, proj_name);
    defer testing.allocator.free(abs);

    try init(testing.allocator, abs);

    for (project_dirs) |dir_name| {
        const check_path = try fs.path.join(testing.allocator, &.{ abs, dir_name });
        defer testing.allocator.free(check_path);
        var dir = try fs.openDirAbsolute(check_path, .{});
        dir.close();
    }

    const cfg_path = try fs.path.join(testing.allocator, &.{ abs, "data", "site.yaml" });
    defer testing.allocator.free(cfg_path);
    const cfg = try fs.openFileAbsolute(cfg_path, .{});
    cfg.close();

    const layouts_path = try fs.path.join(testing.allocator, &.{ abs, "styles", "default", "templates", "layouts" });
    defer testing.allocator.free(layouts_path);
    var layouts_dir = try fs.openDirAbsolute(layouts_path, .{});
    layouts_dir.close();

    const core_manifest = try fs.path.join(testing.allocator, &.{ abs, "styles", "_core", "style.yaml" });
    defer testing.allocator.free(core_manifest);
    const cm = try fs.openFileAbsolute(core_manifest, .{});
    cm.close();
}

test "addStyle: creates manifest with correct name" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makeDir("styles");

    const abs = try tmp.dir.realpathAlloc(testing.allocator, "styles");
    defer testing.allocator.free(abs);

    try addStyle(testing.allocator, abs, "modern");

    const manifest_path = try fs.path.join(testing.allocator, &.{ abs, "modern", "style.yaml" });
    defer testing.allocator.free(manifest_path);
    const content = try fs.openFileAbsolute(manifest_path, .{});
    defer content.close();
    var buf: [512]u8 = undefined;
    const len = try content.readAll(&buf);
    const text = buf[0..len];
    try testing.expect(std.mem.indexOf(u8, text, "# Style: modern") != null);
}

test "addBlock: creates CSS, template, and pattern files (CUBE)" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("styles/default");

    const abs = try tmp.dir.realpathAlloc(testing.allocator, "styles");
    defer testing.allocator.free(abs);

    try addBlock(testing.allocator, abs, "default", "card");

    const css_path = try fs.path.join(testing.allocator, &.{ abs, "default", "css", "blocks", "card.css" });
    defer testing.allocator.free(css_path);
    const css_f = try fs.openFileAbsolute(css_path, .{});
    css_f.close();

    const html_path = try fs.path.join(testing.allocator, &.{ abs, "default", "templates", "blocks", "card.html" });
    defer testing.allocator.free(html_path);
    const html_f = try fs.openFileAbsolute(html_path, .{});
    html_f.close();

    const pat_path = try fs.path.join(testing.allocator, &.{ abs, "default", "patterns", "blocks", "card.html" });
    defer testing.allocator.free(pat_path);
    const pat_f = try fs.openFileAbsolute(pat_path, .{});
    pat_f.close();
}

test "install: returns NotImplemented" {
    try testing.expectError(error.NotImplemented, install(testing.allocator, "theme", "/tmp", .{}));
}
