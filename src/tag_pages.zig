const std = @import("std");
const toupee = @import("toupee");
const scanner = @import("scanner.zig");
const config = @import("config.zig");
const taxonomies = @import("taxonomies.zig");
const pages = @import("pages.zig");
const template_loader = @import("template_loader.zig");

const Allocator = std.mem.Allocator;
const ValueMap = std.StringArrayHashMapUnmanaged(toupee.Value);
const StyleLoader = template_loader.StyleLoader;

fn tagPageValueFromEntry(a: Allocator, page: *const scanner.PageEntry) !toupee.Value {
    var page_map = ValueMap{};
    try page_map.put(a, "path", .{ .string = page.url_path });
    try page_map.put(a, "url", .{ .string = page.absolute_url });
    try page_map.put(a, "source", .{ .string = page.source_path });
    if (page.raw_frontmatter == .map) {
        var fm_it = page.raw_frontmatter.map.iterator();
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

/// Order documents on a tag page: fewer tags first (narrower topic), then path descending so
/// file walk order (/blog/a, …) does not dictate listing (spec: popularity-style sort).
fn tagTaggedPageLessThan(x: toupee.Value, y: toupee.Value) bool {
    const cx = taxonomies.getTerms(x, "tags") orelse &[_]toupee.Value{};
    const cy = taxonomies.getTerms(y, "tags") orelse &[_]toupee.Value{};
    if (cx.len != cy.len) return cx.len < cy.len;
    if (x != .map or y != .map) return false;
    const px = x.map.get("path") orelse return false;
    const py = y.map.get("path") orelse return true;
    if (px != .string or py != .string) return false;
    return std.mem.order(u8, px.string, py.string) == .gt;
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

/// Renders `/tags/` index, `/tags/{slug}/`, and `/tags/{a}/{b}/` intersection pages.
pub fn render(
    ba: Allocator,
    site_cfg: config.SiteConfig,
    style_name: []const u8,
    scan_result: *const scanner.ScanResult,
    engine: *toupee.Engine,
    base_ctx: *toupee.Context,
    template_map: *const std.StringArrayHashMapUnmanaged([]const u8),
    io: std.Io,
    output_dir: std.Io.Dir,
) !void {
    var want_tags = false;
    for (site_cfg.tags) |t| {
        if (std.mem.eql(u8, t, "tags")) {
            want_tags = true;
            break;
        }
    }
    if (!want_tags) return;

    const tax_val = base_ctx.resolve("tags") orelse return;
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
        tag_pages: []const toupee.Value,
    };

    var tag_infos: std.ArrayListUnmanaged(TagInfo) = .empty;
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
            .tag_pages = pg.list,
        });
    }

    std.mem.sort(TagInfo, tag_infos.items, {}, struct {
        fn lt(_: void, x: TagInfo, y: TagInfo) bool {
            if (x.tag_pages.len != y.tag_pages.len) return x.tag_pages.len > y.tag_pages.len;
            return std.mem.order(u8, x.slug, y.slug) == .lt;
        }
    }.lt);

    const list_vals = try ba.alloc(toupee.Value, tag_infos.items.len);
    for (tag_infos.items, list_vals) |info, *out| {
        var m = ValueMap{};
        const path_str = try std.fmt.allocPrint(ba, "/tags/{s}/", .{info.slug});
        try m.put(ba, "path", .{ .string = path_str });
        try m.put(ba, "name", .{ .string = info.name });
        try m.put(ba, "count", .{ .integer = @intCast(info.tag_pages.len) });
        out.* = .{ .map = m };
    }

    {
        var ctx = try toupee.Context.initFrom(ba, base_ctx);
        defer ctx.deinit();
        var wrap = ValueMap{};
        try wrap.put(ba, "tags", .{ .list = list_vals });
        try ctx.put("tag", .{ .map = wrap });
        const html_out = try engine.render(ba, tmpl_index, &ctx, sl.loader(), .{});
        defer ba.free(html_out);
        std.Io.Dir.createDirPath(output_dir, io, "tags") catch {};
        var f = try std.Io.Dir.createFile(output_dir, io, "tags/index.html", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, html_out);
    }

    for (tag_infos.items) |info| {
        var ctx = try toupee.Context.initFrom(ba, base_ctx);
        defer ctx.deinit();

        var doc_map = ValueMap{};
        try doc_map.put(ba, "title", .{ .string = info.name });
        var tag_wrap = ValueMap{};
        try tag_wrap.put(ba, "document", .{ .map = doc_map });
        const path_tags_str = try std.fmt.allocPrint(ba, "{s}", .{info.slug});
        try tag_wrap.put(ba, "path_tags", .{ .string = path_tags_str });

        var sorted_pages = try ba.alloc(toupee.Value, info.tag_pages.len);
        defer ba.free(sorted_pages);
        var sp_n: usize = 0;
        for (info.tag_pages) |pv| {
            if (pv != .map) continue;
            if (pv.map.get("path")) |pp| {
                if (pp != .string) continue;
            } else continue;
            sorted_pages[sp_n] = pv;
            sp_n += 1;
        }
        std.mem.sort(toupee.Value, sorted_pages[0..sp_n], {}, struct {
            fn lt(_: void, x: toupee.Value, y: toupee.Value) bool {
                return tagTaggedPageLessThan(x, y);
            }
        }.lt);

        const doc_items = try ba.alloc(toupee.Value, sp_n);
        for (sorted_pages[0..sp_n], doc_items) |pv, *out| {
            out.* = try wrapTagListDocumentItem(ba, pv);
        }
        try tag_wrap.put(ba, "documents", .{ .list = doc_items });
        try tag_wrap.put(ba, "tags", .{ .list = list_vals });
        try ctx.put("tag", .{ .map = tag_wrap });

        const html_out = try engine.render(ba, tmpl_list, &ctx, sl.loader(), .{});
        defer ba.free(html_out);
        const dir = try std.fmt.allocPrint(ba, "tags/{s}", .{info.slug});
        defer ba.free(dir);
        std.Io.Dir.createDirPath(output_dir, io, dir) catch {};
        const file_path = try std.fmt.allocPrint(ba, "{s}/index.html", .{dir});
        defer ba.free(file_path);
        var f = try std.Io.Dir.createFile(output_dir, io, file_path, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, html_out);
    }

    var pair_seen = std.StringArrayHashMapUnmanaged(void){};
    defer pair_seen.deinit(ba);

    for (scan_result.pages) |*page| {
        if (page.is_section) continue;
        const terms = taxonomies.getTerms(page.raw_frontmatter, "tags") orelse continue;
        var slug_buf: std.ArrayListUnmanaged([]const u8) = .empty;
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

        var match_pages: std.ArrayListUnmanaged(toupee.Value) = .empty;
        for (scan_result.pages) |*sp| {
            if (sp.is_section) continue;
            if (!try pageHasBothTagSlugs(sp.raw_frontmatter, a_slug, b_slug, ba)) continue;
            try match_pages.append(ba, try tagPageValueFromEntry(ba, sp));
        }
        if (match_pages.items.len == 0) continue;

        std.mem.sort(toupee.Value, match_pages.items, {}, struct {
            fn lt(_: void, x: toupee.Value, y: toupee.Value) bool {
                return tagTaggedPageLessThan(x, y);
            }
        }.lt);

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
        std.Io.Dir.createDirPath(output_dir, io, dir2) catch {};
        const fp2 = try std.fmt.allocPrint(ba, "{s}/index.html", .{dir2});
        defer ba.free(fp2);
        var f2 = try std.Io.Dir.createFile(output_dir, io, fp2, .{});
        defer f2.close(io);
        try f2.writeStreamingAll(io, html2);
    }
}

const testing = std.testing;

test "wrapTagListDocumentItem: wraps path and title" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var pm = ValueMap{};
    try pm.put(a, "path", .{ .string = "/posts/hello/" });
    var dm = ValueMap{};
    try dm.put(a, "title", .{ .string = "Hello World" });
    try pm.put(a, "document", .{ .map = dm });

    const result = try wrapTagListDocumentItem(a, .{ .map = pm });
    try testing.expect(result == .map);
    const doc = result.map.get("document") orelse return error.TestUnexpectedResult;
    try testing.expect(doc == .map);
    const path = doc.map.get("path") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("/posts/hello/", path.string);
    const title = doc.map.get("title") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("Hello World", title.string);
}
