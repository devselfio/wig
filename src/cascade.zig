const std = @import("std");
const toupee = @import("toupee");
const scanner_mod = @import("scanner.zig");
const page_meta_mod = @import("page_meta.zig");
const context_mod = @import("context.zig");

const Allocator = std.mem.Allocator;
const ValueMap = std.StringArrayHashMapUnmanaged(toupee.Value);

/// Walks the parent chain (closest ancestor first) looking for a typed cascade field.
/// Returns the first non-null value found, or null if no ancestor provides one.
fn getFromCascade(
    comptime field: []const u8,
    entry: *const scanner_mod.PageEntry,
    scan_result: *const scanner_mod.ScanResult,
) ?[]const u8 {
    var current_url = entry.url_path;
    while (scan_result.parent_map.get(current_url)) |parent_opt| {
        const parent = parent_opt orelse break;
        if (parent.meta.cascade) |cascade| {
            if (cascade.document) |doc_ovr| {
                if (@field(doc_ovr, field)) |v| return v;
            }
        }
        current_url = parent.url_path;
    }
    return null;
}

/// Resolves the layout for a page: page's own meta.layout, then ancestor cascade,
/// then base context (data/document.yaml). Sections skip the ancestor cascade
/// (their cascade applies to *children*, not themselves).
pub fn resolveLayout(
    entry: *const scanner_mod.PageEntry,
    scan_result: *const scanner_mod.ScanResult,
    base_ctx: *const toupee.Context,
) ?[]const u8 {
    if (entry.is_section) {
        return entry.meta.layout orelse
            base_ctx.resolveString("document.layout");
    }
    return getFromCascade("layout", entry, scan_result) orelse
        entry.meta.layout orelse
        base_ctx.resolveString("document.layout");
}

/// Resolves the style for a page (same precedence as layout).
pub fn resolveStyle(
    entry: *const scanner_mod.PageEntry,
    scan_result: *const scanner_mod.ScanResult,
    base_ctx: *const toupee.Context,
) ?[]const u8 {
    return getFromCascade("style", entry, scan_result) orelse
        entry.meta.style orelse blk: {
        const doc_val = base_ctx.resolve("document") orelse break :blk null;
        if (doc_val != .map) break :blk null;
        const style_val = doc_val.map.get("style") orelse break :blk null;
        if (style_val != .string) break :blk null;
        break :blk style_val.string;
    };
}

/// Merges cascade data from ancestor _index pages and the current page into template context.
/// Walks root-first so closest ancestor wins. Applies:
///   - `cascade.document.extra.*` → `document.*`
///   - `cascade.site.*` → `site.*`
pub fn applyCascadeToContext(
    a: Allocator,
    entry: *const scanner_mod.PageEntry,
    scan_result: *const scanner_mod.ScanResult,
    ctx: *toupee.Context,
) !void {
    var merged_doc = ValueMap{};
    var merged_site = ValueMap{};

    var ancestors: std.ArrayListUnmanaged(*const scanner_mod.PageEntry) = .{};
    defer ancestors.deinit(a);
    var current_url = entry.url_path;
    while (scan_result.parent_map.get(current_url)) |parent_opt| {
        const parent = parent_opt orelse break;
        try ancestors.append(a, parent);
        current_url = parent.url_path;
    }
    std.mem.reverse(*const scanner_mod.PageEntry, ancestors.items);

    for (ancestors.items) |ancestor| {
        try mergeOneCascade(a, ancestor.meta.cascade, ancestor.raw_frontmatter, &merged_doc, &merged_site);
    }
    try mergeOneCascade(a, entry.meta.cascade, entry.raw_frontmatter, &merged_doc, &merged_site);

    var doc_it = merged_doc.iterator();
    while (doc_it.next()) |e| {
        if (std.mem.eql(u8, e.key_ptr.*, "style") and e.value_ptr.* == .string) continue;
        const key = try std.fmt.allocPrint(a, "document.{s}", .{e.key_ptr.*});
        defer a.free(key);
        const val = e.value_ptr.*;
        const val_copy: toupee.Value = if (val == .string) .{ .string = try a.dupe(u8, val.string) } else val;
        try ctx.putAt(key, val_copy);
    }

    if (merged_site.count() > 0) {
        var site_map = ValueMap{};
        if (ctx.resolve("site")) |existing| {
            if (existing == .map) {
                var it = existing.map.iterator();
                while (it.next()) |e| {
                    try site_map.put(a, e.key_ptr.*, e.value_ptr.*);
                }
            }
        }
        var site_it = merged_site.iterator();
        while (site_it.next()) |e| {
            const val = e.value_ptr.*;
            const val_copy: toupee.Value = if (val == .string) .{ .string = try a.dupe(u8, val.string) } else val;
            try site_map.put(a, e.key_ptr.*, val_copy);
        }
        try ctx.put("site", .{ .map = site_map });
    }
}

/// Merges a single page's cascade data (from raw_frontmatter document.data) into
/// the accumulated document and site maps. Uses raw_frontmatter for the full
/// key set since CascadeData.document.extra only captures comb.Value, and
/// template context needs toupee.Value.
fn mergeOneCascade(
    a: Allocator,
    cascade: ?page_meta_mod.CascadeData,
    raw_fm: toupee.Value,
    merged_doc: *ValueMap,
    merged_site: *ValueMap,
) !void {
    _ = cascade;
    const data_val = getDocumentData(raw_fm) orelse return;
    if (data_val != .map) return;
    if (data_val.map.get("document")) |doc_val| {
        if (doc_val == .map) {
            var it = doc_val.map.iterator();
            while (it.next()) |e| {
                try merged_doc.put(a, e.key_ptr.*, e.value_ptr.*);
            }
        }
    }
    if (data_val.map.get("site")) |site_val| {
        if (site_val == .map) {
            var it = site_val.map.iterator();
            while (it.next()) |e| {
                try merged_site.put(a, e.key_ptr.*, e.value_ptr.*);
            }
        }
    }
}

fn getDocumentData(fm: toupee.Value) ?toupee.Value {
    if (fm != .map) return null;
    const doc_val = fm.map.get("document") orelse return null;
    if (doc_val != .map) return null;
    return doc_val.map.get("data");
}

const testing = std.testing;

fn testPageEntry(url: []const u8, meta: page_meta_mod.PageMeta) scanner_mod.PageEntry {
    return .{
        .source_path = "",
        .output_file = "",
        .url_path = url,
        .absolute_url = "",
        .content_body = "",
        .extension = ".dj",
        .raw_frontmatter = .{ .string = "" },
        .collection_key = "pages",
        .meta = meta,
    };
}

test "resolveLayout: page meta wins over base context" {
    const a = testing.allocator;
    var child = testPageEntry("/about/", .{ .layout = "custom.html" });

    var parent_map = std.StringArrayHashMapUnmanaged(?*const scanner_mod.PageEntry){};
    try parent_map.put(a, "/about/", null);
    defer parent_map.deinit(a);

    const scan = scanner_mod.ScanResult{
        .pages = &.{},
        .collections = .{},
        .parent_map = parent_map,
        .children_map = .{},
        .arena = std.heap.ArenaAllocator.init(a),
    };

    var base = toupee.Context.init(a);
    defer base.deinit();
    try base.putAt("document.layout", .{ .string = "default.html" });

    const result = resolveLayout(&child, &scan, &base);
    try testing.expectEqualStrings("custom.html", result.?);
}

test "resolveStyle: falls back to base context" {
    const a = testing.allocator;
    var child = testPageEntry("/about/", .{});

    var parent_map = std.StringArrayHashMapUnmanaged(?*const scanner_mod.PageEntry){};
    try parent_map.put(a, "/about/", null);
    defer parent_map.deinit(a);

    const scan = scanner_mod.ScanResult{
        .pages = &.{},
        .collections = .{},
        .parent_map = parent_map,
        .children_map = .{},
        .arena = std.heap.ArenaAllocator.init(a),
    };

    var doc_map = ValueMap{};
    try doc_map.put(a, "style", .{ .string = "default" });
    defer doc_map.deinit(a);
    var base = toupee.Context.init(a);
    defer base.deinit();
    try base.put("document", .{ .map = doc_map });

    const result = resolveStyle(&child, &scan, &base);
    try testing.expectEqualStrings("default", result.?);
}
