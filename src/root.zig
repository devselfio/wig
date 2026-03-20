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
/// Explicit paths: `layouts/X.html`, `blocks/X.html` resolve within the current style.
/// Cross-style: `style:path` (e.g. `_core:layouts/base.html`) resolves from another style.
/// Short names (e.g. `page.html`) try layouts then blocks.
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

        // Cross-style: style:path (e.g. _core:layouts/base.html)
        if (std.mem.indexOf(u8, name, ":")) |colon_pos| {
            const target_style = name[0..colon_pos];
            const path = name[colon_pos + 1 ..];
            const full = try std.fmt.allocPrint(a, "{s}/templates/{s}", .{ target_style, path });
            defer a.free(full);
            if (self.templates.get(full)) |src| return try a.dupe(u8, src);
            return null;
        }

        // Legacy _core/ prefix
        if (std.mem.startsWith(u8, name, "_core/")) {
            const short = name["_core/".len..];
            const full = try std.fmt.allocPrint(a, "_core/templates/{s}", .{short});
            defer a.free(full);
            if (self.templates.get(full)) |src| return try a.dupe(u8, src);
            return null;
        }

        // Try as-is first (full path like default/templates/layouts/page.html)
        if (self.templates.get(name)) |src| return try a.dupe(u8, src);

        // Paths with slash: layouts/X or blocks/X → style/templates/layouts/X or style/templates/blocks/X
        if (std.mem.indexOf(u8, name, "/") != null) {
            const full = try std.fmt.allocPrint(a, "{s}/templates/{s}", .{ self.style_name, name });
            defer a.free(full);
            if (self.templates.get(full)) |src| return try a.dupe(u8, src);
            return null;
        }

        // Short names: try layouts then blocks
        for ([_][]const u8{ "layouts/", "blocks/" }) |subdir| {
            const full = try std.fmt.allocPrint(a, "{s}/templates/{s}{s}", .{ self.style_name, subdir, name });
            defer a.free(full);
            if (self.templates.get(full)) |src| return try a.dupe(u8, src);
        }

        return null;
    }
};

const ValueMap = std.StringArrayHashMapUnmanaged(toupee.Value);

/// Page map shape matching `taxonomies.buildIndex` entries (path, url, source, merged frontmatter).
fn tagPageValueFromEntry(a: Allocator, page: *const scanner.PageEntry) !toupee.Value {
    var page_map = ValueMap{};
    try page_map.put(a, "path", .{ .string = page.url_path });
    try page_map.put(a, "url", .{ .string = page.absolute_url });
    try page_map.put(a, "source", .{ .string = page.source_path });
    if (page.frontmatter == .map) {
        var fm_it = page.frontmatter.map.iterator();
        while (fm_it.next()) |entry| {
            try page_map.put(a, entry.key_ptr.*, entry.value_ptr.*);
        }
    }
    return .{ .map = page_map };
}

fn wrapTagListDocumentItem(a: Allocator, page_val: toupee.Value) !toupee.Value {
    if (page_val != .map) return error.InvalidTagPageValue;
    const pm = page_val.map;
    const ppath = pm.get("path") orelse return error.MissingTagPagePath;
    if (ppath != .string) return error.MissingTagPagePath;
    const ptitle = pages.getDocTitle(page_val) orelse "";
    var inner = ValueMap{};
    try inner.put(a, "path", ppath);
    try inner.put(a, "title", .{ .string = try a.dupe(u8, ptitle) });
    var outer = ValueMap{};
    try outer.put(a, "document", .{ .map = inner });
    return .{ .map = outer };
}

fn pageHasBothTagSlugs(fm: toupee.Value, a_slug: []const u8, b_slug: []const u8, ba: Allocator) !bool {
    const terms = taxonomies.getTerms(fm, "tags") orelse return false;
    var has_a = false;
    var has_b = false;
    for (terms) |tv| {
        const raw = switch (tv) {
            .string => |s| s,
            else => continue,
        };
        const sl = try taxonomies.slugify(ba, raw);
        if (std.mem.eql(u8, sl, a_slug)) has_a = true;
        if (std.mem.eql(u8, sl, b_slug)) has_b = true;
    }
    return has_a and has_b;
}

/// Renders `/tags/` index, `/tags/{slug}/`, and `/tags/{a}/{b}/` intersection pages when `tags` is listed in site taxonomies.
fn renderTaxonomyTagPages(
    ba: Allocator,
    site_cfg: config.SiteConfig,
    style_name: []const u8,
    scan_result: *const scanner.ScanResult,
    engine: *toupee.Engine,
    base_ctx: *toupee.Context,
    template_map: *const std.StringArrayHashMapUnmanaged([]const u8),
    output_dir: fs.Dir,
) !void {
    var want_tags = false;
    for (site_cfg.taxonomies) |t| {
        if (std.mem.eql(u8, t, "tags")) {
            want_tags = true;
            break;
        }
    }
    if (!want_tags) return;

    const tax_val = base_ctx.resolve("taxonomies") orelse return;
    if (tax_val != .map) return;
    const tags_root = tax_val.map.get("tags") orelse return;
    if (tags_root != .map) return;

    const tmpl_index_key = try std.fmt.allocPrint(ba, "{s}/templates/layouts/tag-index.html", .{style_name});
    const tmpl_list_key = try std.fmt.allocPrint(ba, "{s}/templates/layouts/tag-list.html", .{style_name});
    const tmpl_index = template_map.get(tmpl_index_key) orelse return;
    const tmpl_list = template_map.get(tmpl_list_key) orelse return;

    var sl: StyleLoader = .{ .templates = template_map, .style_name = style_name };

    const TagInfo = struct {
        slug: []const u8,
        name: []const u8,
        pages: []const toupee.Value,
    };

    var tag_infos: std.ArrayListUnmanaged(TagInfo) = .{};
    var tit = tags_root.map.iterator();
    while (tit.next()) |e| {
        if (e.value_ptr.* != .map) continue;
        const tm = e.value_ptr.*.map;
        const nm = tm.get("name") orelse continue;
        if (nm != .string) continue;
        const pg = tm.get("pages") orelse continue;
        if (pg != .list) continue;
        try tag_infos.append(ba, .{
            .slug = e.key_ptr.*,
            .name = nm.string,
            .pages = pg.list,
        });
    }

    std.mem.sort(TagInfo, tag_infos.items, {}, struct {
        fn lt(_: void, x: TagInfo, y: TagInfo) bool {
            if (x.pages.len != y.pages.len) return x.pages.len > y.pages.len;
            return std.mem.order(u8, x.slug, y.slug) == .lt;
        }
    }.lt);

    const list_vals = try ba.alloc(toupee.Value, tag_infos.items.len);
    for (tag_infos.items, list_vals) |info, *out| {
        var m = ValueMap{};
        const path_str = try std.fmt.allocPrint(ba, "/tags/{s}/", .{info.slug});
        try m.put(ba, "path", .{ .string = path_str });
        try m.put(ba, "name", .{ .string = info.name });
        try m.put(ba, "count", .{ .integer = @intCast(info.pages.len) });
        out.* = .{ .map = m };
    }

    // --- /tags/index.html ---
    {
        var ctx = try toupee.Context.initFrom(ba, base_ctx);
        defer ctx.deinit();
        var wrap = ValueMap{};
        try wrap.put(ba, "tags", .{ .list = list_vals });
        try ctx.put("tag", .{ .map = wrap });
        const html_out = try engine.render(ba, tmpl_index, &ctx, sl.loader(), .{});
        defer ba.free(html_out);
        output_dir.makePath("tags") catch {};
        var f = try output_dir.createFile("tags/index.html", .{});
        defer f.close();
        try f.writeAll(html_out);
    }

    // --- /tags/{slug}/index.html ---
    for (tag_infos.items) |info| {
        var ctx = try toupee.Context.initFrom(ba, base_ctx);
        defer ctx.deinit();

        var doc_map = ValueMap{};
        try doc_map.put(ba, "title", .{ .string = info.name });
        var tag_wrap = ValueMap{};
        try tag_wrap.put(ba, "document", .{ .map = doc_map });
        const path_tags_str = try std.fmt.allocPrint(ba, "{s}", .{info.slug});
        try tag_wrap.put(ba, "path_tags", .{ .string = path_tags_str });

        const doc_items = try ba.alloc(toupee.Value, info.pages.len);
        var doc_n: usize = 0;
        for (info.pages) |pv| {
            if (pv != .map) continue;
            const pm = pv.map;
            if (pm.get("path")) |pp| {
                if (pp != .string) continue;
            } else continue;
            doc_items[doc_n] = try wrapTagListDocumentItem(ba, pv);
            doc_n += 1;
        }
        try tag_wrap.put(ba, "documents", .{ .list = doc_items[0..doc_n] });
        try tag_wrap.put(ba, "tags", .{ .list = list_vals });
        try ctx.put("tag", .{ .map = tag_wrap });

        const html_out = try engine.render(ba, tmpl_list, &ctx, sl.loader(), .{});
        defer ba.free(html_out);
        const dir = try std.fmt.allocPrint(ba, "tags/{s}", .{info.slug});
        defer ba.free(dir);
        output_dir.makePath(dir) catch {};
        const file_path = try std.fmt.allocPrint(ba, "{s}/index.html", .{dir});
        defer ba.free(file_path);
        var f = try output_dir.createFile(file_path, .{});
        defer f.close();
        try f.writeAll(html_out);
    }

    // --- /tags/{a}/{b}/index.html for co-occurring tags (slugs sorted descending in path) ---
    var pair_seen = std.StringArrayHashMapUnmanaged(void){};
    defer pair_seen.deinit(ba);

    for (scan_result.pages) |*page| {
        if (page.is_section) continue;
        const terms = taxonomies.getTerms(page.frontmatter, "tags") orelse continue;
        var slug_buf: std.ArrayListUnmanaged([]const u8) = .{};
        defer slug_buf.deinit(ba);
        for (terms) |t| {
            const raw = switch (t) {
                .string => |s| s,
                else => continue,
            };
            try slug_buf.append(ba, try taxonomies.slugify(ba, raw));
        }
        if (slug_buf.items.len < 2) continue;
        std.mem.sort([]const u8, slug_buf.items, {}, struct {
            fn gt(_: void, x: []const u8, y: []const u8) bool {
                return std.mem.order(u8, x, y) == .gt;
            }
        }.gt);
        for (0..slug_buf.items.len) |i| {
            for (i + 1..slug_buf.items.len) |j| {
                const a_slug = slug_buf.items[i];
                const b_slug = slug_buf.items[j];
                const key = try std.fmt.allocPrint(ba, "{s}/{s}", .{ a_slug, b_slug });
                _ = try pair_seen.getOrPut(ba, key);
            }
        }
    }

    var pit = pair_seen.iterator();
    while (pit.next()) |kv| {
        const key = kv.key_ptr.*;
        const mid = std.mem.indexOfScalar(u8, key, '/') orelse continue;
        if (mid == 0 or mid + 1 >= key.len) continue;
        const a_slug = key[0..mid];
        const b_slug = key[mid + 1 ..];

        var match_pages: std.ArrayListUnmanaged(toupee.Value) = .{};
        for (scan_result.pages) |*sp| {
            if (sp.is_section) continue;
            if (!try pageHasBothTagSlugs(sp.frontmatter, a_slug, b_slug, ba)) continue;
            try match_pages.append(ba, try tagPageValueFromEntry(ba, sp));
        }
        if (match_pages.items.len == 0) continue;

        const path_tags_join = try std.fmt.allocPrint(ba, "{s}/{s}", .{ a_slug, b_slug });
        var doc_map2 = ValueMap{};
        try doc_map2.put(ba, "title", .{ .string = path_tags_join });
        var tag_wrap2 = ValueMap{};
        try tag_wrap2.put(ba, "document", .{ .map = doc_map2 });
        try tag_wrap2.put(ba, "path_tags", .{ .string = path_tags_join });

        const doc_items2 = try ba.alloc(toupee.Value, match_pages.items.len);
        for (match_pages.items, doc_items2) |mpv, *dout| {
            dout.* = try wrapTagListDocumentItem(ba, mpv);
        }
        try tag_wrap2.put(ba, "documents", .{ .list = doc_items2 });
        try tag_wrap2.put(ba, "tags", .{ .list = list_vals });

        var ctx2 = try toupee.Context.initFrom(ba, base_ctx);
        defer ctx2.deinit();
        try ctx2.put("tag", .{ .map = tag_wrap2 });
        const html2 = try engine.render(ba, tmpl_list, &ctx2, sl.loader(), .{});
        defer ba.free(html2);
        const dir2 = try std.fmt.allocPrint(ba, "tags/{s}/{s}", .{ a_slug, b_slug });
        defer ba.free(dir2);
        output_dir.makePath(dir2) catch {};
        const fp2 = try std.fmt.allocPrint(ba, "{s}/index.html", .{dir2});
        defer ba.free(fp2);
        var f2 = try output_dir.createFile(fp2, .{});
        defer f2.close();
        try f2.writeAll(html2);
    }
}

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
                    try std.fmt.allocPrint(ba, "styles.{s}.computed_tokens", .{style_cfg.name}),
                    token_result.value,
                );
            }
        }

        // Put site data into context
        const site_val = try context.combToToupee(ba, site_cfg.raw);
        try style_ctx.put("site", site_val);

        // Put data files into context (resolve colours palette indirection)
        if (data_result.value == .map) {
            var data_it = data_result.value.map.iterator();
            while (data_it.next()) |entry| {
                var val = entry.value_ptr.*;
                if (std.mem.eql(u8, entry.key_ptr.*, "colours") and val == .map) {
                    val = try colours.resolveColoursData(ba, val);
                }
                try style_ctx.put(entry.key_ptr.*, val);
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
                    if (assets_val == .array) {
                        for (assets_val.array) |item| {
                            if (item != .string) continue;
                            const bundle_path = item.string;
                            if (std.mem.indexOf(u8, bundle_path, "/")) |slash| {
                                const bundle_type = bundle_path[0..slash];
                                const template_rel = bundle_path;
                                const result = bundles.processBundleToPath(
                                    ba,
                                    style_cfg.name,
                                    bundle_path,
                                    template_rel,
                                    styles_dir,
                                    &style_ctx,
                                    output_dir,
                                ) catch continue;
                                const bundle_name = std.fs.path.stem(bundle_path[slash + 1 ..]);
                                try asset_entries.append(ba, .{
                                    .style_name = style_cfg.name,
                                    .bundle_type = bundle_type,
                                    .bundle_name = bundle_name,
                                    .result = result,
                                });
                            }
                        }
                    } else if (assets_val == .object) {
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

        // Single nested `pages` map: root slugs (document, two, …) plus per-folder maps
        // { document, items, slug-per-page } for `pages.posts`, `pages.blog`, etc.
        if (scan_result.collections.getPtr("pages")) |pv| {
            try style_ctx.putAt("pages", pv.*);
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
            for ([_][]const u8{ "templates/layouts", "templates/blocks" }) |subdir| {
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
                for ([_][]const u8{ "templates/layouts", "templates/blocks" }) |subdir| {
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
            }
        } else |_| {}

        // Transform registry for {{ }} interpolation
        var transform_reg = toupee.transform.Registry{};
        try transform_reg.registerBuiltins(ba);
        defer transform_reg.deinit(ba);

        // Render pages with per-style template resolution
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

        // Generate search.json
        var search_entries = std.ArrayListUnmanaged(search.SpecSearchEntry){};
        for (scan_result.pages, render_results) |*page, result| {
            if (page.is_draft) continue;
            const raw_plain = try search.stripHtml(ba, result.search_content);
            const trimmed = std.mem.trim(u8, raw_plain, " \t\n\r");
            const title = pages.getDocTitle(page.frontmatter) orelse "";
            // Spec: content is title + "\n" + body plain text (strip merges h1 + body; re-split on title)
            // Djot: `*x*` is strong; `**x**` nests two strongs — only merge title+body when the
            // stripped text glues heading to body (no whitespace after title), e.g. "My PostThis is…".
            const content_plain: []const u8 = if (title.len > 0 and trimmed.len > title.len and std.mem.startsWith(u8, trimmed, title)) cp: {
                const after = trimmed[title.len..];
                if (after.len > 0 and after[0] != ' ' and after[0] != '\t' and after[0] != '\n' and after[0] != '\r') {
                    const rest = std.mem.trimLeft(u8, after, " \t\n\r");
                    break :cp try std.fmt.allocPrint(ba, "{s}\n{s}", .{ title, rest });
                }
                break :cp try ba.dupe(u8, trimmed);
            } else try ba.dupe(u8, trimmed);
            const excerpt = pages.extractExcerptPublic(ba, page.frontmatter, result.search_content) orelse content_plain;
            var tags_list: []const []const u8 = &.{};
            if (page.frontmatter == .map) {
                if (page.frontmatter.map.get("document")) |doc| {
                    if (doc == .map) {
                        if (doc.map.get("tags")) |tags_val| {
                            if (tags_val == .list) {
                                const tag_strs = try ba.alloc([]const u8, tags_val.list.len);
                                for (tags_val.list, tag_strs) |t, *out| {
                                    out.* = if (t == .string) t.string else "";
                                }
                                tags_list = tag_strs;
                            }
                        }
                    }
                }
            }
            const date_str = if (page.frontmatter == .map) blk: {
                if (page.frontmatter.map.get("document")) |doc| {
                    if (doc == .map) {
                        if (doc.map.get("date")) |d| {
                            if (d == .string) break :blk d.string;
                        }
                    }
                }
                break :blk null;
            } else null;
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
        std.mem.sort(search.SpecSearchEntry, entries_slice, {}, struct {
            fn lessThan(_: void, lhs: search.SpecSearchEntry, rhs: search.SpecSearchEntry) bool {
                return std.mem.order(u8, lhs.url, rhs.url) == .lt;
            }
        }.lessThan);
        try search.generateSearchJson(ba, entries_slice, output_dir);

        // Generate feeds
        for (site_cfg.feeds) |feed_cfg| {
            try feeds.generateAtom(ba, feed_cfg, scan_result.pages, site_cfg.url, site_cfg.title, site_cfg.author, output_dir);
        }

        // Generate sitemap
        try feeds.generateSitemap(ba, scan_result.pages, output_dir);

        try renderTaxonomyTagPages(
            ba,
            site_cfg,
            if (style_cfgs.len > 0) style_cfgs[0].name else "default",
            &scan_result,
            &engine,
            &style_ctx,
            &template_map,
            output_dir,
        );

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
            for ([_][]const u8{ "templates", "includes" }) |subdir| {
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
                for ([_][]const u8{ "templates", "includes" }) |subdir| {
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
                .template_name = d.template,
            });
        }

        return try diags.toOwnedSlice(a);
    }
};

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
