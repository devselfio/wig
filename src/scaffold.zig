const std = @import("std");
const skel = @import("skel.zig");

const Allocator = std.mem.Allocator;

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

/// Scaffolds a new Wig project by extracting the embedded default skeleton (`src/skel/<term>.tar`).
pub fn init(a: Allocator, io: std.Io, target_path: []const u8) !void {
    try skel.unpack(a, io, skel.default_init_term, target_path);
}

/// Installs a style from wig-stand or a git URL.
///
/// **Deferred:** Requires HTTP client and tar/zip extraction, which depend
/// on external networking not yet integrated. Currently returns
/// `error.NotImplemented`.
pub fn install(_: Allocator, _: std.Io, _: []const u8, _: []const u8, _: InstallOptions) !void {
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
pub fn addStyle(a: Allocator, io: std.Io, styles_dir: []const u8, name: []const u8) !void {
    const style_path = try std.fs.path.join(a, &.{ styles_dir, name });
    defer a.free(style_path);
    try std.Io.Dir.createDirAbsolute(io, style_path, .default_dir);

    const manifest_path = try std.fs.path.join(a, &.{ style_path, "style.yaml" });
    defer a.free(manifest_path);
    {
        var f = try std.Io.Dir.createFileAbsolute(io, manifest_path, .{});
        defer f.close(io);
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
        try f.writeStreamingAll(io, content);
    }
}

/// Creates a new block pattern (CSS + HTML template) in a style.
///
/// Writes `css/blocks/{block}.css`, `templates/blocks/{block}.html`, and
/// `patterns/blocks/{block}.html` under the style directory (CUBE convention).
pub fn addBlock(a: Allocator, io: std.Io, styles_dir: []const u8, style_name: []const u8, block_name: []const u8) !void {
    const style_path = try std.fs.path.join(a, &.{ styles_dir, style_name });
    defer a.free(style_path);

    // css/blocks/NAME.css
    var style_dir = try std.Io.Dir.openDirAbsolute(io, style_path, .{});
    defer style_dir.close(io);
    try std.Io.Dir.createDirPath(style_dir, io, "css/blocks");
    const css_dir = try std.fs.path.join(a, &.{ style_path, "css", "blocks" });
    defer a.free(css_dir);
    const css_filename = try std.fmt.allocPrint(a, "{s}.css", .{block_name});
    defer a.free(css_filename);
    const css_path = try std.fs.path.join(a, &.{ css_dir, css_filename });
    defer a.free(css_path);
    {
        var f = try std.Io.Dir.createFileAbsolute(io, css_path, .{});
        defer f.close(io);
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
        try f.writeStreamingAll(io, header);
    }

    // templates/blocks/NAME.html
    try std.Io.Dir.createDirPath(style_dir, io, "templates/blocks");
    const tmpl_dir = try std.fs.path.join(a, &.{ style_path, "templates", "blocks" });
    defer a.free(tmpl_dir);
    const html_filename = try std.fmt.allocPrint(a, "{s}.html", .{block_name});
    defer a.free(html_filename);
    const html_path = try std.fs.path.join(a, &.{ tmpl_dir, html_filename });
    defer a.free(html_path);
    {
        var f = try std.Io.Dir.createFileAbsolute(io, html_path, .{});
        defer f.close(io);
        const content = try std.fmt.allocPrint(a,
            \\<div class="{s}">
            \\  <t-slot />
            \\</div>
            \\
        , .{block_name});
        defer a.free(content);
        try f.writeStreamingAll(io, content);
    }

    // patterns/blocks/NAME.html
    try std.Io.Dir.createDirPath(style_dir, io, "patterns/blocks");
    const pat_dir = try std.fs.path.join(a, &.{ style_path, "patterns", "blocks" });
    defer a.free(pat_dir);
    const pat_filename = try std.fmt.allocPrint(a, "{s}.html", .{block_name});
    defer a.free(pat_filename);
    const pat_path = try std.fs.path.join(a, &.{ pat_dir, pat_filename });
    defer a.free(pat_path);
    {
        var f = try std.Io.Dir.createFileAbsolute(io, pat_path, .{});
        defer f.close(io);
        const content = try std.fmt.allocPrint(a,
            \\<div class="{s}">
            \\  Example content
            \\</div>
            \\
        , .{block_name});
        defer a.free(content);
        try f.writeStreamingAll(io, content);
    }
}

// ── Tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

test "init: creates project directories and CUBE style structure" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;

    const proj_name = "my-site";
    try std.Io.Dir.createDir(tmp.dir, io, proj_name, .{});

    const abs = try std.Io.Dir.realPathFileAlloc(tmp.dir, io, proj_name, testing.allocator);
    defer testing.allocator.free(abs);

    try init(testing.allocator, io, abs);

    for (project_dirs) |dir_name| {
        const check_path = try std.fs.path.join(testing.allocator, &.{ abs, dir_name });
        defer testing.allocator.free(check_path);
        var dir = try std.Io.Dir.openDirAbsolute(io, check_path, .{});
        dir.close(io);
    }

    const cfg_path = try std.fs.path.join(testing.allocator, &.{ abs, "data", "site.yaml" });
    defer testing.allocator.free(cfg_path);
    const cfg = try std.Io.Dir.openFileAbsolute(io, cfg_path, .{});
    cfg.close(io);

    const layouts_path = try std.fs.path.join(testing.allocator, &.{ abs, "styles", "default", "templates", "layouts" });
    defer testing.allocator.free(layouts_path);
    var layouts_dir = try std.Io.Dir.openDirAbsolute(io, layouts_path, .{});
    layouts_dir.close(io);

    const core_manifest = try std.fs.path.join(testing.allocator, &.{ abs, "styles", "_core", "style.yaml" });
    defer testing.allocator.free(core_manifest);
    const cm = try std.Io.Dir.openFileAbsolute(io, core_manifest, .{});
    cm.close(io);
}

test "addStyle: creates manifest with correct name" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;

    try std.Io.Dir.createDir(tmp.dir, io, "styles", .{});

    const abs = try std.Io.Dir.realPathFileAlloc(tmp.dir, io, "styles", testing.allocator);
    defer testing.allocator.free(abs);

    try addStyle(testing.allocator, io, abs, "modern");

    const manifest_path = try std.fs.path.join(testing.allocator, &.{ abs, "modern", "style.yaml" });
    defer testing.allocator.free(manifest_path);
    const text = try std.Io.Dir.readFileAlloc(std.Io.Dir.cwd(), io, manifest_path, testing.allocator, .limited(512));
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "# Style: modern") != null);
}

test "addBlock: creates CSS, template, and pattern files (CUBE)" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;

    try std.Io.Dir.createDirPath(tmp.dir, io, "styles/default");

    const abs = try std.Io.Dir.realPathFileAlloc(tmp.dir, io, "styles", testing.allocator);
    defer testing.allocator.free(abs);

    try addBlock(testing.allocator, io, abs, "default", "card");

    const css_path = try std.fs.path.join(testing.allocator, &.{ abs, "default", "css", "blocks", "card.css" });
    defer testing.allocator.free(css_path);
    const css_f = try std.Io.Dir.openFileAbsolute(io, css_path, .{});
    css_f.close(io);

    const html_path = try std.fs.path.join(testing.allocator, &.{ abs, "default", "templates", "blocks", "card.html" });
    defer testing.allocator.free(html_path);
    const html_f = try std.Io.Dir.openFileAbsolute(io, html_path, .{});
    html_f.close(io);

    const pat_path = try std.fs.path.join(testing.allocator, &.{ abs, "default", "patterns", "blocks", "card.html" });
    defer testing.allocator.free(pat_path);
    const pat_f = try std.Io.Dir.openFileAbsolute(io, pat_path, .{});
    pat_f.close(io);
}

test "install: returns NotImplemented" {
    try testing.expectError(error.NotImplemented, install(testing.allocator, "theme", "/tmp", .{}));
}
