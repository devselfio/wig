const std = @import("std");
pub const toupee = @import("toupee");
pub const comb = @import("comb");
pub const zjot = @import("zjot");

const Allocator = std.mem.Allocator;

pub const config = @import("config.zig");
pub const context = @import("context.zig");
pub const tokens = @import("tokens.zig");
pub const colors = @import("colors.zig");
pub const frontmatter = @import("frontmatter.zig");
pub const scanner = @import("scanner.zig");
pub const taxonomies = @import("taxonomies.zig");
pub const pages = @import("pages.zig");
pub const toc_mod = @import("toc.zig");
pub const search = @import("search.zig");
pub const feeds = @import("feeds.zig");
pub const pattern_parser = @import("pattern_parser.zig");
pub const pattern_loader = @import("pattern_loader.zig");
pub const import_resolver = @import("import_resolver.zig");
pub const auto_bundler = @import("auto_bundler.zig");
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
pub const mime = @import("mime.zig");
pub const watcher_mod = @import("watcher.zig");
pub const serve_mod = @import("serve.zig");
pub const link_checker = @import("link_checker.zig");

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
    InvalidBundleReference,
};

pub const StyleLoader = template_loader.StyleLoader;

const ValueMap = std.StringArrayHashMapUnmanaged(toupee.Value);

fn buildPhase_styleTokensSiteData(
    ba: Allocator,
    io: std.Io,
    abs_root: []const u8,
    site_cfg: *const config.SiteConfig,
    style_cfgs: []config.StyleConfig,
    data_result: *config.DataResult,
) !toupee.Context {
    var style_ctx = toupee.Context.init(ba);
    for (style_cfgs) |style_cfg| {
        var style_val = try context.combToToupee(ba, style_cfg.raw);
        if (style_val == .map) {
            // Before items synthesis so cloned `available.items` carry `source`.
            try ensureHighlightsPairDefaultSources(ba, &style_val.map);
            // Synthesize `items` lists within the style manifest (e.g. highlights.available)
            try synthesizeItemsLists(ba, &style_val.map);
        }
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

        // Load style-scoped data directory (styles/{name}/data/) into the style namespace.
        const style_data_path = try std.fs.path.join(ba, &.{ abs_root, "styles", style_cfg.name, "data" });
        var style_data = try config.loadDataDir(ba, io, style_data_path);
        var sd_it = style_data.iterator();
        while (sd_it.next()) |sd_entry| {
            const ctx_key = try std.fmt.allocPrint(ba, "styles.{s}.{s}", .{ style_cfg.name, sd_entry.key_ptr.* });
            if (style_ctx.resolve(ctx_key) != null) continue;
            var sd_val = sd_entry.value_ptr.*;
            if (sd_val == .map) {
                // Resolve palette indirection in style-scoped colour schemes.
                if (std.mem.eql(u8, sd_entry.key_ptr.*, "colors")) {
                    sd_val = try colors.resolveColorsData(ba, sd_val);
                } else {
                    try synthesizeItemsLists(ba, &sd_val.map);
                }
            }
            try style_ctx.putAt(ctx_key, sd_val);
        }
    }

    const site_val = try context.combToToupee(ba, site_cfg.raw);
    try style_ctx.put("site", site_val);

    if (data_result.value == .map) {
        var data_it = data_result.value.map.iterator();
        while (data_it.next()) |entry| {
            var val = entry.value_ptr.*;
            if (std.mem.eql(u8, entry.key_ptr.*, "colors") and val == .map) {
                val = try colors.resolveColorsData(ba, val);
            }
            try style_ctx.put(entry.key_ptr.*, val);
        }
    }

    return style_ctx;
}

/// Highlights convention: optional `pair.source` (which style owns the scheme YAML under
/// `styles.<source>.colors.<id>`). When omitted, defaults to the current style's own name
/// so a provider style need not repeat itself. Fills in before `highlights.available.items`
/// synthesis so cloned items carry `source` for `$()` dot paths.
fn ensureHighlightsPairDefaultSources(a: Allocator, style_map: *ValueMap) !void {
    const hl_ptr = style_map.getPtr("highlights") orelse return;
    if (hl_ptr.* != .map) return;

    const avail_ptr = hl_ptr.map.getPtr("available") orelse return;
    if (avail_ptr.* != .map) return;

    const default_source: []const u8 = if (style_map.get("name")) |n|
        switch (n) {
            .string => |s| s,
            else => "highlights",
        }
    else
        "highlights";

    var keys = std.ArrayListUnmanaged([]const u8).empty;
    defer keys.deinit(a);

    var scan_it = avail_ptr.map.iterator();
    while (scan_it.next()) |e| {
        if (std.mem.eql(u8, e.key_ptr.*, "items")) continue;
        if (e.value_ptr.* != .map) continue;
        if (e.value_ptr.map.get("source") != null) continue;
        try keys.append(a, try a.dupe(u8, e.key_ptr.*));
    }

    for (keys.items) |k| {
        const vp = avail_ptr.map.getPtr(k) orelse continue;
        if (vp.* != .map) continue;
        try vp.map.put(a, "source", .{ .string = default_source });
    }
}

/// Recursively walks `parent` looking for sub-maps whose values are all
/// maps (i.e. a directory of YAML files) and synthesizes an `items` list
/// so templates can iterate with `t-for`.  Each item is a shallow clone
/// with an added `id` field set to the map key.
fn synthesizeItemsLists(a: Allocator, parent: *ValueMap) !void {
    var it = parent.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* != .map) continue;
        var inner = &entry.value_ptr.*.map;

        // Recurse first so nested directories get items before parent.
        try synthesizeItemsLists(a, inner);

        if (inner.get("items") != null) continue;

        var all_maps = true;
        var check_it = inner.iterator();
        while (check_it.next()) |e| {
            if (e.value_ptr.* != .map) {
                all_maps = false;
                break;
            }
        }
        if (!all_maps or inner.count() == 0) continue;

        var items = std.ArrayListUnmanaged(toupee.Value).empty;
        var stem_it = inner.iterator();
        while (stem_it.next()) |stem_entry| {
            var item_map = try cloneValueMap(a, stem_entry.value_ptr.*.map);
            try item_map.put(a, "id", .{ .string = stem_entry.key_ptr.* });
            try items.append(a, .{ .map = item_map });
        }
        try inner.put(a, "items", .{ .list = try a.dupe(toupee.Value, items.items) });
    }
}

fn cloneValueMap(a: Allocator, src: ValueMap) !ValueMap {
    var dst: ValueMap = .{};
    var it = src.iterator();
    while (it.next()) |entry| {
        try dst.put(a, entry.key_ptr.*, entry.value_ptr.*);
    }
    return dst;
}

const PatternsResult = struct {
    resolved: []const import_resolver.ResolvedStyle,
    bundle_paths: std.StringArrayHashMapUnmanaged(?[]const u8),
};

fn buildPhase_patternsAndBundle(
    ba: Allocator,
    io: std.Io,
    abs_root: []const u8,
    style_cfgs: []config.StyleConfig,
    style_ctx: *const toupee.Context,
    output_dir: std.Io.Dir,
    diags: *diagnostics_mod.Collector,
) !PatternsResult {
    const styles_path = try std.fs.path.join(ba, &.{ abs_root, "styles" });

    var styles_dir = std.Io.Dir.openDirAbsolute(io, styles_path, .{ .iterate = true }) catch
        return .{ .resolved = &.{}, .bundle_paths = .{} };
    defer styles_dir.close(io);

    const resolved = try import_resolver.resolveAllStyles(
        ba,
        io,
        style_cfgs,
        styles_dir,
        style_ctx,
    );

    for (resolved) |rs| {
        for (rs.result.command_dispatch_paths) |path| {
            try diags.errFmt(ba, "command dispatch not yet implemented: {s}", .{path});
        }
    }

    var bundle_paths = std.StringArrayHashMapUnmanaged(?[]const u8){};
    for (resolved) |rs| {
        const bundle = try auto_bundler.generateBundle(ba, io, rs.name, rs.result, output_dir, style_ctx);
        try bundle_paths.put(ba, rs.name, if (bundle) |b| b.path else null);
    }

    return .{ .resolved = resolved, .bundle_paths = bundle_paths };
}

fn renderPatternExamples(
    ba: Allocator,
    patterns_result: PatternsResult,
    template_map: *const std.StringArrayHashMapUnmanaged([]const u8),
    style_ctx: *const toupee.Context,
) !std.StringArrayHashMapUnmanaged([]const u8) {
    var overrides = std.StringArrayHashMapUnmanaged([]const u8){};

    for (patterns_result.resolved) |rs| {
        var style_loader = template_loader.StyleLoader{
            .templates = template_map,
            .style_name = rs.name,
        };

        for (rs.result.all) |pattern| {
            if (pattern.example.len == 0) continue;
            if (std.mem.indexOf(u8, pattern.example, "<t-") == null) continue;

            const rendered = toupee.render(ba, pattern.example, style_ctx, style_loader.loader(), .{
                .strict = false,
            }) catch continue;

            if (!std.mem.eql(u8, rendered, pattern.example)) {
                try overrides.put(ba, pattern.slug, try ba.dupe(u8, rendered));
            }
        }
    }

    return overrides;
}

fn buildPhase_patternContext(
    ba: Allocator,
    io: std.Io,
    abs_root: []const u8,
    patterns_result: PatternsResult,
    example_overrides: *const std.StringArrayHashMapUnmanaged([]const u8),
    style_ctx: *toupee.Context,
    diags: *diagnostics_mod.Collector,
) !void {
    for (patterns_result.resolved) |rs| {
        const pattern_ctx = try pattern_loader.buildPatternContext(ba, rs.result, example_overrides);
        const ctx_key = try std.fmt.allocPrint(ba, "styles.{s}.patterns", .{rs.name});
        try style_ctx.putAt(ctx_key, pattern_ctx);

        if (patterns_result.bundle_paths.get(rs.name)) |opt_path| {
            if (opt_path) |path| {
                const css_path_key = try std.fmt.allocPrint(ba, "styles.{s}.css.path", .{rs.name});
                try style_ctx.putAt(css_path_key, .{ .string = path });
            }
        }

        // Build style file tree at styles.{name}.files
        const files_dir_path = try std.fs.path.join(ba, &.{ abs_root, "styles", rs.name, "files" });
        var files_dir = std.Io.Dir.openDirAbsolute(io, files_dir_path, .{ .iterate = true }) catch continue;
        defer files_dir.close(io);

        const file_tree = try buildStyleFileTree(ba, io, files_dir, rs.name, "", diags);
        const files_ctx_key = try std.fmt.allocPrint(ba, "styles.{s}.files", .{rs.name});
        try style_ctx.putAt(files_ctx_key, file_tree);
    }
}

/// Recursively walks a style's `files/` directory, building a nested toupee.Value
/// map. Files are keyed by stem (no extension), values are web path strings.
/// Directories with file children get an `items` list sorted alphabetically.
/// Stem collisions (two files with same stem, different extensions) are errors.
fn buildStyleFileTree(
    a: Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    style_name: []const u8,
    prefix: []const u8,
    diags: *diagnostics_mod.Collector,
) !toupee.Value {
    var map = ValueMap{};
    var items = std.ArrayListUnmanaged(toupee.Value).empty;
    var stem_exts = std.StringArrayHashMapUnmanaged([]const u8){};

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        switch (entry.kind) {
            .file => {
                const name = try a.dupe(u8, entry.name);
                const dot_pos = std.mem.lastIndexOfScalar(u8, name, '.') orelse continue;
                const stem = name[0..dot_pos];

                if (stem_exts.get(stem)) |existing_ext| {
                    const collision_path = if (prefix.len > 0)
                        try std.fmt.allocPrint(a, "{s}/{s}", .{ prefix, stem })
                    else
                        try a.dupe(u8, stem);
                    try diags.errFmt(a, "style file collision: styles/{s}/files/{s} has multiple extensions ({s}, {s})", .{
                        style_name, collision_path, existing_ext, name[dot_pos..],
                    });
                    continue;
                }
                try stem_exts.put(a, stem, name[dot_pos..]);

                const web_path = if (prefix.len > 0)
                    try std.fmt.allocPrint(a, "/assets/styles/{s}/{s}/{s}", .{ style_name, prefix, name })
                else
                    try std.fmt.allocPrint(a, "/assets/styles/{s}/{s}", .{ style_name, name });

                try map.put(a, stem, .{ .string = web_path });
                try items.append(a, .{ .string = web_path });
            },
            .directory => {
                const dir_name = try a.dupe(u8, entry.name);
                const sub_prefix = if (prefix.len > 0)
                    try std.fmt.allocPrint(a, "{s}/{s}", .{ prefix, dir_name })
                else
                    dir_name;

                var sub_dir = std.Io.Dir.openDir(dir, io, dir_name, .{ .iterate = true }) catch continue;
                defer sub_dir.close(io);
                const sub_tree = try buildStyleFileTree(a, io, sub_dir, style_name, sub_prefix, diags);
                try map.put(a, dir_name, sub_tree);
            },
            else => {},
        }
    }

    if (items.items.len > 0) {
        std.mem.sort(toupee.Value, items.items, {}, struct {
            fn cmp(_: void, lhs: toupee.Value, rhs: toupee.Value) bool {
                const ls = switch (lhs) {
                    .string => |s| s,
                    else => "",
                };
                const rs = switch (rhs) {
                    .string => |s| s,
                    else => "",
                };
                return std.mem.order(u8, ls, rs) == .lt;
            }
        }.cmp);
        try map.put(a, "items", .{ .list = try a.dupe(toupee.Value, items.items) });
    }

    return .{ .map = map };
}

fn buildPhase_scanAndTaxonomies(
    ba: Allocator,
    a: Allocator,
    io: std.Io,
    abs_root: []const u8,
    site_cfg: *const config.SiteConfig,
    site: *Site,
    style_ctx: *toupee.Context,
    data_result: *const config.DataResult,
) !scanner.ScanResult {
    const pages_path = try std.fs.path.join(a, &.{ abs_root, "pages" });
    defer a.free(pages_path);

    var registered_exts: std.ArrayListUnmanaged([]const u8) = .empty;
    defer registered_exts.deinit(a);
    for (site.options.content_parsers) |p| try registered_exts.append(a, p.extension);

    var pages_dir = std.Io.Dir.openDirAbsolute(io, pages_path, .{ .iterate = true }) catch
        return error.BuildFailed;
    defer pages_dir.close(io);

    const default_slugify = extractDefaultSlugify(data_result);

    var scan_result = try scanner.scanWithOptions(
        ba,
        io,
        pages_dir,
        site_cfg.url,
        site.options.draft,
        site.options.debug,
        registered_exts.items,
        default_slugify,
    );

    const tax_ctx = try taxonomies.buildIndex(ba, scan_result.pages, site_cfg.tags);
    try style_ctx.put("tags", tax_ctx);

    if (scan_result.collections.getPtr("pages")) |pv| {
        try style_ctx.putAt("pages", pv.*);
    }

    return scan_result;
}

const buildPhase_loadTemplates = template_loader.loadTemplates;

fn buildPhase_generatedArtifacts(
    ba: Allocator,
    io: std.Io,
    site_cfg: config.SiteConfig,
    style_cfgs: []config.StyleConfig,
    scan_result: *const scanner.ScanResult,
    engine: *toupee.Engine,
    style_ctx: *toupee.Context,
    template_map: *const std.StringArrayHashMapUnmanaged([]const u8),
    output_dir: std.Io.Dir,
    render_results: []const pages.RenderResult,
) !void {
    var search_entries = std.ArrayListUnmanaged(search.SearchEntry).empty;
    for (scan_result.pages, render_results) |*page, result| {
        if (page.meta.draft) continue;
        if (!page.meta.search) continue;
        const raw_plain = try search.stripHtml(ba, result.search_content);
        const trimmed = std.mem.trim(u8, raw_plain, " \t\n\r");
        const title = page.meta.title orelse "";
        const content_plain: []const u8 = if (title.len > 0 and trimmed.len > title.len and std.mem.startsWith(u8, trimmed, title)) cp: {
            const after = trimmed[title.len..];
            if (after.len > 0 and after[0] != ' ' and after[0] != '\t' and after[0] != '\n' and after[0] != '\r') {
                const rest = std.mem.trimStart(u8, after, " \t\n\r");
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
    try search.generateSearchJson(ba, entries_slice, io, output_dir);

    var rendered_map = std.StringArrayHashMapUnmanaged([]const u8){};
    for (scan_result.pages, render_results) |*page, result| {
        if (page.meta.draft) continue;
        try rendered_map.put(ba, page.source_path, result.search_content);
    }

    for (site_cfg.feeds) |feed_cfg| {
        try feeds.generateAtom(ba, feed_cfg, scan_result.pages, site_cfg.url, site_cfg.title, site_cfg.author, io, output_dir, rendered_map);
    }

    try feeds.generateSitemap(ba, scan_result.pages, io, output_dir);

    try tag_pages.render(
        ba,
        site_cfg,
        if (style_cfgs.len > 0) style_cfgs[0].name else "default",
        scan_result,
        engine,
        style_ctx,
        template_map,
        io,
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
    strict_links: bool = false,
    hooks: build_context_mod.Hooks = .{},
};

pub const BuildResult = struct {
    page_count: usize = 0,
    diagnostics: diagnostics_mod.Collector = .{},
};

pub const CheckOptions = struct {
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
    io: std.Io,
    options: SiteOptions,
    root_dir: std.Io.Dir,
    site_config: ?config.SiteConfig = null,
    style_configs: ?[]config.StyleConfig = null,
    data_result: ?config.DataResult = null,
    engine: ?toupee.Engine = null,
    build_arena: ?std.heap.ArenaAllocator = null,

    pub fn init(a: Allocator, io: std.Io, options: SiteOptions) !Site {
        const root_dir = std.Io.Dir.openDir(std.Io.Dir.cwd(), io, options.root, .{ .iterate = true }) catch
            return error.MissingConfig;

        return .{
            .allocator = a,
            .io = io,
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
        self.root_dir.close(self.io);
    }

    /// Opens the built site output directory (`zig-out/site` under the project root).
    /// Call after a successful `buildAll()`. Caller must `close()` the returned handle.
    pub fn openBuiltOutputDir(self: *Site) !std.Io.Dir {
        const a = self.allocator;
        const io = self.io;
        const abs_root = try std.Io.Dir.realPathFileAlloc(self.root_dir, io, ".", a);
        defer a.free(abs_root);
        const site_path = try output_paths.joinSiteOutputDirAbs(a, abs_root);
        defer a.free(site_path);
        return try std.Io.Dir.openDirAbsolute(io, site_path, .{});
    }

    pub fn buildAll(self: *Site, options: BuildOptions) !BuildResult {
        const a = self.allocator;
        const io = self.io;
        const abs_root = try std.Io.Dir.realPathFileAlloc(self.root_dir, io, ".", a);
        defer a.free(abs_root);

        if (self.build_arena) |*ba| ba.deinit();
        var build_arena = std.heap.ArenaAllocator.init(a);
        errdefer build_arena.deinit();
        const ba = build_arena.allocator();

        var diags = diagnostics_mod.Collector{};

        // --- Phase: load config ---
        var site_cfg = try config.loadSiteConfig(a, io, abs_root);
        errdefer site_cfg.deinit();

        const style_cfgs = try config.loadStyleConfigs(a, io, abs_root);
        var data_result = try config.loadDataFiles(a, io, abs_root);
        errdefer data_result.deinit();

        // --- Phase: ensure output tree ---
        var output_dir = try output_paths.prepareSiteOutput(a, io, abs_root, options.clean);
        defer output_dir.close(io);

        // --- Phase: style context, tokens, site + data YAML ---
        var style_ctx = try buildPhase_styleTokensSiteData(ba, io, abs_root, &site_cfg, style_cfgs, &data_result);

        // --- Phase: pattern loading, import resolution, @layer auto-bundling ---
        const patterns_result = try buildPhase_patternsAndBundle(ba, io, abs_root, style_cfgs, &style_ctx, output_dir, &diags);

        // --- Phase: Toupee engine + template map (main allocator) ---
        var engine = try toupee.Engine.init(a);
        var template_map = std.StringArrayHashMapUnmanaged([]const u8){};
        try buildPhase_loadTemplates(ba, io, a, abs_root, style_cfgs, &engine, &template_map);

        // --- Phase: render pattern examples through Toupee ---
        var example_overrides = try renderPatternExamples(ba, patterns_result, &template_map, &style_ctx);

        // --- Phase: build pattern context + style file tree ---
        try buildPhase_patternContext(ba, io, abs_root, patterns_result, &example_overrides, &style_ctx, &diags);

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

        // --- Phase: scan pages, tags, `pages` context ---
        var scan_result = try buildPhase_scanAndTaxonomies(ba, a, io, abs_root, &site_cfg, self, &style_ctx, &data_result);
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
            io,
            output_dir,
            &diags,
        );

        // --- Hook: post_render ---
        for (ctx.hooks.post_render) |hook| try hook(&ctx);

        // --- Phase: search, feeds, sitemap, tag pages ---
        try buildPhase_generatedArtifacts(
            ba,
            io,
            site_cfg,
            style_cfgs,
            &scan_result,
            &engine,
            &style_ctx,
            &template_map,
            output_dir,
            render_results,
        );

        // --- Phase: copy static files ---
        try checkSiteStyleCollision(io, self.root_dir, &diags, ba);
        try copyFiles(a, io, self.root_dir, output_dir);
        try copyStyleFiles(a, io, self.root_dir, output_dir, style_cfgs);
        try writeStyleResources(a, io, patterns_result, output_dir);

        // --- Phase: link checking ---
        {
            var source_map = std.StringArrayHashMapUnmanaged([]const u8){};
            for (scan_result.pages) |page| {
                try source_map.put(ba, page.output_file, page.source_path);
            }
            const link_issues = try link_checker.checkSite(ba, io, output_dir, source_map);
            for (link_issues) |issue| {
                const kind_str: []const u8 = switch (issue.kind) {
                    .broken_path => "broken link",
                    .broken_fragment => "broken fragment",
                };
                if (issue.source_path) |sp| {
                    if (options.strict_links) {
                        try diags.errFmt(ba, "{s}: {s} -> {s} (source: {s})", .{ kind_str, issue.output_path, issue.target_url, sp });
                    } else {
                        try diags.warnFmt(ba, "{s}: {s} -> {s} (source: {s})", .{ kind_str, issue.output_path, issue.target_url, sp });
                    }
                } else {
                    if (options.strict_links) {
                        try diags.errFmt(ba, "{s}: {s} -> {s}", .{ kind_str, issue.output_path, issue.target_url });
                    } else {
                        try diags.warnFmt(ba, "{s}: {s} -> {s}", .{ kind_str, issue.output_path, issue.target_url });
                    }
                }
            }
        }

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

    /// Checks site config, style manifests, and template resolution without
    /// rendering. The `--external` CLI flag is accepted; full external URL
    /// checking is planned for a future release (currently emits a warning).
    pub fn check(self: *Site, options: CheckOptions) ![]const Diagnostic {
        const a = self.allocator;

        var diags: std.ArrayListUnmanaged(Diagnostic) = .empty;

        const io = self.io;
        const abs_root = std.Io.Dir.realPathFileAlloc(self.root_dir, io, ".", a) catch
            return error.MissingConfig;
        defer a.free(abs_root);

        var site_cfg = config.loadSiteConfig(a, io, abs_root) catch |err| {
            try diags.append(a, .{ .kind = .err, .message = switch (err) {
                error.MissingConfig => "Missing site config: create data/site.yaml",
                error.DualConfig => "Found both site.yaml and site.json -- use exactly one",
                error.MissingUrl => "Site config missing required 'url' field",
                else => "Invalid site config",
            } });
            return try diags.toOwnedSlice(a);
        };
        defer site_cfg.deinit();

        const style_cfgs = config.loadStyleConfigs(a, io, abs_root) catch {
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
        template_loader.loadTemplates(a, io, a, abs_root, style_cfgs, &engine, &validate_template_map) catch {
            try diags.append(a, .{ .kind = .warning, .message = "Could not load templates; template validation may be incomplete" });
        };

        var resolver: toupee.Resolver = .{};
        const toupee_diags = engine.validate(a, resolver.loader()) catch
            return try diags.toOwnedSlice(a);
        defer a.free(toupee_diags);

        for (toupee_diags) |d| {
            try diags.append(a, .{
                .kind = .err,
                .message = try a.dupe(u8, d.message),
                .template_name = try a.dupe(u8, d.template),
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

/// Copies style-level `files/` directories to output at `/assets/styles/{name}/`.
fn copyStyleFiles(a: Allocator, io: std.Io, root_dir: std.Io.Dir, output_dir: std.Io.Dir, style_cfgs: []config.StyleConfig) !void {
    for (style_cfgs) |style_cfg| {
        const src_path = try std.fmt.allocPrint(a, "styles/{s}/files", .{style_cfg.name});
        defer a.free(src_path);
        var src_dir = std.Io.Dir.openDir(root_dir, io, src_path, .{ .iterate = true }) catch continue;
        defer src_dir.close(io);

        const dst_path = try std.fmt.allocPrint(a, "assets/styles/{s}", .{style_cfg.name});
        defer a.free(dst_path);
        std.Io.Dir.createDirPath(output_dir, io, dst_path) catch {};
        var dst_dir = try std.Io.Dir.openDir(output_dir, io, dst_path, .{});
        defer dst_dir.close(io);

        try copyDirRecursive(a, io, src_dir, dst_dir);
    }
}

/// Writes processed resource files to output. Pattern-matched CSS is skipped
/// (handled by the auto-bundler). All other resources are individually output.
fn writeStyleResources(
    a: Allocator,
    io: std.Io,
    patterns_result: PatternsResult,
    output_dir: std.Io.Dir,
) !void {
    for (patterns_result.resolved) |rs| {
        // Pattern-matched non-CSS resources.
        for (rs.result.all) |pattern| {
            var res_it = pattern.resources.iterator();
            while (res_it.next()) |entry| {
                if (std.mem.eql(u8, entry.key_ptr.*, "css")) continue;

                const out_path = try std.fmt.allocPrint(a, "assets/{s}/styles/{s}/{s}", .{
                    entry.key_ptr.*, pattern.source_style, entry.value_ptr.rel_path,
                });
                defer a.free(out_path);

                const dir_part = std.fs.path.dirname(out_path) orelse "";
                std.Io.Dir.createDirPath(output_dir, io, dir_part) catch {};
                var f = try std.Io.Dir.createFile(output_dir, io, out_path, .{});
                defer f.close(io);
                try f.writeStreamingAll(io, entry.value_ptr.content);
            }
        }

        // Standalone resources.
        for (rs.result.standalone_resources) |res| {
            const out_path = try std.fmt.allocPrint(a, "assets/{s}/styles/{s}/{s}", .{
                res.resource_type, rs.name, res.rel_path,
            });
            defer a.free(out_path);

            const dir_part = std.fs.path.dirname(out_path) orelse "";
            std.Io.Dir.createDirPath(output_dir, io, dir_part) catch {};
            var f = try std.Io.Dir.createFile(output_dir, io, out_path, .{});
            defer f.close(io);
            try f.writeStreamingAll(io, res.content);
        }
    }
}

/// Checks for collision between site-level `files/assets/styles/` and style file output.
fn checkSiteStyleCollision(io: std.Io, root_dir: std.Io.Dir, diags: *diagnostics_mod.Collector, ba: Allocator) !void {
    var check_dir = std.Io.Dir.openDir(root_dir, io, "files/assets/styles", .{}) catch return;
    check_dir.close(io);
    try diags.err(ba, "site files/assets/styles/ collides with style file output path; move site files elsewhere");
}

/// Recursively copies `files/` to the output root directory.
/// `files/robots.txt` → `/robots.txt`, `files/assets/img.png` → `/assets/img.png`.
fn copyFiles(a: Allocator, io: std.Io, root_dir: std.Io.Dir, output_dir: std.Io.Dir) !void {
    var files_dir = std.Io.Dir.openDir(root_dir, io, "files", .{ .iterate = true }) catch return;
    defer files_dir.close(io);

    try copyDirRecursive(a, io, files_dir, output_dir);
}

fn copyDirRecursive(a: Allocator, io: std.Io, src: std.Io.Dir, dst: std.Io.Dir) !void {
    var it = src.iterate();
    while (try it.next(io)) |entry| {
        switch (entry.kind) {
            .file => {
                const data = try std.Io.Dir.readFileAlloc(src, io, entry.name, a, .limited(64 * 1024 * 1024));
                defer a.free(data);
                var f = try std.Io.Dir.createFile(dst, io, entry.name, .{});
                defer f.close(io);
                try f.writeStreamingAll(io, data);
            },
            .directory => {
                std.Io.Dir.createDirPath(dst, io, entry.name) catch {};
                var sub_src = try std.Io.Dir.openDir(src, io, entry.name, .{ .iterate = true });
                defer sub_src.close(io);
                var sub_dst = try std.Io.Dir.openDir(dst, io, entry.name, .{});
                defer sub_dst.close(io);
                try copyDirRecursive(a, io, sub_src, sub_dst);
            },
            else => {},
        }
    }
}

/// Dev server entry point. Use `serve_mod.DevServer.run()` directly
/// or invoke via `wig serve` on the CLI.
pub const DevServer = serve_mod.DevServer;

test {
    _ = output_paths;
    _ = config;
    _ = context;
    _ = tokens;
    _ = colors;
    _ = frontmatter;
    _ = scanner;
    _ = taxonomies;
    _ = pages;
    _ = toc_mod;
    _ = search;
    _ = feeds;
    _ = pattern_parser;
    _ = pattern_loader;
    _ = import_resolver;
    _ = auto_bundler;
    _ = app;
    _ = router;
    _ = handler;
    _ = session;
    _ = scaffold;
    _ = html_utils;
    _ = test_runner;
    _ = mime;
    _ = watcher_mod;
    _ = link_checker;
}

test "E2E: data pipeline loads config, computes tokens, renders template" {
    const testing_alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(testing_alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try std.Io.Dir.createDirPath(tmp.dir, io, "data");
    try std.Io.Dir.createDirPath(tmp.dir, io, "styles/default");

    {
        var dir = try std.Io.Dir.openDir(tmp.dir, io, "data", .{});
        defer dir.close(io);
        var f = try std.Io.Dir.createFile(dir, io, "site.yaml", .{});
        try f.writeStreamingAll(io, "url: https://example.com\ntitle: E2E Test");
        f.close(io);
    }
    {
        var dir = try std.Io.Dir.openDir(tmp.dir, io, "styles/default", .{});
        defer dir.close(io);
        var f = try std.Io.Dir.createFile(dir, io, "style.yaml", .{});
        try f.writeStreamingAll(io,
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
        f.close(io);
    }

    const abs = try std.Io.Dir.realPathFileAlloc(tmp.dir, io, ".", a);

    var site_cfg = try config.loadSiteConfig(a, io, abs);
    defer site_cfg.deinit();

    const style_cfgs = try config.loadStyleConfigs(a, io, abs);
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

test "copyFiles: copies files/ to output root recursively" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try std.Io.Dir.createDirPath(tmp.dir, io, "files/assets/images");
    {
        var files = try std.Io.Dir.openDir(tmp.dir, io, "files", .{});
        defer files.close(io);
        var f = try std.Io.Dir.createFile(files, io, "robots.txt", .{});
        try f.writeStreamingAll(io, "User-agent: *");
        f.close(io);

        var assets_dir = try std.Io.Dir.openDir(files, io, "assets", .{});
        defer assets_dir.close(io);
        var css = try std.Io.Dir.createFile(assets_dir, io, "style.css", .{});
        try css.writeStreamingAll(io, "body{}");
        css.close(io);

        var images = try std.Io.Dir.openDir(assets_dir, io, "images", .{});
        defer images.close(io);
        var img = try std.Io.Dir.createFile(images, io, "logo.png", .{});
        try img.writeStreamingAll(io, "PNG");
        img.close(io);
    }

    try std.Io.Dir.createDirPath(tmp.dir, io, "output");
    var output = try std.Io.Dir.openDir(tmp.dir, io, "output", .{});
    defer output.close(io);

    try copyFiles(a, io, tmp.dir, output);

    const robots = try std.Io.Dir.readFileAlloc(output, io, "robots.txt", a, .limited(4096));
    defer a.free(robots);
    try std.testing.expectEqualStrings("User-agent: *", robots);

    const css = try std.Io.Dir.readFileAlloc(output, io, "assets/style.css", a, .limited(4096));
    defer a.free(css);
    try std.testing.expectEqualStrings("body{}", css);

    const img = try std.Io.Dir.readFileAlloc(output, io, "assets/images/logo.png", a, .limited(4096));
    defer a.free(img);
    try std.testing.expectEqualStrings("PNG", img);
}

test "putAt then resolve preserves nested map values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = toupee.Context.init(a);
    defer ctx.deinit();

    // Step 1: simulate buildPhase_styleTokensSiteData — styles.default with a name
    var style_map = ValueMap{};
    try style_map.put(a, "name", .{ .string = "default" });
    var styles_map = ValueMap{};
    try styles_map.put(a, "default", .{ .map = style_map });
    try ctx.put("styles", .{ .map = styles_map });

    // Step 2: simulate putAt("styles.default.patterns", ...)
    var patterns_map = ValueMap{};
    try patterns_map.put(a, "all", .{ .list = &.{} });
    try ctx.putAt("styles.default.patterns", .{ .map = patterns_map });

    // Step 3: simulate putAt("styles.default.files", ...) with nested map
    var logo_map = ValueMap{};
    try logo_map.put(a, "logo", .{ .string = "/assets/styles/default/images/logo.svg" });
    var files_map = ValueMap{};
    try files_map.put(a, "images", .{ .map = logo_map });
    try ctx.putAt("styles.default.files", .{ .map = files_map });

    // Verify: resolve from ctx directly
    const files_val = ctx.resolve("styles.default.files") orelse return error.TestUnexpectedResult;
    try std.testing.expect(files_val == .map);
    try std.testing.expectEqual(@as(usize, 1), files_val.map.count());

    const images_val = ctx.resolve("styles.default.files.images") orelse return error.TestUnexpectedResult;
    try std.testing.expect(images_val == .map);

    const logo = ctx.resolve("styles.default.files.images.logo") orelse return error.TestUnexpectedResult;
    try std.testing.expect(logo == .string);
    try std.testing.expectEqualStrings("/assets/styles/default/images/logo.svg", logo.string);

    // Step 4: simulate what renderPage does — initFrom + putAt("document.style", ...)
    var child = try toupee.Context.initFrom(a, &ctx);
    defer child.deinit();

    const style_resolved = child.resolve("styles.default") orelse return error.TestUnexpectedResult;
    try child.putAt("document.style", style_resolved);

    // Verify: document.style.files.images.logo
    const ds_files = child.resolve("document.style.files") orelse {
        std.debug.print("FAIL: document.style.files not found\n", .{});
        // Extra diagnostics: check what document.style contains
        if (child.resolve("document.style")) |ds| {
            if (ds == .map) {
                std.debug.print("  document.style keys:", .{});
                var ds_it = ds.map.iterator();
                while (ds_it.next()) |e| std.debug.print(" {s}({s})", .{ e.key_ptr.*, @tagName(e.value_ptr.*) });
                std.debug.print("\n", .{});
            }
        }
        return error.TestUnexpectedResult;
    };
    try std.testing.expect(ds_files == .map);

    const ds_logo = child.resolve("document.style.files.images.logo") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("/assets/styles/default/images/logo.svg", ds_logo.string);
}

test "putAt into existing map merges, does not clobber siblings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = toupee.Context.init(a);
    defer ctx.deinit();

    // Put a map at a.b with key "x"
    var inner = ValueMap{};
    try inner.put(a, "x", .{ .string = "1" });
    try ctx.putAt("a.b", .{ .map = inner });

    // Now put a new key at a.b.y — should not clobber x
    try ctx.putAt("a.b.y", .{ .string = "2" });

    // Both should be present
    const x = ctx.resolve("a.b.x") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("1", x.string);
    const y = ctx.resolve("a.b.y") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("2", y.string);

    // But putAt("a.b", new_map) REPLACES the whole map
    var replacement = ValueMap{};
    try replacement.put(a, "z", .{ .string = "3" });
    try ctx.putAt("a.b", .{ .map = replacement });

    // x and y should be gone, z should exist
    try std.testing.expect(ctx.resolve("a.b.x") == null);
    try std.testing.expect(ctx.resolve("a.b.y") == null);
    const z = ctx.resolve("a.b.z") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("3", z.string);
}

test "putAt-only style pipeline: putAt styles.default then add children" {
    // Reproduces the real pipeline: putAt("styles.default", val), then
    // putAt("styles.default.patterns", ...), then putAt("styles.default.files", ...).
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = toupee.Context.init(a);
    defer ctx.deinit();

    // Step 1: buildPhase_styleTokensSiteData — putAt("styles.default", yaml_value)
    var style_val = ValueMap{};
    try style_val.put(a, "name", .{ .string = "default" });
    try ctx.putAt("styles.default", .{ .map = style_val });

    // Verify initial state
    const name1 = ctx.resolve("styles.default.name") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("default", name1.string);

    // Step 2: putAt("styles.default.patterns", ...) — adds patterns sibling
    var patterns = ValueMap{};
    try patterns.put(a, "all", .{ .list = &.{} });
    try ctx.putAt("styles.default.patterns", .{ .map = patterns });

    // Verify name still there
    const name2 = ctx.resolve("styles.default.name") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("default", name2.string);

    // Step 3: putAt("styles.default.files", ...) — adds files sibling
    var images = ValueMap{};
    try images.put(a, "logo", .{ .string = "/assets/styles/default/images/logo.svg" });
    var files = ValueMap{};
    try files.put(a, "images", .{ .map = images });
    try ctx.putAt("styles.default.files", .{ .map = files });

    // Verify all three siblings present
    try std.testing.expect(ctx.resolve("styles.default.name") != null);
    try std.testing.expect(ctx.resolve("styles.default.patterns") != null);
    const f = ctx.resolve("styles.default.files") orelse return error.TestUnexpectedResult;
    try std.testing.expect(f == .map);
    try std.testing.expectEqual(@as(usize, 1), f.map.count());
    const logo = ctx.resolve("styles.default.files.images.logo") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("/assets/styles/default/images/logo.svg", logo.string);
}

test "initFrom child sees parent putAt additions via document.style alias" {
    // Full pipeline simulation: build style context, create child, alias to document.style
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var parent = toupee.Context.init(a);
    defer parent.deinit();

    // Build up styles.default with putAt (as real code does)
    var style_val = ValueMap{};
    try style_val.put(a, "name", .{ .string = "default" });
    try parent.putAt("styles.default", .{ .map = style_val });
    try parent.putAt("styles.default.patterns", .{ .string = "pat-placeholder" });

    var images = ValueMap{};
    try images.put(a, "logo", .{ .string = "/assets/styles/default/images/logo.svg" });
    var files = ValueMap{};
    try files.put(a, "images", .{ .map = images });
    try parent.putAt("styles.default.files", .{ .map = files });

    // Create child context (as renderPage does)
    var child = try toupee.Context.initFrom(a, &parent);
    defer child.deinit();

    // Resolve styles.default and put as document.style (as renderPage line 207-208)
    const style_resolved = child.resolve("styles.default") orelse return error.TestUnexpectedResult;
    try child.putAt("document.style", style_resolved);

    // Verify document.style.files.images.logo
    const ds_logo = child.resolve("document.style.files.images.logo") orelse {
        // Diagnostic: dump what document.style actually contains
        if (child.resolve("document.style")) |ds| {
            if (ds == .map) {
                std.debug.print("document.style keys:", .{});
                var it2 = ds.map.iterator();
                while (it2.next()) |e| std.debug.print(" {s}({s})", .{ e.key_ptr.*, @tagName(e.value_ptr.*) });
                std.debug.print("\n", .{});
            }
        }
        if (child.resolve("document.style.files")) |dsf| {
            if (dsf == .map) {
                std.debug.print("document.style.files count={d} keys:", .{dsf.map.count()});
                var it3 = dsf.map.iterator();
                while (it3.next()) |e| std.debug.print(" {s}", .{e.key_ptr.*});
                std.debug.print("\n", .{});
            } else {
                std.debug.print("document.style.files is {s}\n", .{@tagName(dsf)});
            }
        } else {
            std.debug.print("document.style.files is null\n", .{});
        }
        return error.TestUnexpectedResult;
    };
    try std.testing.expectEqualStrings("/assets/styles/default/images/logo.svg", ds_logo.string);
}

test "detachPerPageDocumentMap preserves style alias" {
    // Tests the detachPerPageDocumentMap step that happens between initFrom
    // and document.style being set. This copies the document map.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var parent = toupee.Context.init(a);
    defer parent.deinit();

    // Set up parent with style data and document defaults
    var style_val = ValueMap{};
    try style_val.put(a, "name", .{ .string = "default" });
    try parent.putAt("styles.default", .{ .map = style_val });

    var images = ValueMap{};
    try images.put(a, "logo", .{ .string = "/logo.svg" });
    var files = ValueMap{};
    try files.put(a, "images", .{ .map = images });
    try parent.putAt("styles.default.files", .{ .map = files });

    // Set document.layout in parent (as document.yaml would)
    try parent.putAt("document.layout", .{ .string = "page.html" });

    // Create child and detach document map (as renderPage does)
    var child = try toupee.Context.initFrom(a, &parent);
    defer child.deinit();

    // detachPerPageDocumentMap clones the document map
    const doc_val = parent.resolve("document") orelse return error.TestUnexpectedResult;
    if (doc_val == .map) {
        var clone: ValueMap = .{};
        var it = doc_val.map.iterator();
        while (it.next()) |e| {
            const val = e.value_ptr.*;
            const val_copy: toupee.Value = if (val == .string)
                .{ .string = try a.dupe(u8, val.string) }
            else
                val;
            try clone.put(a, try a.dupe(u8, e.key_ptr.*), val_copy);
        }
        try child.put("document", .{ .map = clone });
    }

    // Now set document.style from resolved styles.default
    const style_resolved = child.resolve("styles.default") orelse return error.TestUnexpectedResult;
    try child.putAt("document.style", style_resolved);

    // Verify
    const logo = child.resolve("document.style.files.images.logo") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("/logo.svg", logo.string);
}

test "full renderPage context sequence with many document.* putAt calls" {
    // Reproduces the exact sequence of putAt calls that renderPage makes,
    // including many document.* entries that grow the map before document.style.
    // Uses arena allocators like the real pipeline to catch allocator-specific issues.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var parent = toupee.Context.init(a);
    defer parent.deinit();

    // Set up parent like the real build pipeline
    var style_map = ValueMap{};
    try style_map.put(a, "name", .{ .string = "default" });
    try parent.putAt("styles.default", .{ .map = style_map });

    var patterns = ValueMap{};
    try patterns.put(a, "all", .{ .list = &.{} });
    try parent.putAt("styles.default.patterns", .{ .map = patterns });

    var images = ValueMap{};
    try images.put(a, "logo", .{ .string = "/assets/styles/default/images/logo.svg" });
    var files = ValueMap{};
    try files.put(a, "images", .{ .map = images });
    try parent.putAt("styles.default.files", .{ .map = files });

    try parent.putAt("document.layout", .{ .string = "page.html" });
    try parent.putAt("document.style", .{ .string = "default" });

    // Create child context (line 93 of pages.zig)
    var ctx = try toupee.Context.initFrom(a, &parent);
    defer ctx.deinit();

    // detachPerPageDocumentMap (line 94)
    const doc_val = parent.resolve("document") orelse return error.TestUnexpectedResult;
    if (doc_val == .map) {
        var clone: ValueMap = .{};
        var it = doc_val.map.iterator();
        while (it.next()) |e| {
            const val = e.value_ptr.*;
            const val_copy: toupee.Value = if (val == .string) .{ .string = try a.dupe(u8, val.string) } else val;
            try clone.put(a, try a.dupe(u8, e.key_ptr.*), val_copy);
        }
        try ctx.put("document", .{ .map = clone });
    }

    // Lines 95-96: document.path, document.url
    try ctx.putAt("document.path", .{ .string = "/" });
    try ctx.putAt("document.url", .{ .string = "http://localhost/" });

    // Line 133: document.ancestors
    try ctx.putAt("document.ancestors", .{ .list = &.{} });

    // Line 156-158: document.children
    try ctx.putAt("document.children", .{ .list = &.{} });

    // Line 161: document.toc
    try ctx.putAt("document.toc", .{ .list = &.{} });

    // Line 165: document.excerpt
    try ctx.putAt("document.excerpt", .{ .string = "" });

    // Lines 207-208: resolve styles.default and put as document.style
    const style_resolved = ctx.resolve("styles.default") orelse return error.TestUnexpectedResult;
    try ctx.putAt("document.style", style_resolved);

    // Line 213: document.layout AFTER document.style
    try ctx.putAt("document.layout", .{ .string = try a.dupe(u8, "page.html") });

    // NOW verify — does document.style.files survive all the map growth?
    const ds = ctx.resolve("document.style") orelse {
        std.debug.print("FAIL: document.style not found\n", .{});
        return error.TestUnexpectedResult;
    };
    try std.testing.expect(ds == .map);

    const ds_files = ctx.resolve("document.style.files") orelse {
        std.debug.print("FAIL: document.style.files not found\n", .{});
        std.debug.print("document.style keys:", .{});
        var it2 = ds.map.iterator();
        while (it2.next()) |e| std.debug.print(" {s}({s})", .{ e.key_ptr.*, @tagName(e.value_ptr.*) });
        std.debug.print("\n", .{});
        return error.TestUnexpectedResult;
    };
    try std.testing.expect(ds_files == .map);

    const logo = ctx.resolve("document.style.files.images.logo") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("/assets/styles/default/images/logo.svg", logo.string);
}
