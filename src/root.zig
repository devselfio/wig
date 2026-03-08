const std = @import("std");
pub const toupee = @import("toupee");
pub const comb = @import("comb");
pub const zjot = @import("zjot");

const Allocator = std.mem.Allocator;
const fs = std.fs;

pub const config = @import("config.zig");
pub const context = @import("context.zig");
pub const tokens = @import("tokens.zig");
pub const colours = @import("colours.zig");
pub const frontmatter = @import("frontmatter.zig");
pub const bundles = @import("bundles.zig");
pub const scanner = @import("scanner.zig");
pub const taxonomies = @import("taxonomies.zig");
pub const pages = @import("pages.zig");
pub const toc_mod = @import("toc.zig");
pub const search = @import("search.zig");
pub const feeds = @import("feeds.zig");
pub const patterns = @import("patterns.zig");
pub const app = @import("app.zig");
pub const router = @import("router.zig");
pub const handler = @import("handler.zig");
pub const session = @import("session.zig");
pub const scaffold = @import("scaffold.zig");
pub const html_utils = @import("html.zig");
pub const test_runner = @import("test_runner.zig");

pub const Diagnostic = struct {
    kind: Kind = .err,
    message: []const u8,
    template_name: ?[]const u8 = null,

    pub const Kind = enum { err, warning };
};

pub const WigError = error{
    NotImplemented,
    InvalidConfig,
    MissingConfig,
    MissingUrl,
    DualConfig,
    MissingFrontmatter,
    PathCollision,
    UnrecognisedExtension,
    MissingTemplate,
    BuildFailed,
    OutputDirNotClean,
    TemplateConflict,
};

/// Resolves template names relative to a style during rendering.
/// Short names (e.g. `base.html`) resolve within the current style's
/// `layouts/` then `includes/` directories. Names prefixed with `_core/`
/// resolve from the shared `_core` directories. Full paths are tried as-is.
pub const StyleLoader = struct {
    templates: *const std.StringArrayHashMapUnmanaged([]const u8),
    style_name: []const u8,

    pub fn loader(self: *const StyleLoader) toupee.Loader {
        return .{
            .ptr = @ptrCast(self),
            .getSourceFn = getSource,
        };
    }

    fn getSource(ptr: *const anyopaque, a: Allocator, name: []const u8) Allocator.Error!?[]const u8 {
        const self: *const StyleLoader = @ptrCast(@alignCast(ptr));

        if (std.mem.startsWith(u8, name, "_core/")) {
            const short = name["_core/".len..];
            const paths = [_][]const u8{ "_core/layouts/", "_core/includes/" };
            for (paths) |prefix| {
                const full = try std.fmt.allocPrint(a, "{s}{s}", .{ prefix, short });
                defer a.free(full);
                if (self.templates.get(full)) |src| return try a.dupe(u8, src);
            }
            return null;
        }

        if (std.mem.indexOf(u8, name, "/") != null) {
            if (self.templates.get(name)) |src| return try a.dupe(u8, src);
            return null;
        }

        const prefixes = [_][]const u8{ "/layouts/", "/includes/" };
        for (prefixes) |suffix| {
            const full = try std.fmt.allocPrint(a, "{s}{s}{s}", .{ self.style_name, suffix, name });
            defer a.free(full);
            if (self.templates.get(full)) |src| return try a.dupe(u8, src);
        }

        return null;
    }
};

pub const ContentParser = pages.ContentParser;
pub const ContentParserEntry = pages.ContentParserEntry;

pub fn zjotParser(a: Allocator, source: []const u8) anyerror![]const u8 {
    return zjot.toHtml(a, source);
}

pub const SiteOptions = struct {
    root: []const u8 = ".",
    draft: bool = false,
    debug: bool = false,
    content_parsers: []const ContentParserEntry = &.{
        .{ .extension = ".dj", .parse = zjotParser },
    },
};

pub const BuildOptions = struct {
    clean: bool = false,
};

pub const ValidateOptions = struct {
    external_links: bool = false,
};

/// Two-phase site struct. `init()` loads config (phase 1).
/// `buildAll()` computes tokens, builds CSS, renders pages (phase 2).
/// After `buildAll()`, the engine and build state are available for
/// custom route handlers in the dev server.
pub const Site = struct {
    allocator: Allocator,
    options: SiteOptions,
    root_dir: fs.Dir,
    site_config: ?config.SiteConfig = null,
    style_configs: ?[]config.StyleConfig = null,
    data_result: ?config.DataResult = null,
    engine: ?toupee.Engine = null,
    build_arena: ?std.heap.ArenaAllocator = null,

    pub fn init(a: Allocator, options: SiteOptions) !Site {
        const root_dir = fs.cwd().openDir(options.root, .{ .iterate = true }) catch
            return error.MissingConfig;

        return .{
            .allocator = a,
            .options = options,
            .root_dir = root_dir,
        };
    }

    pub fn deinit(self: *Site) void {
        if (self.engine) |*e| e.deinit();
        if (self.build_arena) |*ba| ba.deinit();
        if (self.data_result) |*d| d.deinit();
        if (self.style_configs) |cfgs| {
            for (cfgs) |*c| @constCast(c).deinit();
            self.allocator.free(cfgs);
        }
        if (self.site_config) |*c| c.deinit();
        self.root_dir.close();
    }

    pub fn buildAll(self: *Site, options: BuildOptions) !void {
        const a = self.allocator;
        const abs_root = try self.root_dir.realpathAlloc(a, ".");
        defer a.free(abs_root);

        if (self.build_arena) |*ba| ba.deinit();
        var build_arena = std.heap.ArenaAllocator.init(a);
        errdefer build_arena.deinit();
        const ba = build_arena.allocator();

        // Load config
        var site_cfg = try config.loadSiteConfig(a, abs_root);
        errdefer site_cfg.deinit();

        const style_cfgs = try config.loadStyleConfigs(a, abs_root);
        var data_result = try config.loadDataFiles(a, abs_root);
        errdefer data_result.deinit();

        // Output directory
        const output_path = try fs.path.join(a, &.{ abs_root, "zig-out", "site" });
        defer a.free(output_path);

        if (options.clean) {
            fs.deleteTreeAbsolute(output_path) catch {};
        }

        fs.makeDirAbsolute(output_path) catch {};
        const parent_path = try fs.path.join(a, &.{ abs_root, "zig-out" });
        defer a.free(parent_path);
        fs.makeDirAbsolute(parent_path) catch {};
        fs.makeDirAbsolute(output_path) catch {};

        var output_dir = fs.openDirAbsolute(output_path, .{}) catch
            return error.BuildFailed;
        defer output_dir.close();

        // Compute tokens + colours per style
        var style_ctx = toupee.Context.init(ba);
        for (style_cfgs) |style_cfg| {
            const style_val = try context.combToToupee(ba, style_cfg.raw);
            try style_ctx.putAt(
                try std.fmt.allocPrint(ba, "styles.{s}", .{style_cfg.name}),
                style_val,
            );

            if (style_cfg.raw.get("tokens")) |tok_val| {
                const params = try tokens.extractParams(tok_val, ba);
                var token_result = try tokens.compute(ba, params);
                defer token_result.deinit();
                try style_ctx.putAt(
                    try std.fmt.allocPrint(ba, "styles.{s}.tokens", .{style_cfg.name}),
                    token_result.value,
                );
            }
        }

        // Put site data into context
        const site_val = try context.combToToupee(ba, site_cfg.raw);
        try style_ctx.put("site", site_val);

        // Put data files into context
        if (data_result.value == .map) {
            var data_it = data_result.value.map.iterator();
            while (data_it.next()) |entry| {
                try style_ctx.put(entry.key_ptr.*, entry.value_ptr.*);
            }
        }

        // CSS/JS bundles per style
        var asset_entries: std.ArrayListUnmanaged(bundles.AssetEntry) = .{};

        const styles_path = try fs.path.join(a, &.{ abs_root, "styles" });
        defer a.free(styles_path);

        if (fs.openDirAbsolute(styles_path, .{ .iterate = true })) |sd| {
            var styles_dir = sd;
            defer styles_dir.close();

            for (style_cfgs) |style_cfg| {
                const assets_val_opt = style_cfg.raw.get("bundles") orelse style_cfg.raw.get("assets");
                if (assets_val_opt) |assets_val| {
                    if (assets_val == .object) {
                        for (assets_val.object) |type_entry| {
                            const bundle_type = switch (type_entry.key) {
                                .string => |s| s,
                                else => continue,
                            };
                            if (type_entry.value == .object) {
                                for (type_entry.value.object) |bundle_entry| {
                                    const bundle_name = switch (bundle_entry.key) {
                                        .string => |s| s,
                                        else => continue,
                                    };
                                    const file_list = switch (bundle_entry.value) {
                                        .array => |arr| arr,
                                        else => continue,
                                    };

                                    var file_patterns: std.ArrayListUnmanaged([]const u8) = .{};
                                    defer file_patterns.deinit(ba);
                                    for (file_list) |item| {
                                        if (item == .string) try file_patterns.append(ba, item.string);
                                    }

                                    const result = try bundles.processBundle(
                                        ba,
                                        style_cfg.name,
                                        bundle_type,
                                        bundle_name,
                                        file_patterns.items,
                                        styles_dir,
                                        &style_ctx,
                                        output_dir,
                                    );

                                    try asset_entries.append(ba, .{
                                        .style_name = style_cfg.name,
                                        .bundle_type = bundle_type,
                                        .bundle_name = bundle_name,
                                        .result = result,
                                    });
                                }
                            }
                        }
                    }
                }
            }
        } else |_| {}

        // Build asset context
        const asset_ctx = try bundles.buildAssetContext(ba, asset_entries.items);
        try style_ctx.put("assets", asset_ctx);

        // Scan pages
        const pages_path = try fs.path.join(a, &.{ abs_root, "pages" });
        defer a.free(pages_path);

        var registered_exts: std.ArrayListUnmanaged([]const u8) = .{};
        defer registered_exts.deinit(a);
        for (self.options.content_parsers) |p| try registered_exts.append(a, p.extension);

        var pages_dir = fs.openDirAbsolute(pages_path, .{ .iterate = true }) catch
            return error.BuildFailed;
        defer pages_dir.close();

        var scan_result = try scanner.scan(
            ba,
            pages_dir,
            site_cfg.url,
            self.options.draft,
            self.options.debug,
            registered_exts.items,
        );
        _ = &scan_result;

        // Build taxonomies
        const tax_ctx = try taxonomies.buildIndex(ba, scan_result.pages, site_cfg.taxonomies);
        try style_ctx.put("taxonomies", tax_ctx);

        // Put collections into context using putAt for dot-path resolution.
        // Skip the root "pages" collection when nested collections exist,
        // because putAt("pages", list) followed by putAt("pages.posts", list)
        // would conflict (pages can't be both a list and a map).
        const has_nested = blk: {
            var coll_check = scan_result.collections.iterator();
            while (coll_check.next()) |entry| {
                if (std.mem.indexOf(u8, entry.key_ptr.*, ".") != null) break :blk true;
            }
            break :blk false;
        };

        var coll_it = scan_result.collections.iterator();
        while (coll_it.next()) |entry| {
            if (has_nested and std.mem.eql(u8, entry.key_ptr.*, "pages")) continue;
            try style_ctx.putAt(entry.key_ptr.*, entry.value_ptr.*);
        }

        // Load templates per-style into engine and a shared template map.
        // Engine manages its own memory (dupes names/sources, creates per-template
        // arenas), so it uses the main allocator to avoid lifetime coupling with
        // the build arena.
        var engine = try toupee.Engine.init(a);
        var template_map = std.StringArrayHashMapUnmanaged([]const u8){};

        if (fs.openDirAbsolute(styles_path, .{ .iterate = true })) |sd2| {
            var styles_dir2 = sd2;
            defer styles_dir2.close();

            // Load _core templates (shared across all styles)
            for ([_][]const u8{ "layouts", "includes" }) |subdir| {
                const core_subdir = try std.fmt.allocPrint(ba, "_core/{s}", .{subdir});
                if (styles_dir2.openDir(core_subdir, .{ .iterate = true })) |cd| {
                    var core_dir = cd;
                    defer core_dir.close();
                    var cit = core_dir.iterate();
                    while (try cit.next()) |entry| {
                        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".html")) continue;
                        const tmpl_name = try std.fmt.allocPrint(ba, "_core/{s}/{s}", .{ subdir, entry.name });
                        const content = try core_dir.readFileAlloc(ba, entry.name, 4 * 1024 * 1024);
                        try engine.addTemplate(tmpl_name, content);
                        try template_map.put(ba, tmpl_name, content);
                    }
                } else |_| {}
            }

            // Load per-style templates
            for (style_cfgs) |style_cfg| {
                for ([_][]const u8{ "layouts", "includes" }) |subdir| {
                    const style_subdir = try std.fmt.allocPrint(ba, "{s}/{s}", .{ style_cfg.name, subdir });
                    if (styles_dir2.openDir(style_subdir, .{ .iterate = true })) |sd3| {
                        var tmpl_dir = sd3;
                        defer tmpl_dir.close();
                        var tit = tmpl_dir.iterate();
                        while (try tit.next()) |entry| {
                            if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".html")) continue;
                            const tmpl_name = try std.fmt.allocPrint(ba, "{s}/{s}/{s}", .{ style_cfg.name, subdir, entry.name });
                            const content = try tmpl_dir.readFileAlloc(ba, entry.name, 4 * 1024 * 1024);
                            try engine.addTemplate(tmpl_name, content);
                            try template_map.put(ba, tmpl_name, content);
                        }
                    } else |_| {}
                }

                // Backward compatibility: load from html/ subdirectory
                const html_subdir = try std.fmt.allocPrint(ba, "{s}/html", .{style_cfg.name});
                if (styles_dir2.openDir(html_subdir, .{ .iterate = true })) |sd3| {
                    var html_dir = sd3;
                    defer html_dir.close();
                    var hit = html_dir.iterate();
                    while (try hit.next()) |entry| {
                        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".html")) continue;
                        const tmpl_name = try std.fmt.allocPrint(ba, "{s}/html/{s}", .{ style_cfg.name, entry.name });
                        const content = try html_dir.readFileAlloc(ba, entry.name, 4 * 1024 * 1024);
                        try engine.addTemplate(tmpl_name, content);
                        try template_map.put(ba, tmpl_name, content);
                    }
                } else |_| {}
            }
        } else |_| {}

        // Render pages with per-style template resolution
        _ = try pages.renderAll(
            ba,
            scan_result.pages,
            &engine,
            &style_ctx,
            &template_map,
            self.options.content_parsers,
            output_dir,
        );

        // Generate feeds
        for (site_cfg.feeds) |feed_cfg| {
            try feeds.generateAtom(ba, feed_cfg, scan_result.pages, site_cfg.url, site_cfg.title, output_dir);
        }

        // Generate sitemap
        try feeds.generateSitemap(ba, scan_result.pages, output_dir);

        // Copy assets
        try copyAssets(a, self.root_dir, output_dir);

        // Store build state
        if (self.site_config) |*c| c.deinit();
        self.site_config = site_cfg;
        if (self.data_result) |*d| d.deinit();
        self.data_result = data_result;
        if (self.style_configs) |cfgs| {
            for (cfgs) |*c| @constCast(c).deinit();
            self.allocator.free(cfgs);
        }
        self.style_configs = style_cfgs;
        self.engine = engine;
        self.build_arena = build_arena;
    }

    /// Validates the site without rendering. Checks config, manifests,
    /// frontmatter, and template resolution. Optionally checks external links.
    pub fn validate(self: *Site, options: ValidateOptions) ![]const Diagnostic {
        _ = options;
        const a = self.allocator;

        var diags: std.ArrayListUnmanaged(Diagnostic) = .{};

        const abs_root = self.root_dir.realpathAlloc(a, ".") catch
            return error.MissingConfig;
        defer a.free(abs_root);

        var site_cfg = config.loadSiteConfig(a, abs_root) catch |err| {
            try diags.append(a, .{ .kind = .err, .message = switch (err) {
                error.MissingConfig => "Missing site config: create data/site.yaml",
                error.DualConfig => "Found both site.yaml and site.json -- use exactly one",
                error.MissingUrl => "Site config missing required 'url' field",
                else => "Invalid site config",
            } });
            return try diags.toOwnedSlice(a);
        };
        defer site_cfg.deinit();

        const style_cfgs = config.loadStyleConfigs(a, abs_root) catch {
            try diags.append(a, .{ .kind = .warning, .message = "Could not scan styles directory" });
            return try diags.toOwnedSlice(a);
        };
        defer {
            for (style_cfgs) |*c| @constCast(c).deinit();
            a.free(style_cfgs);
        }

        if (style_cfgs.len == 0) {
            try diags.append(a, .{ .kind = .warning, .message = "No styles found (no style.yaml in styles/)" });
        }

        const styles_path = try fs.path.join(a, &.{ abs_root, "styles" });
        defer a.free(styles_path);

        var engine = toupee.Engine.init(a) catch {
            try diags.append(a, .{ .kind = .err, .message = "Failed to initialise template engine" });
            return try diags.toOwnedSlice(a);
        };
        defer engine.deinit();

        // Load templates for validation (same logic as buildAll)
        if (fs.openDirAbsolute(styles_path, .{ .iterate = true })) |sd| {
            var sdir = sd;
            defer sdir.close();
            for ([_][]const u8{ "layouts", "includes", "html" }) |subdir| {
                const core_subdir_str = std.fmt.allocPrint(a, "_core/{s}", .{subdir}) catch continue;
                defer a.free(core_subdir_str);
                if (sdir.openDir(core_subdir_str, .{ .iterate = true })) |cd| {
                    var core_dir = cd;
                    defer core_dir.close();
                    var cit = core_dir.iterate();
                    while (cit.next() catch null) |entry| {
                        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".html")) continue;
                        const tmpl_name = std.fmt.allocPrint(a, "_core/{s}/{s}", .{ subdir, entry.name }) catch continue;
                        defer a.free(tmpl_name);
                        const content = core_dir.readFileAlloc(a, entry.name, 4 * 1024 * 1024) catch continue;
                        defer a.free(content);
                        engine.addTemplate(tmpl_name, content) catch {};
                    }
                } else |_| {}
            }
            for (style_cfgs) |style_cfg| {
                for ([_][]const u8{ "layouts", "includes", "html" }) |subdir| {
                    const ssd = std.fmt.allocPrint(a, "{s}/{s}", .{ style_cfg.name, subdir }) catch continue;
                    defer a.free(ssd);
                    if (sdir.openDir(ssd, .{ .iterate = true })) |sd2| {
                        var tmpl_dir = sd2;
                        defer tmpl_dir.close();
                        var tit = tmpl_dir.iterate();
                        while (tit.next() catch null) |entry| {
                            if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".html")) continue;
                            const tmpl_name = std.fmt.allocPrint(a, "{s}/{s}/{s}", .{ style_cfg.name, subdir, entry.name }) catch continue;
                            defer a.free(tmpl_name);
                            const content = tmpl_dir.readFileAlloc(a, entry.name, 4 * 1024 * 1024) catch continue;
                            defer a.free(content);
                            engine.addTemplate(tmpl_name, content) catch {};
                        }
                    } else |_| {}
                }
            }
        } else |_| {}

        var resolver: toupee.Resolver = .{};
        const toupee_diags = engine.validate(a, resolver.loader()) catch
            return try diags.toOwnedSlice(a);
        defer a.free(toupee_diags);

        for (toupee_diags) |d| {
            try diags.append(a, .{
                .kind = .err,
                .message = d.message,
                .template_name = d.template_name,
            });
        }

        return try diags.toOwnedSlice(a);
    }
};

/// Recursively copies `assets/` to the output directory.
fn copyAssets(a: Allocator, root_dir: fs.Dir, output_dir: fs.Dir) !void {
    var assets_dir = root_dir.openDir("assets", .{ .iterate = true }) catch return;
    defer assets_dir.close();

    output_dir.makePath("assets") catch {};
    var out_assets = try output_dir.openDir("assets", .{});
    defer out_assets.close();

    try copyDirRecursive(a, assets_dir, out_assets);
}

fn copyDirRecursive(a: Allocator, src: fs.Dir, dst: fs.Dir) !void {
    var it = src.iterate();
    while (try it.next()) |entry| {
        switch (entry.kind) {
            .file => {
                const content = try src.readFileAlloc(a, entry.name, 64 * 1024 * 1024);
                defer a.free(content);
                var f = try dst.createFile(entry.name, .{});
                defer f.close();
                try f.writeAll(content);
            },
            .directory => {
                dst.makePath(entry.name) catch {};
                var sub_src = try src.openDir(entry.name, .{ .iterate = true });
                defer sub_src.close();
                var sub_dst = try dst.openDir(entry.name, .{});
                defer sub_dst.close();
                try copyDirRecursive(a, sub_src, sub_dst);
            },
            else => {},
        }
    }
}

/// Creates a pre-wired dev server App backed by the given Site.
/// The caller must run `site.buildAll()` before calling this.
///
/// The returned App serves:
///   - Static files from `zig-out/site/` (the build output)
///   - User-added custom routes
///
/// File watching and SSE live reload are future additions.
/// Call `app.listen(port)` to start serving (currently stubbed).
pub fn devServer(a: Allocator, site: *Site) !app.App {
    _ = site;
    var application = app.App.init(a);

    try application.get("/", struct {
        fn handle(ctx: *handler.Context) anyerror!void {
            try ctx.respond("Wig dev server running.", "text/plain");
        }
    }.handle);

    return application;
}

test {
    _ = config;
    _ = context;
    _ = tokens;
    _ = colours;
    _ = frontmatter;
    _ = bundles;
    _ = scanner;
    _ = taxonomies;
    _ = pages;
    _ = toc_mod;
    _ = search;
    _ = feeds;
    _ = patterns;
    _ = app;
    _ = router;
    _ = handler;
    _ = session;
    _ = scaffold;
    _ = html_utils;
    _ = test_runner;
}

test "E2E: data pipeline loads config, computes tokens, renders template" {
    const testing_alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(testing_alloc);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("data");
    try tmp.dir.makePath("styles/default");

    {
        var dir = try tmp.dir.openDir("data", .{});
        defer dir.close();
        var f = try dir.createFile("site.yaml", .{});
        try f.writeAll("url: https://example.com\ntitle: E2E Test");
        f.close();
    }
    {
        var dir = try tmp.dir.openDir("styles/default", .{});
        defer dir.close();
        var f = try dir.createFile("style.yaml", .{});
        try f.writeAll(
            \\viewport:
            \\  min: 320
            \\  max: 1240
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
        );
        f.close();
    }

    const abs = try tmp.dir.realpathAlloc(a, ".");

    var site_cfg = try config.loadSiteConfig(a, abs);
    defer site_cfg.deinit();

    const style_cfgs = try config.loadStyleConfigs(a, abs);
    try std.testing.expect(style_cfgs.len == 1);

    const params = try tokens.extractParams(style_cfgs[0].raw, a);
    var token_result = try tokens.compute(a, params);
    defer token_result.deinit();

    var ctx = toupee.Context.init(a);
    const site_val = try context.combToToupee(a, site_cfg.raw);
    try ctx.put("site", site_val);
    try ctx.put("tokens", token_result.value);

    var resolver: toupee.Resolver = .{};
    const html = try toupee.render(
        a,
        "<h1><t-var name=\"site.title\">default</t-var></h1>",
        &ctx,
        resolver.loader(),
        .{},
    );
    try std.testing.expectEqualStrings("<h1>E2E Test</h1>", html);

    const html2 = try toupee.render(
        a,
        "<t-if var=\"tokens.typography\">has-tokens</t-if>",
        &ctx,
        resolver.loader(),
        .{},
    );
    try std.testing.expectEqualStrings("has-tokens", html2);
}

test "copyAssets: copies files recursively" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("assets/images");
    {
        var assets = try tmp.dir.openDir("assets", .{});
        defer assets.close();
        var f = try assets.createFile("style.css", .{});
        try f.writeAll("body{}");
        f.close();

        var images = try assets.openDir("images", .{});
        defer images.close();
        var img = try images.createFile("logo.png", .{});
        try img.writeAll("PNG");
        img.close();
    }

    try tmp.dir.makePath("output");
    var output = try tmp.dir.openDir("output", .{});
    defer output.close();

    try copyAssets(a, tmp.dir, output);

    const css = try output.readFileAlloc(a, "assets/style.css", 4096);
    defer a.free(css);
    try std.testing.expectEqualStrings("body{}", css);

    const img = try output.readFileAlloc(a, "assets/images/logo.png", 4096);
    defer a.free(img);
    try std.testing.expectEqualStrings("PNG", img);
}
