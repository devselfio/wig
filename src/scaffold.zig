const std = @import("std");

const Allocator = std.mem.Allocator;
const fs = std.fs;

const project_dirs = [_][]const u8{ "data", "pages", "styles", "assets" };

/// Scaffolds a new Wig project at the given path.
///
/// Creates the standard directory structure: data/, pages/, styles/, assets/.
/// Also writes a minimal site config and a starter index page.
pub fn init(a: Allocator, target_path: []const u8) !void {
    const abs = try fs.realpathAlloc(a, target_path);
    defer a.free(abs);

    for (project_dirs) |dir_name| {
        const dir_path = try fs.path.join(a, &.{ abs, dir_name });
        defer a.free(dir_path);
        try fs.makeDirAbsolute(dir_path);
    }

    const config_path = try fs.path.join(a, &.{ abs, "data", "site.yaml" });
    defer a.free(config_path);
    {
        var f = try fs.createFileAbsolute(config_path, .{});
        defer f.close();
        try f.writeAll(
            \\url: https://example.com
            \\title: My Wig Site
            \\
        );
    }

    const index_path = try fs.path.join(a, &.{ abs, "pages", "index.dj" });
    defer a.free(index_path);
    {
        var f = try fs.createFileAbsolute(index_path, .{});
        defer f.close();
        try f.writeAll(
            \\---
            \\title: Home
            \\---
            \\Welcome to your new Wig site.
            \\
        );
    }
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
            \\# Tokens, colour schemes, and asset bundles for this style.
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
/// Writes `styles/{style}/{block}.css` and `styles/{style}/{block}.html`
/// with starter content.
pub fn addBlock(a: Allocator, styles_dir: []const u8, style_name: []const u8, block_name: []const u8) !void {
    const style_path = try fs.path.join(a, &.{ styles_dir, style_name });
    defer a.free(style_path);

    const css_filename = try std.fmt.allocPrint(a, "{s}.css", .{block_name});
    defer a.free(css_filename);
    const css_path = try fs.path.join(a, &.{ style_path, css_filename });
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

    const html_filename = try std.fmt.allocPrint(a, "{s}.html", .{block_name});
    defer a.free(html_filename);
    const html_path = try fs.path.join(a, &.{ style_path, html_filename });
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
}

// ── Tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

test "init: creates project directories" {
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

test "addBlock: creates CSS and HTML files" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("styles/default");

    const abs = try tmp.dir.realpathAlloc(testing.allocator, "styles");
    defer testing.allocator.free(abs);

    try addBlock(testing.allocator, abs, "default", "card");

    const css_path = try fs.path.join(testing.allocator, &.{ abs, "default", "card.css" });
    defer testing.allocator.free(css_path);
    const css_f = try fs.openFileAbsolute(css_path, .{});
    css_f.close();

    const html_path = try fs.path.join(testing.allocator, &.{ abs, "default", "card.html" });
    defer testing.allocator.free(html_path);
    const html_f = try fs.openFileAbsolute(html_path, .{});
    html_f.close();
}

test "install: returns NotImplemented" {
    try testing.expectError(error.NotImplemented, install(testing.allocator, "theme", "/tmp", .{}));
}
