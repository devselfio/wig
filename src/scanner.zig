const std = @import("std");
const comb = @import("comb");
const toupee = @import("toupee");
const frontmatter = @import("frontmatter.zig");
const context_mod = @import("context.zig");

const Allocator = std.mem.Allocator;
const fs = std.fs;

const ValueMap = std.StringArrayHashMapUnmanaged(toupee.Value);

pub const PageEntry = struct {
    source_path: []const u8,
    output_file: []const u8,
    url_path: []const u8,
    absolute_url: []const u8,
    content_body: []const u8,
    extension: []const u8,
    frontmatter: toupee.Value,
    collection_key: []const u8,
    is_section: bool = false,
    is_draft: bool = false,
    is_debug: bool = false,
};

pub const ScanResult = struct {
    pages: []PageEntry,
    collections: ValueMap,
    parent_map: std.StringArrayHashMapUnmanaged(?*const PageEntry),
    children_map: std.StringArrayHashMapUnmanaged([]const *const PageEntry),
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *ScanResult) void {
        self.arena.deinit();
    }
};

/// Walks the `pages/` directory, parses frontmatter, builds collections,
/// detects sections, applies render gating, and checks for path collisions.
///
/// `registered_extensions` lists valid content file extensions (e.g. `.dj`, `.md`).
/// `.html` is always accepted. Files with unrecognised extensions are an error.
/// Files without `---` frontmatter are an error.
pub fn scan(
    backing: Allocator,
    pages_dir: fs.Dir,
    base_url: []const u8,
    site_draft: bool,
    site_debug: bool,
    registered_extensions: []const []const u8,
) !ScanResult {
    var arena = std.heap.ArenaAllocator.init(backing);
    errdefer arena.deinit();
    const a = arena.allocator();

    var entries: std.ArrayListUnmanaged(PageEntry) = .{};
    var output_paths = std.StringArrayHashMapUnmanaged([]const u8){};
    var gated_dirs = std.StringArrayHashMapUnmanaged(void){};

    try walkDir(a, pages_dir, "", base_url, site_draft, site_debug, registered_extensions, &entries, &output_paths, &gated_dirs);

    var collections = ValueMap{};
    try buildCollections(a, entries.items, &collections);

    const parent_map = try buildParentMap(a, entries.items);
    const children_map = try buildChildrenMap(a, entries.items);

    return .{
        .pages = entries.items,
        .collections = collections,
        .parent_map = parent_map,
        .children_map = children_map,
        .arena = arena,
    };
}

fn walkDir(
    a: Allocator,
    dir: fs.Dir,
    rel_prefix: []const u8,
    base_url: []const u8,
    site_draft: bool,
    site_debug: bool,
    registered_extensions: []const []const u8,
    entries: *std.ArrayListUnmanaged(PageEntry),
    output_paths: *std.StringArrayHashMapUnmanaged([]const u8),
    gated_dirs: *std.StringArrayHashMapUnmanaged(void),
) !void {
    if (rel_prefix.len > 0 and gated_dirs.contains(parentDir(rel_prefix))) return;

    // Pass 1: find _index section file, check gating before processing others.
    var section_entry: ?PageEntry = null;
    {
        var it = dir.iterate();
        while (try it.next()) |entry| {
            if (entry.kind != .file) continue;
            const ext = fs.path.extension(entry.name);
            const stem = entry.name[0 .. entry.name.len - ext.len];
            if (!isSection(stem)) continue;
            if (!isValidExtension(ext, registered_extensions)) return error.UnrecognisedExtension;

            const page = try parsePageFile(a, dir, entry.name, rel_prefix, ext, base_url, registered_extensions);
            if (page.is_draft and !site_draft or page.is_debug and !site_debug) {
                try gated_dirs.put(a, rel_prefix, {});
                return;
            }
            section_entry = page;
            break;
        }
    }

    // Pass 2: process non-section files.
    {
        var it = dir.iterate();
        while (try it.next()) |entry| {
            if (entry.kind != .file) continue;
            const ext = fs.path.extension(entry.name);
            const stem = entry.name[0 .. entry.name.len - ext.len];
            if (isSection(stem)) continue;
            if (!isValidExtension(ext, registered_extensions)) return error.UnrecognisedExtension;

            const page = try parsePageFile(a, dir, entry.name, rel_prefix, ext, base_url, registered_extensions);
            if (page.is_draft and !site_draft) continue;
            if (page.is_debug and !site_debug) continue;

            if (output_paths.contains(page.output_file)) return error.PathCollision;
            try output_paths.put(a, page.output_file, page.source_path);
            try entries.append(a, page);
        }
    }

    // Add section entry after non-section pages (so collision check covers both).
    if (section_entry) |se| {
        if (output_paths.contains(se.output_file)) return error.PathCollision;
        try output_paths.put(a, se.output_file, se.source_path);
        try entries.append(a, se);
    }

    // Pass 3: recurse into subdirectories.
    {
        var it = dir.iterate();
        while (try it.next()) |entry| {
            if (entry.kind != .directory) continue;

            const sub_prefix = if (rel_prefix.len > 0)
                try std.fmt.allocPrint(a, "{s}/{s}", .{ rel_prefix, entry.name })
            else
                try a.dupe(u8, entry.name);

            var sub_dir = dir.openDir(entry.name, .{ .iterate = true }) catch continue;
            defer sub_dir.close();

            try walkDir(a, sub_dir, sub_prefix, base_url, site_draft, site_debug, registered_extensions, entries, output_paths, gated_dirs);
        }
    }
}

fn parsePageFile(
    a: Allocator,
    dir: fs.Dir,
    filename: []const u8,
    rel_prefix: []const u8,
    ext: []const u8,
    base_url: []const u8,
    registered_extensions: []const []const u8,
) !PageEntry {
    _ = registered_extensions;

    const rel_path = if (rel_prefix.len > 0)
        try std.fmt.allocPrint(a, "{s}/{s}", .{ rel_prefix, filename })
    else
        try a.dupe(u8, filename);

    const source = try dir.readFileAlloc(a, filename, 4 * 1024 * 1024);
    const fm_result = try frontmatter.parse(a, source);
    if (fm_result == null) return error.MissingFrontmatter;
    const fm = fm_result.?;

    const fm_toupee = try context_mod.combToToupee(a, fm.data);
    const stem = filename[0 .. filename.len - ext.len];

    const output_file = try deriveOutputPath(a, rel_path);
    const url_path = try deriveUrlPath(a, output_file);

    const absolute_url = if (base_url.len > 0 and std.mem.endsWith(u8, base_url, "/"))
        try std.fmt.allocPrint(a, "{s}{s}", .{ base_url[0 .. base_url.len - 1], url_path })
    else if (base_url.len > 0)
        try std.fmt.allocPrint(a, "{s}{s}", .{ base_url, url_path })
    else
        try a.dupe(u8, url_path);

    const collection_key = if (rel_prefix.len > 0) blk: {
        const dot = try dotPath(a, rel_prefix);
        break :blk try std.fmt.allocPrint(a, "pages.{s}", .{dot});
    } else try a.dupe(u8, "pages");

    return .{
        .source_path = rel_path,
        .output_file = output_file,
        .url_path = url_path,
        .absolute_url = absolute_url,
        .content_body = fm.content,
        .extension = try a.dupe(u8, ext),
        .frontmatter = fm_toupee,
        .collection_key = collection_key,
        .is_section = isSection(stem),
        .is_draft = getBool(fm.data, "draft"),
        .is_debug = getBool(fm.data, "debug"),
    };
}

fn isValidExtension(ext: []const u8, registered: []const []const u8) bool {
    if (std.mem.eql(u8, ext, ".html")) return true;
    for (registered) |r| {
        if (std.mem.eql(u8, ext, r)) return true;
    }
    return false;
}

fn isSection(stem: []const u8) bool {
    return std.mem.eql(u8, stem, "_index");
}

fn getBool(val: comb.Value, key: []const u8) bool {
    const v = val.get(key) orelse return false;
    return switch (v) {
        .boolean => |b| b,
        else => false,
    };
}

/// Derives the output file path from a source path using clean URL rules.
///
/// - `about.dj` -> `about/index.html`
/// - `index.dj` -> `index.html`
/// - `_index.dj` -> `index.html`
/// - `_404.dj` -> `404.html`
/// - `posts/my-post.dj` -> `posts/my-post/index.html`
/// - `posts/_index.dj` -> `posts/index.html`
pub fn deriveOutputPath(a: Allocator, source_path: []const u8) ![]const u8 {
    const dir_part = if (std.mem.lastIndexOfScalar(u8, source_path, '/')) |idx|
        source_path[0 .. idx + 1]
    else
        "";
    const filename = if (std.mem.lastIndexOfScalar(u8, source_path, '/')) |idx|
        source_path[idx + 1 ..]
    else
        source_path;

    const ext = fs.path.extension(filename);
    const stem = filename[0 .. filename.len - ext.len];

    // _404, _500, etc. -> 404.html, 500.html
    if (stem.len >= 2 and stem[0] == '_') {
        var all_digits = true;
        for (stem[1..]) |c| {
            if (!std.ascii.isDigit(c)) {
                all_digits = false;
                break;
            }
        }
        if (all_digits) return try std.fmt.allocPrint(a, "{s}.html", .{stem[1..]});
    }

    if (std.mem.eql(u8, stem, "_index")) {
        return try std.fmt.allocPrint(a, "{s}index.html", .{dir_part});
    }

    // Root index.dj -> index.html; sub/index.dj -> sub/index/index.html
    if (std.mem.eql(u8, stem, "index")) {
        if (dir_part.len == 0) return try a.dupe(u8, "index.html");
        return try std.fmt.allocPrint(a, "{s}index/index.html", .{dir_part});
    }

    return try std.fmt.allocPrint(a, "{s}{s}/index.html", .{ dir_part, stem });
}

/// Derives the URL path from an output file path.
/// `about/index.html` -> `/about/`, `index.html` -> `/`
pub fn deriveUrlPath(a: Allocator, output_file: []const u8) ![]const u8 {
    if (std.mem.eql(u8, output_file, "404.html")) return try a.dupe(u8, "/404.html");
    if (std.mem.eql(u8, output_file, "index.html")) return try a.dupe(u8, "/");

    if (std.mem.endsWith(u8, output_file, "/index.html")) {
        const dir = output_file[0 .. output_file.len - "index.html".len];
        return try std.fmt.allocPrint(a, "/{s}", .{dir});
    }

    return try std.fmt.allocPrint(a, "/{s}", .{output_file});
}

/// Converts `posts/tutorials` to `posts.tutorials` for collection keys.
pub fn dotPath(a: Allocator, path: []const u8) ![]u8 {
    const result = try a.dupe(u8, path);
    for (result) |*c| {
        if (c.* == '/') c.* = '.';
    }
    return result;
}

fn parentDir(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |idx| return path[0..idx];
    return "";
}

/// Builds a single page value with path, url, source, and merged document (path + frontmatter).
fn buildPageValue(a: Allocator, page: *const PageEntry) !toupee.Value {
    var page_map = ValueMap{};
    try page_map.put(a, "path", .{ .string = page.url_path });
    try page_map.put(a, "url", .{ .string = page.absolute_url });
    try page_map.put(a, "source", .{ .string = page.source_path });

    // Build document map: path first, then overlay frontmatter document
    var doc_map = ValueMap{};
    try doc_map.put(a, "path", .{ .string = page.url_path });
    try doc_map.put(a, "url", .{ .string = page.absolute_url });
    if (page.frontmatter == .map) {
        if (page.frontmatter.map.get("document")) |doc_val| {
            if (doc_val == .map) {
                var doc_it = doc_val.map.iterator();
                while (doc_it.next()) |doc_entry| {
                    try doc_map.put(a, doc_entry.key_ptr.*, doc_entry.value_ptr.*);
                }
            }
        }
        var fm_it = page.frontmatter.map.iterator();
        while (fm_it.next()) |entry| {
            if (!std.mem.eql(u8, entry.key_ptr.*, "document")) {
                try page_map.put(a, entry.key_ptr.*, entry.value_ptr.*);
            }
        }
    }
    try page_map.put(a, "document", .{ .map = doc_map });
    return .{ .map = page_map };
}

/// Builds collection maps from page entries. Each directory produces a
/// collection at its full dot-path (e.g. `pages.posts`). Section pages
/// (`_index`) are excluded from collection lists. Collections are sorted
/// by filename descending (newest first for date-prefixed blogs).
/// For the root "pages" collection, also builds a slug-keyed map for direct
/// access (pages.document, pages.two, etc.).
fn buildCollections(
    a: Allocator,
    pages: []const PageEntry,
    collections: *ValueMap,
) !void {
    var buckets = std.StringArrayHashMapUnmanaged(std.ArrayListUnmanaged(toupee.Value)){};

    for (pages) |page| {
        if (page.is_section) continue;

        const key = page.collection_key;
        var list = if (buckets.get(key)) |l| l else std.ArrayListUnmanaged(toupee.Value){};

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

        const items = try a.dupe(toupee.Value, entry.value_ptr.items);
        try collections.put(a, entry.key_ptr.*, .{ .list = items });
    }

    // For root "pages" collection, build slug-keyed map for direct access (pages.document, pages.two)
    var pages_by_slug = ValueMap{};
    for (pages) |page| {
        if (!std.mem.eql(u8, page.collection_key, "pages")) continue;

        const page_val = try buildPageValue(a, &page);
        const slug = if (page.is_section) "document" else blk: {
            const stem = std.fs.path.stem(page.source_path);
            break :blk stem;
        };
        try pages_by_slug.put(a, slug, page_val);
    }
    if (pages_by_slug.count() > 0) {
        try collections.put(a, "pages", .{ .map = pages_by_slug });
    }
}

/// URL path of parent directory. "/docs/alpha/" -> "/docs/", "/docs/" -> "/", "/" -> empty.
fn urlPathParent(url_path: []const u8) []const u8 {
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
fn buildParentMap(a: Allocator, pages: []const PageEntry) !std.StringArrayHashMapUnmanaged(?*const PageEntry) {
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

/// Builds url_path -> children pages map for section hierarchy.
fn buildChildrenMap(a: Allocator, pages: []const PageEntry) !std.StringArrayHashMapUnmanaged([]const *const PageEntry) {
    var children_lists = std.StringArrayHashMapUnmanaged(std.ArrayListUnmanaged(*const PageEntry)){};
    for (pages) |*p| {
        const parent_url = urlPathParent(p.url_path);
        if (parent_url.len == 0) continue;
        var list = children_lists.getPtr(parent_url) orelse blk: {
            const new_list = std.ArrayListUnmanaged(*const PageEntry){};
            try children_lists.put(a, parent_url, new_list);
            break :blk children_lists.getPtr(parent_url).?;
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

// ── Tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

test "deriveOutputPath: regular page" {
    const a = testing.allocator;
    const r = try deriveOutputPath(a, "about.dj");
    defer a.free(r);
    try testing.expectEqualStrings("about/index.html", r);
}

test "deriveOutputPath: root index" {
    const a = testing.allocator;
    const r = try deriveOutputPath(a, "index.dj");
    defer a.free(r);
    try testing.expectEqualStrings("index.html", r);
}

test "deriveOutputPath: _index section" {
    const a = testing.allocator;
    const r = try deriveOutputPath(a, "posts/_index.dj");
    defer a.free(r);
    try testing.expectEqualStrings("posts/index.html", r);
}

test "deriveOutputPath: _404 error page" {
    const a = testing.allocator;
    const r = try deriveOutputPath(a, "_404.dj");
    defer a.free(r);
    try testing.expectEqualStrings("404.html", r);
}

test "deriveOutputPath: nested page" {
    const a = testing.allocator;
    const r = try deriveOutputPath(a, "posts/my-post.dj");
    defer a.free(r);
    try testing.expectEqualStrings("posts/my-post/index.html", r);
}

test "deriveOutputPath: html extension" {
    const a = testing.allocator;
    const r = try deriveOutputPath(a, "contact.html");
    defer a.free(r);
    try testing.expectEqualStrings("contact/index.html", r);
}

test "deriveOutputPath: deeply nested" {
    const a = testing.allocator;
    const r = try deriveOutputPath(a, "tutorials/zig/intro.dj");
    defer a.free(r);
    try testing.expectEqualStrings("tutorials/zig/intro/index.html", r);
}

test "deriveUrlPath: regular page" {
    const a = testing.allocator;
    const r = try deriveUrlPath(a, "about/index.html");
    defer a.free(r);
    try testing.expectEqualStrings("/about/", r);
}

test "deriveUrlPath: root index" {
    const a = testing.allocator;
    const r = try deriveUrlPath(a, "index.html");
    defer a.free(r);
    try testing.expectEqualStrings("/", r);
}

test "deriveUrlPath: nested page" {
    const a = testing.allocator;
    const r = try deriveUrlPath(a, "posts/my-post/index.html");
    defer a.free(r);
    try testing.expectEqualStrings("/posts/my-post/", r);
}

test "deriveUrlPath: 404" {
    const a = testing.allocator;
    const r = try deriveUrlPath(a, "404.html");
    defer a.free(r);
    try testing.expectEqualStrings("/404.html", r);
}

test "scan: basic pages directory" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("pages");
    var pages_dir = try tmp.dir.openDir("pages", .{ .iterate = true });
    defer pages_dir.close();

    var f1 = try pages_dir.createFile("index.dj", .{});
    try f1.writeAll("---\ntitle: Home\n---\nWelcome");
    f1.close();

    var f2 = try pages_dir.createFile("about.dj", .{});
    try f2.writeAll("---\ntitle: About\n---\nAbout us");
    f2.close();

    const exts = [_][]const u8{".dj"};
    var result = try scan(testing.allocator, pages_dir, "https://example.com", false, false, &exts);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 2), result.pages.len);
}

test "scan: collection building" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("pages/posts");
    var pages_dir = try tmp.dir.openDir("pages", .{ .iterate = true });
    defer pages_dir.close();

    var f1 = try pages_dir.createFile("index.dj", .{});
    try f1.writeAll("---\ntitle: Home\n---\nhome");
    f1.close();

    var posts_dir = try pages_dir.openDir("posts", .{});
    defer posts_dir.close();
    var f2 = try posts_dir.createFile("first.dj", .{});
    try f2.writeAll("---\ntitle: First Post\n---\ncontent");
    f2.close();

    const exts = [_][]const u8{".dj"};
    var result = try scan(testing.allocator, pages_dir, "https://example.com", false, false, &exts);
    defer result.deinit();

    try testing.expect(result.collections.get("pages") != null);
    try testing.expect(result.collections.get("pages.posts") != null);

    const posts_list = result.collections.get("pages.posts").?.list;
    try testing.expectEqual(@as(usize, 1), posts_list.len);
}

test "scan: missing frontmatter is an error" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("pages");
    var pages_dir = try tmp.dir.openDir("pages", .{ .iterate = true });
    defer pages_dir.close();

    var f = try pages_dir.createFile("bad.dj", .{});
    try f.writeAll("No frontmatter here");
    f.close();

    const exts = [_][]const u8{".dj"};
    const result = scan(testing.allocator, pages_dir, "https://example.com", false, false, &exts);
    try testing.expectError(error.MissingFrontmatter, result);
}

test "scan: draft pages excluded when site.draft is false" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("pages");
    var pages_dir = try tmp.dir.openDir("pages", .{ .iterate = true });
    defer pages_dir.close();

    var f1 = try pages_dir.createFile("visible.dj", .{});
    try f1.writeAll("---\ntitle: Visible\n---\nyes");
    f1.close();

    var f2 = try pages_dir.createFile("hidden.dj", .{});
    try f2.writeAll("---\ntitle: Hidden\ndraft: true\n---\nno");
    f2.close();

    const exts = [_][]const u8{".dj"};
    var result = try scan(testing.allocator, pages_dir, "https://example.com", false, false, &exts);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 1), result.pages.len);
    try testing.expectEqualStrings("visible.dj", result.pages[0].source_path);
}

test "scan: draft pages included when site.draft is true" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("pages");
    var pages_dir = try tmp.dir.openDir("pages", .{ .iterate = true });
    defer pages_dir.close();

    var f = try pages_dir.createFile("draft-post.dj", .{});
    try f.writeAll("---\ntitle: Draft\ndraft: true\n---\nwip");
    f.close();

    const exts = [_][]const u8{".dj"};
    var result = try scan(testing.allocator, pages_dir, "https://example.com", true, false, &exts);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 1), result.pages.len);
}

test "scan: section _index detection" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("pages/posts");
    var pages_dir = try tmp.dir.openDir("pages", .{ .iterate = true });
    defer pages_dir.close();

    var posts_dir = try pages_dir.openDir("posts", .{});
    defer posts_dir.close();

    var idx = try posts_dir.createFile("_index.dj", .{});
    try idx.writeAll("---\ntitle: All Posts\n---\nlisting");
    idx.close();

    var p = try posts_dir.createFile("first.dj", .{});
    try p.writeAll("---\ntitle: First\n---\ncontent");
    p.close();

    const exts = [_][]const u8{".dj"};
    var result = try scan(testing.allocator, pages_dir, "https://example.com", false, false, &exts);
    defer result.deinit();

    var section_count: usize = 0;
    var non_section_count: usize = 0;
    for (result.pages) |page| {
        if (page.is_section) section_count += 1 else non_section_count += 1;
    }
    try testing.expectEqual(@as(usize, 1), section_count);
    try testing.expectEqual(@as(usize, 1), non_section_count);

    const posts_coll = result.collections.get("pages.posts").?.list;
    try testing.expectEqual(@as(usize, 1), posts_coll.len);
}

test "scan: gated section excludes entire directory" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("pages/drafts");
    var pages_dir = try tmp.dir.openDir("pages", .{ .iterate = true });
    defer pages_dir.close();

    var drafts_dir = try pages_dir.openDir("drafts", .{});
    defer drafts_dir.close();

    var idx = try drafts_dir.createFile("_index.dj", .{});
    try idx.writeAll("---\ntitle: Drafts\ndraft: true\n---\nlisting");
    idx.close();

    var p = try drafts_dir.createFile("secret.dj", .{});
    try p.writeAll("---\ntitle: Secret\n---\nhidden");
    p.close();

    const exts = [_][]const u8{".dj"};
    var result = try scan(testing.allocator, pages_dir, "https://example.com", false, false, &exts);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 0), result.pages.len);
}

test "scan: absolute URL construction" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("pages");
    var pages_dir = try tmp.dir.openDir("pages", .{ .iterate = true });
    defer pages_dir.close();

    var f = try pages_dir.createFile("about.dj", .{});
    try f.writeAll("---\ntitle: About\n---\ncontent");
    f.close();

    const exts = [_][]const u8{".dj"};
    var result = try scan(testing.allocator, pages_dir, "https://example.com", false, false, &exts);
    defer result.deinit();

    try testing.expectEqualStrings("/about/", result.pages[0].url_path);
    try testing.expectEqualStrings("https://example.com/about/", result.pages[0].absolute_url);
}

test "scan: collections sorted by filename descending" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("pages/posts");
    var pages_dir = try tmp.dir.openDir("pages", .{ .iterate = true });
    defer pages_dir.close();

    var posts_dir = try pages_dir.openDir("posts", .{});
    defer posts_dir.close();

    var f1 = try posts_dir.createFile("260101-alpha.dj", .{});
    try f1.writeAll("---\ntitle: Alpha\n---\na");
    f1.close();

    var f2 = try posts_dir.createFile("260303-gamma.dj", .{});
    try f2.writeAll("---\ntitle: Gamma\n---\nc");
    f2.close();

    var f3 = try posts_dir.createFile("260202-beta.dj", .{});
    try f3.writeAll("---\ntitle: Beta\n---\nb");
    f3.close();

    const exts = [_][]const u8{".dj"};
    var result = try scan(testing.allocator, pages_dir, "https://example.com", false, false, &exts);
    defer result.deinit();

    const posts = result.collections.get("pages.posts").?.list;
    try testing.expectEqual(@as(usize, 3), posts.len);

    const first_src = posts[0].map.get("source").?.string;
    const last_src = posts[2].map.get("source").?.string;
    try testing.expect(std.mem.indexOf(u8, first_src, "gamma") != null);
    try testing.expect(std.mem.indexOf(u8, last_src, "alpha") != null);
}

test "scan: unrecognised extension is an error" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("pages");
    var pages_dir = try tmp.dir.openDir("pages", .{ .iterate = true });
    defer pages_dir.close();

    var f = try pages_dir.createFile("page.rst", .{});
    try f.writeAll("---\ntitle: RST\n---\ncontent");
    f.close();

    const exts = [_][]const u8{".dj"};
    const result = scan(testing.allocator, pages_dir, "https://example.com", false, false, &exts);
    try testing.expectError(error.UnrecognisedExtension, result);
}

test "isSection: identifies _index stems" {
    try testing.expect(isSection("_index"));
    try testing.expect(!isSection("index"));
    try testing.expect(!isSection("about"));
    try testing.expect(!isSection("_404"));
}

test "dotPath: single slash" {
    const a = testing.allocator;
    const r = try dotPath(a, "posts/tutorials");
    defer a.free(r);
    try testing.expectEqualStrings("posts.tutorials", r);
}

test "dotPath: no slash unchanged" {
    const a = testing.allocator;
    const r = try dotPath(a, "posts");
    defer a.free(r);
    try testing.expectEqualStrings("posts", r);
}

test "dotPath: multiple levels" {
    const a = testing.allocator;
    const r = try dotPath(a, "a/b/c/d");
    defer a.free(r);
    try testing.expectEqualStrings("a.b.c.d", r);
}

test "dotPath: empty string" {
    const a = testing.allocator;
    const r = try dotPath(a, "");
    defer a.free(r);
    try testing.expectEqualStrings("", r);
}
