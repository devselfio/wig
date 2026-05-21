const std = @import("std");
const toupee = @import("toupee");
const scanner_mod = @import("scanner.zig");

const Allocator = std.mem.Allocator;
const fs = std.fs;
const PageEntry = scanner_mod.PageEntry;
const ValueMap = std.StringArrayHashMapUnmanaged(toupee.Value);

/// Builds a single page value with path, url, source, and merged document (path + frontmatter).
pub fn buildPageValue(a: Allocator, page: *const PageEntry) !toupee.Value {
    var page_map = ValueMap{};
    try page_map.put(a, "path", .{ .string = page.url_path });
    try page_map.put(a, "url", .{ .string = page.absolute_url });
    try page_map.put(a, "source", .{ .string = page.source_path });

    var doc_map = ValueMap{};
    try doc_map.put(a, "path", .{ .string = page.url_path });
    try doc_map.put(a, "url", .{ .string = page.absolute_url });
    if (page.raw_frontmatter == .map) {
        if (page.raw_frontmatter.map.get("document")) |doc_val| {
            if (doc_val == .map) {
                var doc_it = doc_val.map.iterator();
                while (doc_it.next()) |doc_entry| {
                    try doc_map.put(a, doc_entry.key_ptr.*, doc_entry.value_ptr.*);
                }
            }
        }
    }
    try page_map.put(a, "document", .{ .map = doc_map });
    return .{ .map = page_map };
}

/// Builds a single nested `pages` map for template context.
///
/// - Root entries (`collection_key == "pages"`): slugs `document` (_index), `two`, etc.
/// - Subfolders (`pages.posts`, `pages.blog`, …): map with `document` (section _index),
///   `items` (sorted leaf list for `<t-for>` / paginate), plus one key per leaf slug.
/// Section pages are excluded from `items` lists only; they appear as `document` on the folder map.
pub fn buildCollections(
    a: Allocator,
    pages: []const PageEntry,
    collections: *ValueMap,
) !void {
    var buckets = std.StringArrayHashMapUnmanaged(std.ArrayListUnmanaged(toupee.Value)){};

    for (pages) |page| {
        if (page.is_section) continue;

        const key = page.collection_key;
        var list = if (buckets.get(key)) |l| l else std.ArrayListUnmanaged(toupee.Value).empty;

        const page_val = try buildPageValue(a, &page);
        try list.append(a, page_val);
        try buckets.put(a, key, list);
    }

    var bucket_it = buckets.iterator();
    while (bucket_it.next()) |entry| {
        std.mem.sort(toupee.Value, entry.value_ptr.items, {}, struct {
            fn cmp(_: void, lhs: toupee.Value, rhs: toupee.Value) bool {
                const l_src = if (lhs == .map) (lhs.map.get("source") orelse return false) else return false;
                const r_src = if (rhs == .map) (rhs.map.get("source") orelse return true) else return true;
                const l_str = if (l_src == .string) l_src.string else return false;
                const r_str = if (r_src == .string) r_src.string else return true;
                return std.mem.order(u8, l_str, r_str) == .gt;
            }
        }.cmp);
    }

    var pages_root = ValueMap{};

    for (pages) |page| {
        if (!std.mem.eql(u8, page.collection_key, "pages")) continue;
        const page_val = try buildPageValue(a, &page);
        const slug = if (page.is_section) "document" else blk: {
            const stem = std.fs.path.stem(page.source_path);
            break :blk stem;
        };
        try pages_root.put(a, try a.dupe(u8, slug), page_val);
    }

    var nested_keys = std.ArrayListUnmanaged([]const u8).empty;
    defer nested_keys.deinit(a);
    {
        var bit = buckets.iterator();
        while (bit.next()) |e| {
            const pkey = e.key_ptr.*;
            if (!std.mem.startsWith(u8, pkey, "pages.")) continue;
            const rest = pkey["pages.".len..];
            if (rest.len == 0) continue;
            try nested_keys.append(a, pkey);
        }
    }

    std.mem.sort([]const u8, nested_keys.items, {}, struct {
        fn dotCount(s: []const u8) usize {
            var n: usize = 0;
            for (s) |c| {
                if (c == '.') n += 1;
            }
            return n;
        }
        fn lessThan(_: void, ak: []const u8, bk: []const u8) bool {
            const ar = ak["pages.".len..];
            const br = bk["pages.".len..];
            const ca = dotCount(ar);
            const cb = dotCount(br);
            if (ca != cb) return ca > cb;
            return std.mem.order(u8, ar, br) == .lt;
        }
    }.lessThan);

    for (nested_keys.items) |pkey| {
        const bucket_list = buckets.getPtr(pkey) orelse continue;
        const items = try a.dupe(toupee.Value, bucket_list.items);
        const rest = pkey["pages.".len..];
        const segments = try splitDotSegments(a, rest);
        defer a.free(segments);

        const rel_prefix = try std.mem.join(a, "/", segments);
        defer a.free(rel_prefix);

        const section_page = findSectionByRelPrefix(pages, rel_prefix);

        var sub_map = ValueMap{};
        if (section_page) |sp| {
            try sub_map.put(a, "document", try buildPageValue(a, sp));
        }
        try sub_map.put(a, "items", .{ .list = items });

        for (items) |pv| {
            if (pv != .map) continue;
            const src_val = pv.map.get("source") orelse continue;
            if (src_val != .string) continue;
            const slug = slugFromSourceUnderPrefix(src_val.string, rel_prefix) orelse continue;
            try sub_map.put(a, try a.dupe(u8, slug), pv);
        }

        try mergeNestedLeaf(a, &pages_root, segments, sub_map);
    }

    if (pages_root.count() > 0) {
        try collections.put(a, "pages", .{ .map = pages_root });
    }
}

fn splitDotSegments(alloc: Allocator, rest: []const u8) Allocator.Error![][]const u8 {
    var n: usize = 1;
    for (rest) |c| {
        if (c == '.') n += 1;
    }
    const out = try alloc.alloc([]const u8, n);
    var idx: usize = 0;
    var start: usize = 0;
    for (rest, 0..) |c, i| {
        if (c == '.') {
            out[idx] = rest[start..i];
            idx += 1;
            start = i + 1;
        }
    }
    out[idx] = rest[start..];
    return out;
}

fn sectionRelPrefixForSource(source_path: []const u8) ?[]const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, source_path, '/');
    const file = if (slash) |s| source_path[s + 1 ..] else source_path;
    const ext = fs.path.extension(file);
    if (file.len < ext.len) return null;
    const stem = file[0 .. file.len - ext.len];
    if (!std.mem.eql(u8, stem, "_index")) return null;
    if (slash) |s| return source_path[0..s] else return "";
}

fn findSectionByRelPrefix(page_list: []const PageEntry, rel_prefix: []const u8) ?*const PageEntry {
    for (page_list) |*p| {
        if (!p.is_section) continue;
        const sp = sectionRelPrefixForSource(p.source_path) orelse continue;
        if (std.mem.eql(u8, sp, rel_prefix)) return p;
    }
    return null;
}

fn slugFromSourceUnderPrefix(source: []const u8, rel_prefix: []const u8) ?[]const u8 {
    if (rel_prefix.len == 0) {
        if (std.mem.indexOfScalar(u8, source, '/') != null) return null;
        return std.fs.path.stem(source);
    }
    if (source.len < rel_prefix.len + 2) return null;
    if (!std.mem.startsWith(u8, source, rel_prefix)) return null;
    if (source[rel_prefix.len] != '/') return null;
    const rest = source[rel_prefix.len + 1 ..];
    if (std.mem.indexOfScalar(u8, rest, '/') != null) return null;
    return std.fs.path.stem(rest);
}

fn ensureChildMap(a: Allocator, parent: *ValueMap, seg: []const u8) !*ValueMap {
    const seg_key = try a.dupe(u8, seg);
    if (parent.getPtr(seg_key)) |vp| {
        if (vp.* != .map) return error.PathConflict;
        return &vp.map;
    }
    try parent.put(a, seg_key, .{ .map = .{} });
    return &parent.getPtr(seg_key).?.map;
}

fn mergeNestedLeaf(a: Allocator, root: *ValueMap, segments: []const []const u8, leaf: ValueMap) !void {
    if (segments.len == 0) return error.InvalidArgument;
    var cur: *ValueMap = root;
    for (segments[0 .. segments.len - 1]) |seg| {
        cur = try ensureChildMap(a, cur, seg);
    }
    const last_seg = segments[segments.len - 1];
    const last_key = try a.dupe(u8, last_seg);
    if (cur.getPtr(last_key)) |vp| {
        if (vp.* != .map) return error.PathConflict;
        var it = leaf.iterator();
        while (it.next()) |e| {
            const k = try a.dupe(u8, e.key_ptr.*);
            const v = e.value_ptr.*;
            const vcopy: toupee.Value = if (v == .string) .{ .string = try a.dupe(u8, v.string) } else v;
            try vp.map.put(a, k, vcopy);
        }
        return;
    }
    try cur.put(a, last_key, .{ .map = leaf });
}

/// URL path of parent directory. "/docs/alpha/" -> "/docs/", "/docs/" -> "/", "/" -> empty.
pub fn urlPathParent(url_path: []const u8) []const u8 {
    if (url_path.len <= 1) return "";
    var end = url_path.len;
    while (end > 1 and url_path[end - 1] == '/') end -= 1;
    if (end <= 1) return "/";
    var idx = end - 1;
    while (idx > 0 and url_path[idx] != '/') idx -= 1;
    if (idx <= 0) return "/";
    return url_path[0 .. idx + 1];
}

/// Builds url_path -> parent page map for section hierarchy.
pub fn buildParentMap(a: Allocator, pages: []const PageEntry) !std.StringArrayHashMapUnmanaged(?*const PageEntry) {
    var url_to_page = std.StringArrayHashMapUnmanaged(*const PageEntry){};
    for (pages) |*p| try url_to_page.put(a, p.url_path, p);

    var parent_map = std.StringArrayHashMapUnmanaged(?*const PageEntry){};
    for (pages) |*p| {
        const parent_url = urlPathParent(p.url_path);
        const parent = if (parent_url.len == 0) null else url_to_page.get(parent_url);
        try parent_map.put(a, p.url_path, parent);
    }
    return parent_map;
}

/// Groups leaf pages (non-`_index`) by parent directory under `pages/`. Keys are arena-owned
/// copies; lookup uses `pagesParentDir(entry.source_path)` (slice into `source_path` matches by value).
pub fn buildChildrenMap(a: Allocator, pages: []const PageEntry) !std.StringArrayHashMapUnmanaged([]const *const PageEntry) {
    var children_lists = std.StringArrayHashMapUnmanaged(std.ArrayListUnmanaged(*const PageEntry)){};
    for (pages) |*p| {
        if (p.is_section) continue;
        const dir = scanner_mod.pagesParentDir(p.source_path);
        var list = children_lists.getPtr(dir) orelse blk: {
            const key = try a.dupe(u8, dir);
            const new_list = std.ArrayListUnmanaged(*const PageEntry).empty;
            try children_lists.put(a, key, new_list);
            break :blk children_lists.getPtr(key).?;
        };
        try list.append(a, p);
    }

    var children_map = std.StringArrayHashMapUnmanaged([]const *const PageEntry){};
    var it = children_lists.iterator();
    while (it.next()) |entry| {
        const slice = try a.dupe(*const PageEntry, entry.value_ptr.items);
        try children_map.put(a, entry.key_ptr.*, slice);
    }
    return children_map;
}

const testing = std.testing;

test "urlPathParent: nested path" {
    try testing.expectEqualStrings("/docs/", urlPathParent("/docs/alpha/"));
}

test "urlPathParent: root and edge cases" {
    try testing.expectEqualStrings("", urlPathParent("/"));
    try testing.expectEqualStrings("/", urlPathParent("/about/"));
    try testing.expectEqualStrings("/docs/", urlPathParent("/docs/guide/"));
    try testing.expectEqualStrings("", urlPathParent(""));
}

test "buildPageValue: shape" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var entry = PageEntry{
        .source_path = "posts/hello.dj",
        .output_file = "posts/hello/index.html",
        .url_path = "/posts/hello/",
        .absolute_url = "https://example.com/posts/hello/",
        .content_body = "body",
        .extension = ".dj",
        .raw_frontmatter = .{ .string = "" },
        .collection_key = "pages.posts",
    };
    const val = try buildPageValue(a, &entry);
    try testing.expect(val == .map);
    const path_val = val.map.get("path") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("/posts/hello/", path_val.string);
    const url_val = val.map.get("url") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("https://example.com/posts/hello/", url_val.string);
    const doc_val = val.map.get("document") orelse return error.TestUnexpectedResult;
    try testing.expect(doc_val == .map);
}
