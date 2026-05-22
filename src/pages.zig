const std = @import("std");
const toupee = @import("toupee");
const scanner_mod = @import("scanner.zig");
const toc_mod = @import("toc.zig");
const context_mod = @import("context.zig");
const html = @import("html.zig");
const template_loader = @import("template_loader.zig");
const cascade = @import("cascade.zig");
const diagnostics_mod = @import("diagnostics.zig");

const Allocator = std.mem.Allocator;
const ValueMap = std.StringArrayHashMapUnmanaged(toupee.Value);

pub const ContentParser = *const fn (Allocator, []const u8) anyerror![]const u8;

pub const ContentParserEntry = struct {
    extension: []const u8,
    parse: ContentParser,
};

pub const RenderResult = struct {
    output_html: []const u8,
    search_content: []const u8,
};

/// Renders a single page through the full pipeline:
///   1. Content parsing (dispatch by extension, .html = pass-through)
///   2. Shortcode rendering (Toupee pass on content HTML)
///   3. ToC extraction from rendered content
///   4. Excerpt extraction (first <p> or frontmatter description:)
///   5. Context building (data cascade + document.* + toc + excerpt)
///   6. Layout rendering through Toupee Engine (content as slot)
///
/// When `pagination` is non-null the paginate context is injected (list layouts).
pub fn renderOne(
    a: Allocator,
    entry: *const scanner_mod.PageEntry,
    engine: *const toupee.Engine,
    base_ctx: *const toupee.Context,
    template_map: *const std.StringArrayHashMapUnmanaged([]const u8),
    content_parsers: []const ContentParserEntry,
    transform_registry: *const toupee.transform.Registry,
    scan_result: *const scanner_mod.ScanResult,
    diags: *diagnostics_mod.Collector,
) !RenderResult {
    return renderPage(a, entry, null, null, engine, base_ctx, template_map, content_parsers, transform_registry, scan_result, diags);
}

fn renderPage(
    a: Allocator,
    entry: *const scanner_mod.PageEntry,
    pagination: ?PaginationChunk,
    layout_override: ?[]const u8,
    engine: *const toupee.Engine,
    base_ctx: *const toupee.Context,
    template_map: *const std.StringArrayHashMapUnmanaged([]const u8),
    content_parsers: []const ContentParserEntry,
    transform_registry: *const toupee.transform.Registry,
    scan_result: *const scanner_mod.ScanResult,
    diags: *diagnostics_mod.Collector,
) !RenderResult {
    // Phase 1: content preparation (interpolations → parse → shortcodes)
    var interp_ctx = try toupee.Context.initFrom(a, base_ctx);
    defer interp_ctx.deinit();
    try detachPerPageDocumentMap(a, &interp_ctx, base_ctx);
    try interp_ctx.putAt("document.path", .{ .string = entry.url_path });
    try interp_ctx.putAt("document.url", .{ .string = entry.absolute_url });
    if (entry.raw_frontmatter == .map) {
        if (entry.raw_frontmatter.map.get("document")) |doc_val| {
            if (doc_val == .map) {
                var doc_it = doc_val.map.iterator();
                while (doc_it.next()) |doc_entry| {
                    const doc_key = try std.fmt.allocPrint(a, "document.{s}", .{doc_entry.key_ptr.*});
                    const val = doc_entry.value_ptr.*;
                    const val_copy: toupee.Value = if (val == .string) .{ .string = try a.dupe(u8, val.string) } else val;
                    try interp_ctx.putAt(doc_key, val_copy);
                }
            }
        }
    }
    // Resolve document.style so {{ document.style.files.* }} works in content.
    const interp_style_name = cascade.resolveStyle(entry, scan_result, base_ctx) orelse "default";
    const interp_style_path = try std.fmt.allocPrint(a, "styles.{s}", .{interp_style_name});
    defer a.free(interp_style_path);
    if (interp_ctx.resolve(interp_style_path)) |style_val|
        try interp_ctx.putAt("document.style", style_val);
    // Content `{{ document.title }}` resolves only when a root `title:` exists in frontmatter;
    // nested-only `document:` blocks leave `document.title` unset (see test/035). Treat as empty.
    if (interp_ctx.resolve("document.title") == null) {
        try interp_ctx.putAt("document.title", .{ .string = "" });
    }
    const content_preprocessed = try resolveInterpolations(a, entry.content_body, &interp_ctx, transform_registry, entry.source_path, diags);
    errdefer a.free(content_preprocessed);
    const content_html = try parseContent(a, content_preprocessed, entry.extension, content_parsers);
    a.free(content_preprocessed);
    const search_content = try a.dupe(u8, content_html);

    // Shortcode pass: resolve <t-var>, <t-raw>, <t-if>, <t-for>, and <t-include> tags
    // in content HTML (from Djot =html raw blocks or HTML pages) using the page's style
    // loader so block templates are available alongside data-access shortcodes.
    const shortcode_style_loader = template_loader.StyleLoader{
        .templates = template_map,
        .style_name = interp_style_name,
    };
    const shortcoded = toupee.render(a, content_html, base_ctx, shortcode_style_loader.loader(), .{}) catch content_html;

    const toc_entries = try toc_mod.extract(a, shortcoded);
    const toc_value = try toc_mod.toValue(a, toc_entries);
    const excerpt = extractExcerpt(a, entry.raw_frontmatter, shortcoded);

    // Phase 2: context building
    var ctx = try toupee.Context.initFrom(a, base_ctx);
    try detachPerPageDocumentMap(a, &ctx, base_ctx);
    try ctx.putAt("document.path", .{ .string = entry.url_path });
    try ctx.putAt("document.url", .{ .string = entry.absolute_url });

    if (pagination) |chunk| {
        try ctx.put("paginate", chunk.context);
        if (entry.meta.paginate) |cfg| {
            if (chunk.items.len == 1) {
                try ctx.put(cfg.alias, chunk.items[0]);
            }
        }
    }

    try cascade.applyCascadeToContext(a, entry, scan_result, &ctx);

    if (scan_result.parent_map.get(entry.url_path)) |parent_opt| {
        if (parent_opt) |parent_page| {
            const title = parent_page.meta.title orelse "";
            var parent_map = ValueMap{};
            try parent_map.put(a, "path", .{ .string = parent_page.url_path });
            try parent_map.put(a, "title", .{ .string = title });
            try ctx.putAt("document.parent", .{ .map = parent_map });
        }
    }

    var ancestors_list = std.ArrayListUnmanaged(toupee.Value).empty;
    var current_url = entry.url_path;
    while (scan_result.parent_map.get(current_url)) |parent_opt| {
        const parent_page = parent_opt orelse break;
        const title = parent_page.meta.title orelse "";
        var ancestor_map = ValueMap{};
        try ancestor_map.put(a, "path", .{ .string = parent_page.url_path });
        try ancestor_map.put(a, "title", .{ .string = title });
        try ancestors_list.append(a, .{ .map = ancestor_map });
        current_url = parent_page.url_path;
    }
    std.mem.reverse(toupee.Value, ancestors_list.items);
    const ancestors = try a.dupe(toupee.Value, ancestors_list.items);
    defer a.free(ancestors);
    try ctx.putAt("document.ancestors", .{ .list = ancestors });

    if (scan_result.children_map.get(scanner_mod.pagesParentDir(entry.source_path))) |children| {
        const child_vals = try a.alloc(toupee.Value, children.len);
        for (children, child_vals) |child_page, *cv| {
            cv.* = try scanner_mod.buildPageValue(a, child_page);
            switch (cv.*) {
                .map => |*m| {
                    const t = child_page.meta.title orelse "";
                    try m.put(a, "title", .{ .string = try a.dupe(u8, t) });
                },
                else => {},
            }
        }
        std.mem.sort(toupee.Value, child_vals, {}, struct {
            fn lessThan(_: void, lhs: toupee.Value, rhs: toupee.Value) bool {
                const l_path = if (lhs == .map) (lhs.map.get("path") orelse return false) else return false;
                const r_path = if (rhs == .map) (rhs.map.get("path") orelse return true) else return true;
                const l_str = if (l_path == .string) l_path.string else return false;
                const r_str = if (r_path == .string) r_path.string else return true;
                return std.mem.order(u8, l_str, r_str) == .lt;
            }
        }.lessThan);
        try ctx.putAt("document.children", .{ .list = child_vals });
    } else {
        try ctx.putAt("document.children", .{ .list = &[_]toupee.Value{} });
    }

    try ctx.putAt("document.toc", toc_value);
    if (excerpt) |e| {
        try ctx.putAt("document.excerpt", .{ .string = e });
    } else {
        try ctx.putAt("document.excerpt", .{ .string = "" });
    }

    // Engine-computed document keys that frontmatter must not overwrite.
    const computed_keys = [_][]const u8{
        "path", "url", "toc", "excerpt", "style", "layout",
        "parent", "ancestors", "children",
    };

    if (entry.raw_frontmatter == .map) {
        var fm_it = entry.raw_frontmatter.map.iterator();
        while (fm_it.next()) |fm_entry| {
            if (std.mem.eql(u8, fm_entry.key_ptr.*, "document") and fm_entry.value_ptr.* == .map) {
                var doc_it = fm_entry.value_ptr.*.map.iterator();
                while (doc_it.next()) |doc_entry| {
                    const doc_key = try std.fmt.allocPrint(a, "document.{s}", .{doc_entry.key_ptr.*});
                    const val = doc_entry.value_ptr.*;
                    const val_copy: toupee.Value = if (val == .string) .{ .string = try a.dupe(u8, val.string) } else val;
                    try ctx.putAt(doc_key, val_copy);
                }
            } else {
                var is_computed = false;
                for (computed_keys) |ck| {
                    if (std.mem.eql(u8, fm_entry.key_ptr.*, ck)) {
                        is_computed = true;
                        break;
                    }
                }
                if (!is_computed) {
                    const key = try std.fmt.allocPrint(a, "document.{s}", .{fm_entry.key_ptr.*});
                    try ctx.putAt(key, fm_entry.value_ptr.*);
                }
            }
        }
    }

    try ctx.setSlot("", shortcoded);

    // Phase 3: layout resolution and rendering
    const style_name = cascade.resolveStyle(entry, scan_result, base_ctx) orelse "default";
    const style_path = try std.fmt.allocPrint(a, "styles.{s}", .{style_name});
    defer a.free(style_path);
    if (ctx.resolve(style_path)) |style_val|
        try ctx.putAt("document.style", style_val);
    const layout_short = layout_override orelse
        cascade.resolveLayout(entry, scan_result, base_ctx) orelse
        base_ctx.resolveString("document.layout") orelse "page.html";
    try ctx.putAt("document.layout", .{ .string = try a.dupe(u8, layout_short) });

    const layout_name = resolveLayoutPath(a, layout_short, style_name) catch {
        try diags.errFmt(a, "invalid layout path '{s}' for page {s}", .{ layout_short, entry.source_path });
        return error.BuildFailed;
    };

    const style_loader = template_loader.StyleLoader{
        .templates = template_map,
        .style_name = style_name,
    };
    const loader = style_loader.loader();

    var err_detail: toupee.ErrorDetail = .{};
    ctx.err_detail = &err_detail;

    const output_html = engine.renderTemplate(a, layout_name, &ctx, loader, .{}) catch |err| blk: {
        if (err != error.TemplateNotFound) {
            try recordRenderError(a, diags, &err_detail, entry.source_path, layout_name);
            return error.BuildFailed;
        }
        const src = (loader.getSource(a, layout_name) catch {
            try diags.errAt(
                a,
                try std.fmt.allocPrint(a, "missing layout template '{s}'", .{layout_name}),
                entry.source_path,
                layout_name,
            );
            return error.BuildFailed;
        }) orelse {
            try diags.errAt(
                a,
                try std.fmt.allocPrint(a, "missing layout template '{s}'", .{layout_name}),
                entry.source_path,
                layout_name,
            );
            return error.BuildFailed;
        };
        defer a.free(src);
        break :blk engine.render(a, src, &ctx, loader, .{}) catch {
            try recordRenderError(a, diags, &err_detail, entry.source_path, layout_name);
            return error.BuildFailed;
        };
    };

    return .{
        .output_html = output_html,
        .search_content = search_content,
    };
}

/// Records a Toupee render error in the build diagnostic collector.
fn recordRenderError(
    a: Allocator,
    diags: *diagnostics_mod.Collector,
    ed: *const toupee.ErrorDetail,
    page_source: []const u8,
    layout: []const u8,
) !void {
    const msg = if (ed.kind == .none)
        try std.fmt.allocPrint(a, "render error (no detail available)", .{})
    else
        ed.formatError(a) catch try a.dupe(u8, ed.message);
    try diags.errAt(a, msg, page_source, layout);
}

/// Resolves a short layout name to the full template path within a style.
fn resolveLayoutPath(a: Allocator, layout_short: []const u8, style_name: []const u8) ![]const u8 {
    const path = blk: {
        if (std.mem.indexOf(u8, layout_short, ":")) |colon_pos| {
            const s = layout_short[0..colon_pos];
            const p = layout_short[colon_pos + 1 ..];
            break :blk try std.fmt.allocPrint(a, "{s}/templates/{s}", .{ s, p });
        }
        if (std.mem.indexOf(u8, layout_short, "/") != null) {
            break :blk try std.fmt.allocPrint(a, "{s}/templates/{s}", .{ style_name, layout_short });
        }
        break :blk try std.fmt.allocPrint(a, "{s}/templates/layouts/{s}", .{ style_name, layout_short });
    };
    defer a.free(path);
    return try a.dupe(u8, path);
}

pub const PaginateConfig = @import("page_meta.zig").PaginateConfig;

/// Resolves a collection from context by dot-path (e.g. "pages.posts").
fn resolveCollection(ctx: *const toupee.Context, path: []const u8) ?[]const toupee.Value {
    const resolved = ctx.resolve(path) orelse return null;
    if (resolved == .list) return resolved.list;
    if (resolved == .map) {
        if (resolved.map.get("items")) |iv| {
            if (iv == .list) return iv.list;
        }
    }
    return null;
}

/// Resolves a collection for a specific page. When the collection path starts
/// with "document.style.", rewrites the path to use the page's resolved style
/// name so paths like `document.style.patterns.all` map to
/// `styles.{resolved_name}.patterns.all` in the base context.
fn resolveCollectionForPage(
    a: Allocator,
    base_ctx: *const toupee.Context,
    collection_path: []const u8,
    page: *const scanner_mod.PageEntry,
    scan_result: *const scanner_mod.ScanResult,
) ?[]const toupee.Value {
    const prefix = "document.style.";
    if (!std.mem.startsWith(u8, collection_path, prefix)) {
        return resolveCollection(@constCast(base_ctx), collection_path);
    }
    const style_name = cascade.resolveStyle(page, scan_result, base_ctx) orelse "default";
    const suffix = collection_path[prefix.len..];
    const rewritten = std.fmt.allocPrint(a, "styles.{s}.{s}", .{ style_name, suffix }) catch return null;
    defer a.free(rewritten);
    return resolveCollection(@constCast(base_ctx), rewritten);
}

/// Converts a pagination URL path (e.g. "/posts/", "/posts/page/2/") to output file path.
fn paginateUrlPathToFile(a: Allocator, url_path: []const u8) ![]const u8 {
    var trimmed = url_path;
    if (trimmed.len > 0 and trimmed[0] == '/') trimmed = trimmed[1..];
    if (trimmed.len > 0 and trimmed[trimmed.len - 1] == '/') trimmed = trimmed[0 .. trimmed.len - 1];
    if (trimmed.len == 0) return try a.dupe(u8, "index.html");
    return try std.fmt.allocPrint(a, "{s}/index.html", .{trimmed});
}

/// Renders all pages sequentially. Parallel rendering (thread pool)
/// is deferred to a later step. Pages with paginate config produce multiple output files.
pub fn renderAll(
    a: Allocator,
    scan_result: *const scanner_mod.ScanResult,
    engine: *const toupee.Engine,
    base_ctx: *const toupee.Context,
    template_map: *const std.StringArrayHashMapUnmanaged([]const u8),
    content_parsers: []const ContentParserEntry,
    transform_registry: *const toupee.transform.Registry,
    io: std.Io,
    output_dir: std.Io.Dir,
    diags: *diagnostics_mod.Collector,
) ![]RenderResult {
    const all_pages = scan_result.pages;
    const results = try a.alloc(RenderResult, all_pages.len);

    for (all_pages, 0..) |*page, i| {
        const paginate_cfg = page.meta.paginate;

        if (paginate_cfg != null and page.is_section) {
            const cfg = paginate_cfg.?;
            const items = resolveCollectionForPage(a, base_ctx, cfg.collection, page, scan_result) orelse {
                results[i] = try renderOne(a, page, engine, base_ctx, template_map, content_parsers, transform_registry, scan_result, diags);
                std.Io.Dir.createDirPath(output_dir, io, std.fs.path.dirname(page.output_file) orelse ".") catch {};
                var f = try std.Io.Dir.createFile(output_dir, io, page.output_file, .{});
                defer f.close(io);
                try f.writeStreamingAll(io, results[i].output_html);
                continue;
            };

            const base_path = page.url_path;
            const chunks = if (cfg.slug) |slug_field|
                try paginateBySlug(a, items, base_path, slug_field)
            else
                try paginate(a, items, cfg.size, base_path, cfg.path);
            defer a.free(chunks);

            // When slug pagination has a layout override, also render the
            // section index page using the page's own layout (e.g. a shell
            // with sidebar navigation) before generating the sub-pages.
            const has_index = cfg.slug != null and cfg.layout != null;
            if (has_index) {
                const index_result = try renderOne(a, page, engine, base_ctx, template_map, content_parsers, transform_registry, scan_result, diags);
                std.Io.Dir.createDirPath(output_dir, io, std.fs.path.dirname(page.output_file) orelse ".") catch {};
                var idx_f = try std.Io.Dir.createFile(output_dir, io, page.output_file, .{});
                defer idx_f.close(io);
                try idx_f.writeStreamingAll(io, index_result.output_html);
                results[i] = index_result;
            }

            var first_result: ?RenderResult = null;
            for (chunks) |chunk| {
                const result = try renderPage(a, page, chunk, cfg.layout, engine, base_ctx, template_map, content_parsers, transform_registry, scan_result, diags);
                const file_path = try paginateUrlPathToFile(a, chunk.output_path);
                defer a.free(file_path);
                std.Io.Dir.createDirPath(output_dir, io, std.fs.path.dirname(file_path) orelse ".") catch {};
                var f = try std.Io.Dir.createFile(output_dir, io, file_path, .{});
                defer f.close(io);
                try f.writeStreamingAll(io, result.output_html);
                if (first_result == null) first_result = result;
            }
            if (!has_index) {
                results[i] = first_result.?;
            }
        } else {
            const result = try renderOne(a, page, engine, base_ctx, template_map, content_parsers, transform_registry, scan_result, diags);
            std.Io.Dir.createDirPath(output_dir, io, std.fs.path.dirname(page.output_file) orelse ".") catch {};
            var f = try std.Io.Dir.createFile(output_dir, io, page.output_file, .{});
            defer f.close(io);
            try f.writeStreamingAll(io, result.output_html);
            results[i] = result;
        }
    }

    return results;
}

/// Resolves `{{ variable }}` interpolations in content using the given context.
/// Supports `{{ path }}` and `{{ path | transform }}` / `{{ path | transform:arg }}`.
/// Runs before content parsing (zjot) so Djot links get resolved URLs.
/// Emits a diagnostic error for unresolvable paths instead of silently producing empty strings.
fn resolveInterpolations(
    a: Allocator,
    content: []const u8,
    ctx: *const toupee.Context,
    transform_registry: *const toupee.transform.Registry,
    source_path: []const u8,
    diags: *diagnostics_mod.Collector,
) ![]const u8 {
    var out = std.ArrayListUnmanaged(u8).empty;
    defer out.deinit(a);
    var pos: usize = 0;

    while (std.mem.indexOfPos(u8, content, pos, "{{")) |open| {
        try out.appendSlice(a, content[pos..open]);
        pos = open + 2;

        const close = std.mem.indexOfPos(u8, content, pos, "}}") orelse {
            try out.appendSlice(a, "{{");
            pos = open + 2;
            continue;
        };

        var inner = std.mem.trim(u8, content[pos..close], " \t\n\r");
        pos = close + 2;

        // Split on | for transforms (e.g. {{ x | upper }} or {{ x | date:%B %e, %Y }})
        const pipe = std.mem.indexOf(u8, inner, "|");
        const path = if (pipe) |p| std.mem.trim(u8, inner[0..p], " \t\n\r") else inner;

        const resolved = ctx.resolve(path) orelse {
            try diags.errFmt(a, "unresolved interpolation: {{{{ {s} }}}} in {s}", .{ path, source_path });
            return error.BuildFailed;
        };

        const str_val = try resolved.toStringValue(a) orelse {
            try diags.errFmt(a, "non-string interpolation: {{{{ {s} }}}} in {s}", .{ path, source_path });
            return error.BuildFailed;
        };

        if (pipe) |p| {
            var transform_part = std.mem.trim(u8, inner[p + 1 ..], " \t\n\r");
            const colon = std.mem.indexOf(u8, transform_part, ":");
            const tname = if (colon) |c| transform_part[0..c] else transform_part;
            const targs = if (colon) |c| blk: {
                const arg_str = std.mem.trim(u8, transform_part[c + 1 ..], " \t\n\r");
                const arg_slice = try a.alloc([]const u8, 1);
                arg_slice[0] = arg_str;
                break :blk arg_slice;
            } else &[_][]const u8{};

            defer if (colon != null) a.free(targs);

            if (transform_registry.get(tname)) |tfn| {
                const transformed = tfn(a, str_val, targs) catch {
                    try out.appendSlice(a, str_val);
                    continue;
                };
                defer a.free(transformed);
                try out.appendSlice(a, transformed);
            } else {
                try out.appendSlice(a, str_val);
            }
        } else {
            try out.appendSlice(a, str_val);
        }
    }
    try out.appendSlice(a, content[pos..]);
    return try out.toOwnedSlice(a);
}

/// Dispatches content to the appropriate parser by file extension.
/// `.html` files are pass-through (no parsing).
fn parseContent(
    a: Allocator,
    content: []const u8,
    extension: []const u8,
    parsers: []const ContentParserEntry,
) ![]const u8 {
    if (std.mem.eql(u8, extension, ".html")) return try a.dupe(u8, content);

    for (parsers) |parser| {
        if (std.mem.eql(u8, extension, parser.extension)) {
            return try parser.parse(a, content);
        }
    }

    return error.UnrecognisedExtension;
}

/// Extracts excerpt: frontmatter `description:` overrides, otherwise
/// first `<p>...</p>` from content HTML with inner tags stripped.
pub fn extractExcerptPublic(a: Allocator, fm: toupee.Value, content: []const u8) ?[]const u8 {
    return extractExcerpt(a, fm, content);
}

fn extractExcerpt(a: Allocator, fm: toupee.Value, content: []const u8) ?[]const u8 {
    if (fm == .map) {
        if (fm.map.get("document")) |doc_val| {
            if (doc_val == .map) {
                if (doc_val.map.get("description")) |desc| {
                    if (desc == .string) return desc.string;
                }
            }
        }
    }

    const p_start = std.mem.indexOf(u8, content, "<p>") orelse return null;
    const text_start = p_start + 3;
    const p_end = std.mem.indexOfPos(u8, content, text_start, "</p>") orelse return null;
    return html.stripTags(a, content[text_start..p_end]) catch return null;
}

/// Splits a collection into paginated chunks and builds pagination context.
/// Returns one PaginationChunk per page (at least one, even for empty collections).
pub fn paginate(
    a: Allocator,
    items: []const toupee.Value,
    page_size: usize,
    base_path: []const u8,
    path_prefix: []const u8,
) ![]PaginationChunk {
    const size = if (page_size == 0) items.len else page_size;
    const total_pages = if (items.len == 0) 1 else (items.len + size - 1) / size;

    const chunks = try a.alloc(PaginationChunk, total_pages);
    for (0..total_pages) |i| {
        const start = i * size;
        const end = @min(start + size, items.len);
        const page_items = if (start < items.len) items[start..end] else &[_]toupee.Value{};
        const page_num = i + 1;

        const page_path = if (i == 0)
            try a.dupe(u8, base_path)
        else
            try std.fmt.allocPrint(a, "{s}{s}/{d}/", .{ base_path, path_prefix, page_num });

        var ctx_map = ValueMap{};
        try ctx_map.put(a, "items", .{ .list = page_items });
        try ctx_map.put(a, "page", .{ .integer = @intCast(page_num) });
        try ctx_map.put(a, "total_pages", .{ .integer = @intCast(total_pages) });

        if (i > 0) {
            var prev = ValueMap{};
            const prev_path = if (i == 1)
                try a.dupe(u8, base_path)
            else
                try std.fmt.allocPrint(a, "{s}{s}/{d}/", .{ base_path, path_prefix, i });
            try prev.put(a, "url", .{ .string = prev_path });
            try prev.put(a, "page", .{ .integer = @intCast(i) });
            try ctx_map.put(a, "previous", .{ .map = prev });
        }

        if (i < total_pages - 1) {
            var next = ValueMap{};
            const next_path = try std.fmt.allocPrint(a, "{s}{s}/{d}/", .{ base_path, path_prefix, page_num + 1 });
            try next.put(a, "url", .{ .string = next_path });
            try next.put(a, "page", .{ .integer = @intCast(page_num + 1) });
            try ctx_map.put(a, "next", .{ .map = next });
        }

        chunks[i] = .{
            .items = page_items,
            .context = .{ .map = ctx_map },
            .output_path = page_path,
        };
    }

    return chunks;
}

/// Splits a collection into one chunk per item, using a named field from each
/// item as the URL slug instead of a numeric page index.
/// Each chunk contains exactly one item and its URL is `{base_path}{slug}/`.
pub fn paginateBySlug(
    a: Allocator,
    items: []const toupee.Value,
    base_path: []const u8,
    slug_field: []const u8,
) ![]PaginationChunk {
    const total = if (items.len == 0) 1 else items.len;
    const chunks = try a.alloc(PaginationChunk, total);

    if (items.len == 0) {
        var ctx_map = ValueMap{};
        try ctx_map.put(a, "items", .{ .list = &[_]toupee.Value{} });
        try ctx_map.put(a, "page", .{ .integer = 1 });
        try ctx_map.put(a, "total_pages", .{ .integer = 1 });
        chunks[0] = .{
            .items = &[_]toupee.Value{},
            .context = .{ .map = ctx_map },
            .output_path = try a.dupe(u8, base_path),
        };
        return chunks;
    }

    for (items, 0..) |item, i| {
        const slug = switch (item) {
            .map => |m| blk: {
                const v = m.get(slug_field) orelse break :blk slug_field;
                break :blk switch (v) {
                    .string => |s| s,
                    else => slug_field,
                };
            },
            else => slug_field,
        };

        const page_path = try std.fmt.allocPrint(a, "{s}{s}/", .{ base_path, slug });
        const single = try a.alloc(toupee.Value, 1);
        single[0] = item;

        var ctx_map = ValueMap{};
        try ctx_map.put(a, "items", .{ .list = single });
        try ctx_map.put(a, "page", .{ .integer = @intCast(i + 1) });
        try ctx_map.put(a, "total_pages", .{ .integer = @intCast(total) });
        try ctx_map.put(a, "slug", .{ .string = slug });

        if (i > 0) {
            const prev_item = items[i - 1];
            const prev_slug = switch (prev_item) {
                .map => |m| blk: {
                    const v = m.get(slug_field) orelse break :blk slug_field;
                    break :blk switch (v) {
                        .string => |s| s,
                        else => slug_field,
                    };
                },
                else => slug_field,
            };
            var prev = ValueMap{};
            try prev.put(a, "url", .{ .string = try std.fmt.allocPrint(a, "{s}{s}/", .{ base_path, prev_slug }) });
            try prev.put(a, "page", .{ .integer = @intCast(i) });
            try ctx_map.put(a, "previous", .{ .map = prev });
        }

        if (i < total - 1) {
            const next_item = items[i + 1];
            const next_slug = switch (next_item) {
                .map => |m| blk: {
                    const v = m.get(slug_field) orelse break :blk slug_field;
                    break :blk switch (v) {
                        .string => |s| s,
                        else => slug_field,
                    };
                },
                else => slug_field,
            };
            var next = ValueMap{};
            try next.put(a, "url", .{ .string = try std.fmt.allocPrint(a, "{s}{s}/", .{ base_path, next_slug }) });
            try next.put(a, "page", .{ .integer = @intCast(i + 2) });
            try ctx_map.put(a, "next", .{ .map = next });
        }

        chunks[i] = .{
            .items = single,
            .context = .{ .map = ctx_map },
            .output_path = page_path,
        };
    }

    return chunks;
}

pub const PaginationChunk = struct {
    items: []const toupee.Value,
    context: toupee.Value,
    output_path: []const u8,
};

pub fn getDocTitle(fm: toupee.Value) ?[]const u8 {
    if (fm != .map) return null;
    if (fm.map.get("document")) |doc_val| {
        if (doc_val == .map) {
            if (doc_val.map.get("title")) |title_val| {
                if (title_val == .string) return title_val.string;
            }
        }
    }
    return null;
}


/// `toupee.Context.initFrom` shallow-copies top-level keys; the nested `document` map is the same
/// storage as in `base_ctx`. Per-page `putAt("document.*", …)` would mutate site-wide defaults and
/// break later `base_ctx.resolveString("document.layout")` across renders. Replace `document` in
/// `ctx` with a shallow clone (string values duped; keys duped).
fn detachPerPageDocumentMap(a: Allocator, ctx: *toupee.Context, base_ctx: *const toupee.Context) !void {
    const doc_val = base_ctx.resolve("document") orelse return;
    if (doc_val != .map) return;
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
    try ctx.put("document", .{ .map = clone });
}

// ── Tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

fn mockParser(_: Allocator, source: []const u8) anyerror![]const u8 {
    return source;
}

test "parseContent: html pass-through" {
    const a = testing.allocator;
    const result = try parseContent(a, "<p>Hello</p>", ".html", &.{});
    defer a.free(result);
    try testing.expectEqualStrings("<p>Hello</p>", result);
}

test "parseContent: dispatches to registered parser" {
    const a = testing.allocator;
    const parsers = [_]ContentParserEntry{
        .{ .extension = ".dj", .parse = mockParser },
    };
    const result = try parseContent(a, "djot content", ".dj", &parsers);
    try testing.expectEqualStrings("djot content", result);
}

test "parseContent: unrecognised extension" {
    const result = parseContent(testing.allocator, "content", ".rst", &.{});
    try testing.expectError(error.UnrecognisedExtension, result);
}

test "extractExcerpt: from first paragraph" {
    const a = testing.allocator;
    const fm_empty: ValueMap = .{};
    const excerpt = extractExcerpt(a, .{ .map = fm_empty }, "<h1>Title</h1><p>First paragraph.</p><p>Second.</p>");
    defer a.free(excerpt.?);
    try testing.expectEqualStrings("First paragraph.", excerpt.?);
}

test "extractExcerpt: strips inner tags from paragraph" {
    const a = testing.allocator;
    const fm_empty: ValueMap = .{};
    const excerpt = extractExcerpt(a, .{ .map = fm_empty }, "<h1>Title</h1><p>Hello <em>world</em></p>");
    defer a.free(excerpt.?);
    try testing.expectEqualStrings("Hello world", excerpt.?);
}

test "extractExcerpt: frontmatter description overrides" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = ValueMap{};
    try doc.put(a, "description", .{ .string = "Custom description" });
    var map: ValueMap = .{};
    try map.put(a, "document", .{ .map = doc });

    const excerpt = extractExcerpt(a, .{ .map = map }, "<p>Ignored.</p>");
    try testing.expectEqualStrings("Custom description", excerpt.?);
}

test "extractExcerpt: no paragraphs returns null" {
    const fm_empty: ValueMap = .{};
    const excerpt = extractExcerpt(testing.allocator, .{ .map = fm_empty }, "<h1>Title only</h1>");
    try testing.expect(excerpt == null);
}

test "paginate: splits into correct chunks" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const items = [_]toupee.Value{
        .{ .string = "a" }, .{ .string = "b" }, .{ .string = "c" },
        .{ .string = "d" }, .{ .string = "e" },
    };

    const chunks = try paginate(a, &items, 2, "/posts/", "page");
    try testing.expectEqual(@as(usize, 3), chunks.len);

    try testing.expectEqual(@as(usize, 2), chunks[0].items.len);
    try testing.expectEqual(@as(usize, 2), chunks[1].items.len);
    try testing.expectEqual(@as(usize, 1), chunks[2].items.len);

    try testing.expectEqual(@as(i64, 1), chunks[0].context.map.get("page").?.integer);
    try testing.expectEqual(@as(i64, 3), chunks[0].context.map.get("total_pages").?.integer);
}

test "paginate: empty collection produces 1 page" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const chunks = try paginate(a, &.{}, 5, "/posts/", "page");
    try testing.expectEqual(@as(usize, 1), chunks.len);
    try testing.expectEqual(@as(usize, 0), chunks[0].items.len);
    try testing.expectEqual(@as(i64, 1), chunks[0].context.map.get("total_pages").?.integer);
}

test "paginate: previous/next links" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const items = [_]toupee.Value{
        .{ .string = "a" }, .{ .string = "b" }, .{ .string = "c" },
    };

    const chunks = try paginate(a, &items, 1, "/posts/", "page");
    try testing.expectEqual(@as(usize, 3), chunks.len);

    try testing.expect(chunks[0].context.map.get("previous") == null);
    try testing.expect(chunks[0].context.map.get("next") != null);

    try testing.expect(chunks[1].context.map.get("previous") != null);
    try testing.expect(chunks[1].context.map.get("next") != null);

    try testing.expect(chunks[2].context.map.get("previous") != null);
    try testing.expect(chunks[2].context.map.get("next") == null);
}

test "paginate: first page uses base path" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const items = [_]toupee.Value{ .{ .string = "a" }, .{ .string = "b" } };
    const chunks = try paginate(a, &items, 1, "/posts/", "page");

    try testing.expectEqualStrings("/posts/", chunks[0].output_path);
    try testing.expectEqualStrings("/posts/page/2/", chunks[1].output_path);
}

// Documents Toupee behaviour: `initFrom` copies `Value` by value; nested `.map` shares storage with parent.
test "Toupee initFrom: child putAt document.layout mutates parent document map" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var parent = toupee.Context.init(a);
    defer parent.deinit();
    var doc_map: ValueMap = .{};
    try doc_map.put(a, "layout", .{ .string = try a.dupe(u8, "base.html") });
    try parent.put("document", .{ .map = doc_map });

    var child = try toupee.Context.initFrom(a, &parent);
    defer child.deinit();
    try child.putAt("document.layout", .{ .string = try a.dupe(u8, "other.html") });

    try testing.expectEqualStrings("other.html", parent.resolveString("document.layout").?);
}

test "detachPerPageDocumentMap: child document.layout does not change base_ctx" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var parent = toupee.Context.init(a);
    defer parent.deinit();
    var doc_map: ValueMap = .{};
    try doc_map.put(a, "layout", .{ .string = try a.dupe(u8, "base.html") });
    try parent.put("document", .{ .map = doc_map });

    var child = try toupee.Context.initFrom(a, &parent);
    defer child.deinit();
    try detachPerPageDocumentMap(a, &child, &parent);
    try child.putAt("document.layout", .{ .string = try a.dupe(u8, "post.html") });

    try testing.expectEqualStrings("base.html", parent.resolveString("document.layout").?);
    try testing.expectEqualStrings("post.html", child.resolveString("document.layout").?);
}
