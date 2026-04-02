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
const pattern_manifests = @import("pattern_manifests.zig");
pub const app = @import("app.zig");
pub const router = @import("router.zig");
pub const handler = @import("handler.zig");
pub const session = @import("session.zig");
pub const scaffold = @import("scaffold.zig");
pub const html_utils = @import("html.zig");
pub const test_runner = @import("test_runner.zig");
pub const output_paths = @import("output_paths.zig");
pub const template_loader = @import("template_loader.zig");
pub const tag_pages = @import("tag_pages.zig");
pub const collections = @import("collections.zig");
pub const diagnostics_mod = @import("diagnostics.zig");
pub const build_context_mod = @import("build_context.zig");

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

pub const StyleLoader = template_loader.StyleLoader;

const ValueMap = std.StringArrayHashMapUnmanaged(toupee.Value);

fn buildPhase_styleTokensSiteData(
    ba: Allocator,
    site_cfg: *const config.SiteConfig,
    style_cfgs: []config.StyleConfig,
    data_result: *config.DataResult,
) !toupee.Context {
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
                try std.fmt.allocPrint(ba, "styles.{s}.tokens.computed", .{style_cfg.name}),
                token_result.value,
            );
        }
    }

    const site_val = try context.combToToupee(ba, site_cfg.raw);
    try style_ctx.put("site", site_val);

    if (data_result.value == .map) {
        var data_it = data_result.value.map.iterator();
        while (data_it.next()) |entry| {
            var val = entry.value_ptr.*;
            if ((std.mem.eql(u8, entry.key_ptr.*, "colors") or
                std.mem.eql(u8, entry.key_ptr.*, "colours")) and val == .map)
            {
                val = try colours.resolveColoursData(ba, val);
            }
            try style_ctx.put(entry.key_ptr.*, val);
        }
    }

    return style_ctx;
}

fn buildPhase_assetBundles(
    ba: Allocator,
    a: Allocator,
    abs_root: []const u8,
    style_cfgs: []config.StyleConfig,
    style_ctx: *toupee.Context,
    output_dir: fs.Dir,
) !void {
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
                                    style_ctx,
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

    const asset_ctx = try bundles.buildAssetContext(ba, asset_entries.items);
    try style_ctx.put("assets", asset_ctx);
}

fn buildPhase_scanAndTaxonomies(
    ba: Allocator,
    a: Allocator,
    abs_root: []const u8,
    site_cfg: *const config.SiteConfig,
    site: *Site,
    style_ctx: *toupee.Context,
    data_result: *const config.DataResult,
) !scanner.ScanResult {
    const pages_path = try fs.path.join(a, &.{ abs_root, "pages" });
    defer a.free(pages_path);

    var registered_exts: std.ArrayListUnmanaged([]const u8) = .{};
    defer registered_exts.deinit(a);
    for (site.options.content_parsers) |p| try registered_exts.append(a, p.extension);

    var pages_dir = fs.openDirAbsolute(pages_path, .{ .iterate = true }) catch
        return error.BuildFailed;
    defer pages_dir.close();

    const default_slugify = extractDefaultSlugify(data_result);

    var scan_result = try scanner.scanWithOptions(
        ba,
        pages_dir,
        site_cfg.url,
        site.options.draft,
        site.options.debug,
        registered_exts.items,
        default_slugify,
    );

    const tax_ctx = try taxonomies.buildIndex(ba, scan_result.pages, site_cfg.taxonomies);
    try style_ctx.put("taxonomies", tax_ctx);

    if (scan_result.collections.getPtr("pages")) |pv| {
        try style_ctx.putAt("pages", pv.*);
    }

    return scan_result;
}

const buildPhase_loadTemplates = template_loader.loadTemplates;

fn buildPhase_generatedArtifacts(
    ba: Allocator,
    site_cfg: config.SiteConfig,
    style_cfgs: []config.StyleConfig,
    scan_result: *const scanner.ScanResult,
    engine: *toupee.Engine,
    style_ctx: *toupee.Context,
    template_map: *const std.StringArrayHashMapUnmanaged([]const u8),
    output_dir: fs.Dir,
    render_results: []const pages.RenderResult,
) !void {
    var search_entries = std.ArrayListUnmanaged(search.SearchEntry){};
    for (scan_result.pages, render_results) |*page, result| {
        if (page.meta.draft) continue;
        if (!page.meta.search) continue;
        const raw_plain = try search.stripHtml(ba, result.search_content);
        const trimmed = std.mem.trim(u8, raw_plain, " \t\n\r");
        const title = page.meta.title orelse "";
        const content_plain: []const u8 = if (title.len > 0 and trimmed.len > title.len and std.mem.startsWith(u8, trimmed, title)) cp: {
            const after = trimmed[title.len..];
            if (after.len > 0 and after[0] != ' ' and after[0] != '\t' and after[0] != '\n' and after[0] != '\r') {
                const rest = std.mem.trimLeft(u8, after, " \t\n\r");
                break :cp try std.fmt.allocPrint(ba, "{s}\n{s}", .{ title, rest });
            }
            break :cp try ba.dupe(u8, trimmed);
        } else try ba.dupe(u8, trimmed);
        const excerpt = pages.extractExcerptPublic(ba, page.raw_frontmatter, result.search_content) orelse content_plain;
        const tags_list = page.meta.tags;
        const date_str = page.meta.date;
        const section = sectionFromUrl(ba, page.url_path) catch null;
        try search_entries.append(ba, .{
            .url = page.absolute_url,
            .title = title,
            .content = content_plain,
            .excerpt = excerpt,
            .tags = tags_list,
            .date = date_str,
            .section = section,
        });
    }
    const entries_slice = search_entries.items;
    std.mem.sort(search.SearchEntry, entries_slice, {}, struct {
        fn lessThan(_: void, lhs: search.SearchEntry, rhs: search.SearchEntry) bool {
            return std.mem.order(u8, lhs.url, rhs.url) == .lt;
        }
    }.lessThan);
    try search.generateSearchJson(ba, entries_slice, output_dir);

    var rendered_map = std.StringArrayHashMapUnmanaged([]const u8){};
    for (scan_result.pages, render_results) |*page, result| {
        if (page.meta.draft) continue;
        try rendered_map.put(ba, page.source_path, result.search_content);
    }

    for (site_cfg.feeds) |feed_cfg| {
        try feeds.generateAtom(ba, feed_cfg, scan_result.pages, site_cfg.url, site_cfg.title, site_cfg.author, output_dir, rendered_map);
    }

    try feeds.generateSitemap(ba, scan_result.pages, output_dir);

    try tag_pages.render(
        ba,
        site_cfg,
        if (style_cfgs.len > 0) style_cfgs[0].name else "default",
        scan_result,
        engine,
        style_ctx,
        template_map,
        output_dir,
    );
}

pub const ContentParser = pages.ContentParser;
pub const ContentParserEntry = pages.ContentParserEntry;
pub const BuildContext = build_context_mod.BuildContext;
pub const Hook = build_context_mod.Hook;
pub const Hooks = build_context_mod.Hooks;

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
    extensions: []const []const u8 = &.{},
};

pub const BuildOptions = struct {
    clean: bool = false,
    pretty: bool = false,
    hooks: build_context_mod.Hooks = .{},
};

pub const BuildResult = struct {
    page_count: usize = 0,
    diagnostics: diagnostics_mod.Collector = .{},
};

pub const ValidateOptions = struct {
    external_links: bool = false,
};

/// Two-phase site struct. `init()` opens the site root (phase 1).
/// `buildAll()` runs the build pipeline (phase 2): output dirs, style/data
/// context, bundles, scan, templates, render, and generated artifacts.
///
/// **Allocators:** `allocator` is the `Site` lifetime allocator (config strings,
/// `Engine`, freed in `deinit`). `build_arena` (after `buildAll`) owns scan/pages
/// context, template source map, and most per-build strings; reset by the next
/// `buildAll()`.
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

    /// Opens the built site output directory (`zig-out/site` under the project root).
    /// Call after a successful `buildAll()`. Caller must `close()` the returned handle.
    pub fn openBuiltOutputDir(self: *Site) !fs.Dir {
        const a = self.allocator;
        const abs_root = try self.root_dir.realpathAlloc(a, ".");
        defer a.free(abs_root);
        const site_path = try output_paths.joinSiteOutputDirAbs(a, abs_root);
        defer a.free(site_path);
        return try fs.openDirAbsolute(site_path, .{});
    }

    pub fn buildAll(self: *Site, options: BuildOptions) !BuildResult {
        const a = self.allocator;
        const abs_root = try self.root_dir.realpathAlloc(a, ".");
        defer a.free(abs_root);

        if (self.build_arena) |*ba| ba.deinit();
        var build_arena = std.heap.ArenaAllocator.init(a);
        errdefer build_arena.deinit();
        const ba = build_arena.allocator();

        var diags = diagnostics_mod.Collector{};

        // --- Phase: load config ---
        var site_cfg = try config.loadSiteConfig(a, abs_root);
        errdefer site_cfg.deinit();

        const style_cfgs = try config.loadStyleConfigs(a, abs_root);
        var data_result = try config.loadDataFiles(a, abs_root);
        errdefer data_result.deinit();

        // --- Phase: ensure output tree ---
        var output_dir = try output_paths.prepareSiteOutput(a, abs_root, options.clean);
        defer output_dir.close();

        // --- Phase: style context, tokens, site + data YAML ---
        var style_ctx = try buildPhase_styleTokensSiteData(ba, &site_cfg, style_cfgs, &data_result);

        // --- Phase: CSS/JS bundles and `assets` context ---
        try buildPhase_assetBundles(ba, a, abs_root, style_cfgs, &style_ctx, output_dir);

        // --- Phase: pattern YAML manifests under styles/{name}/patterns/ ---
        try pattern_manifests.loadIntoContext(ba, abs_root, style_cfgs, &style_ctx);

        // --- Phase: Toupee engine + template map (main allocator) ---
        var engine = try toupee.Engine.init(a);
        var template_map = std.StringArrayHashMapUnmanaged([]const u8){};
        try buildPhase_loadTemplates(ba, a, abs_root, style_cfgs, &engine, &template_map);

        var transform_reg = toupee.transform.Registry{};
        try transform_reg.registerBuiltins(ba);
        defer transform_reg.deinit(ba);

        var ctx = build_context_mod.BuildContext{
            .allocator = a,
            .arena = ba,
            .abs_root = abs_root,
            .site_cfg = &site_cfg,
            .style_cfgs = style_cfgs,
            .engine = &engine,
            .template_map = &template_map,
            .style_ctx = &style_ctx,
            .content_parsers = self.options.content_parsers,
            .transform_registry = &transform_reg,
            .diagnostics = &diags,
            .hooks = options.hooks,
        };

        // --- Hook: pre_scan ---
        for (ctx.hooks.pre_scan) |hook| try hook(&ctx);

        // --- Phase: scan pages, taxonomies, `pages` context ---
        var scan_result = try buildPhase_scanAndTaxonomies(ba, a, abs_root, &site_cfg, self, &style_ctx, &data_result);
        ctx.scan_result = &scan_result;

        // --- Hook: post_scan ---
        for (ctx.hooks.post_scan) |hook| try hook(&ctx);

        // --- Hook: pre_render ---
        for (ctx.hooks.pre_render) |hook| try hook(&ctx);

        // --- Phase: render HTML pages ---
        const render_results = try pages.renderAll(
            ba,
            &scan_result,
            &engine,
            &style_ctx,
            &template_map,
            self.options.content_parsers,
            &transform_reg,
            output_dir,
        );

        // --- Hook: post_render ---
        for (ctx.hooks.post_render) |hook| try hook(&ctx);

        // --- Phase: search, feeds, sitemap, tag pages ---
        try buildPhase_generatedArtifacts(
            ba,
            site_cfg,
            style_cfgs,
            &scan_result,
            &engine,
            &style_ctx,
            &template_map,
            output_dir,
            render_results,
        );

        // --- Phase: copy static assets ---
        try copyAssets(a, self.root_dir, output_dir);

        // --- Hook: post_build ---
        for (ctx.hooks.post_build) |hook| try hook(&ctx);

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

        return .{
            .page_count = scan_result.pages.len,
            .diagnostics = diags,
        };
    }

    /// Validates the site without rendering. Checks config, manifests,
    /// frontmatter, and template resolution. The `--external` CLI flag is
    /// accepted; full external URL checking is planned for v0.2+ (v0.1 emits a
    /// warning when the flag is set).
    pub fn validate(self: *Site, options: ValidateOptions) ![]const Diagnostic {
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

        var engine = toupee.Engine.init(a) catch {
            try diags.append(a, .{ .kind = .err, .message = "Failed to initialise template engine" });
            return try diags.toOwnedSlice(a);
        };
        defer engine.deinit();

        var validate_template_map: std.StringArrayHashMapUnmanaged([]const u8) = .{};
        template_loader.loadTemplates(a, a, abs_root, style_cfgs, &engine, &validate_template_map) catch {
            try diags.append(a, .{ .kind = .warning, .message = "Could not load templates; template validation may be incomplete" });
        };

        var resolver: toupee.Resolver = .{};
        const toupee_diags = engine.validate(a, resolver.loader()) catch
            return try diags.toOwnedSlice(a);
        defer a.free(toupee_diags);

        for (toupee_diags) |d| {
            try diags.append(a, .{
                .kind = .err,
                .message = d.message,
                .template_name = d.template,
            });
        }

        if (options.external_links) {
            try diags.append(a, .{
                .kind = .warning,
                .message = "External link checking (--external) is not implemented yet; planned for v0.2+",
            });
        }

        return try diags.toOwnedSlice(a);
    }
};

/// Extracts the default `slugify` value from `data/document.yaml` in the data cascade.
fn extractDefaultSlugify(data_result: *const config.DataResult) bool {
    if (data_result.value != .map) return false;
    const doc = data_result.value.map.get("document") orelse return false;
    if (doc != .map) return false;
    const val = doc.map.get("slugify") orelse return false;
    return switch (val) {
        .boolean => |b| b,
        else => false,
    };
}

/// Derives section from url_path: /blog/post/ -> "blog", / -> null.
fn sectionFromUrl(a: Allocator, url_path: []const u8) !?[]const u8 {
    var trimmed = std.mem.trim(u8, url_path, "/");
    if (trimmed.len == 0) return null;
    if (std.mem.indexOf(u8, trimmed, "/")) |idx| {
        return try a.dupe(u8, trimmed[0..idx]);
    }
    return null;
}

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

/// Creates a pre-wired dev server `App` for local preview.
///
/// **Build vs HTTP:** This does not take `*Site`. Pass the **open site output directory**
/// (`zig-out/site` under the project root), e.g. from `Site.openBuiltOutputDir()` after
/// `buildAll()`. The caller keeps ownership of `site_output_dir` and must `close()` it
/// when finished (typically after the server shuts down).
///
/// The returned App will serve static files from that directory once the HTTP stack is
/// wired (v0.3+). Custom routes can be added on the returned `App`.
///
/// File watching and SSE live reload are future additions.
/// Call `app.listen(port)` to start serving (currently stubbed).
pub fn devServer(a: Allocator, site_output_dir: fs.Dir) !app.App {
    _ = site_output_dir;
    var application = app.App.init(a);

    try application.get("/", struct {
        fn handle(ctx: *handler.Context) anyerror!void {
            try ctx.respond("Wig dev server running.", "text/plain");
        }
    }.handle);

    return application;
}

test {
    _ = output_paths;
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
