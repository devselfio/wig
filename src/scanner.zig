const std = @import("std");
const comb = @import("comb");
const toupee = @import("toupee");
const frontmatter = @import("frontmatter.zig");
const context_mod = @import("context.zig");
const page_meta_mod = @import("page_meta.zig");
const slug_mod = @import("slug.zig");
const collections = @import("collections.zig");

const Allocator = std.mem.Allocator;
const fs = std.fs;

const ValueMap = std.StringArrayHashMapUnmanaged(toupee.Value);
pub const PageMeta = page_meta_mod.PageMeta;

pub const buildPageValue = collections.buildPageValue;

pub const PageEntry = struct {
    source_path: []const u8,
    output_file: []const u8,
    url_path: []const u8,
    absolute_url: []const u8,
    content_body: []const u8,
    extension: []const u8,
    raw_frontmatter: toupee.Value,
    collection_key: []const u8,
    meta: PageMeta = .{},
    is_section: bool = false,
};

pub const ScanResult = struct {
    pages: []PageEntry,
    collections: ValueMap,
    parent_map: std.StringArrayHashMapUnmanaged(?*const PageEntry),
    /// Non-`_index` pages grouped by parent directory path under `pages/` (`""` = root).
    /// Section `_index` pages resolve children with `pagesParentDir(entry.source_path)` as the key.
    children_map: std.StringArrayHashMapUnmanaged([]const *const PageEntry),
    arena: std.heap.ArenaAllocator,

    /// Creates a ScanResult from pre-built pages (e.g. programmatic content sources).
    /// Builds collections, parent map, and children map from the supplied entries.
    pub fn init(backing: Allocator, pages: []PageEntry) !ScanResult {
        var arena = std.heap.ArenaAllocator.init(backing);
        errdefer arena.deinit();
        const a = arena.allocator();

        const owned_pages = try a.dupe(PageEntry, pages);
        var colls: ValueMap = .{};
        try collections.buildCollections(a, owned_pages, &colls);

        return .{
            .pages = owned_pages,
            .collections = colls,
            .parent_map = try collections.buildParentMap(a, owned_pages),
            .children_map = try collections.buildChildrenMap(a, owned_pages),
            .arena = arena,
        };
    }

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
    return scanWithOptions(backing, pages_dir, base_url, site_draft, site_debug, registered_extensions, false);
}

pub fn scanWithOptions(
    backing: Allocator,
    pages_dir: fs.Dir,
    base_url: []const u8,
    site_draft: bool,
    site_debug: bool,
    registered_extensions: []const []const u8,
    default_slugify: bool,
) !ScanResult {
    var arena = std.heap.ArenaAllocator.init(backing);
    errdefer arena.deinit();
    const a = arena.allocator();

    var entries: std.ArrayListUnmanaged(PageEntry) = .{};
    var output_paths = std.StringArrayHashMapUnmanaged([]const u8){};
    var gated_dirs = std.StringArrayHashMapUnmanaged(void){};

    try walkDir(a, pages_dir, "", base_url, site_draft, site_debug, registered_extensions, &entries, &output_paths, &gated_dirs, default_slugify);

    var colls = ValueMap{};
    try collections.buildCollections(a, entries.items, &colls);

    const parent_map = try collections.buildParentMap(a, entries.items);
    const children_map = try collections.buildChildrenMap(a, entries.items);

    return .{
        .pages = entries.items,
        .collections = colls,
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
    default_slugify: bool,
) !void {
    if (rel_prefix.len > 0 and gated_dirs.contains(pagesParentDir(rel_prefix))) return;

    // Pass 1: find _index section file, check gating before processing others.
    var section_entry: ?PageEntry = null;
    {
        var it = dir.iterate();
        while (try it.next()) |entry| {
            if (entry.kind != .file) continue;
            if (isHidden(entry.name)) continue;
            const ext = fs.path.extension(entry.name);
            const stem = entry.name[0 .. entry.name.len - ext.len];
            if (!isSection(stem)) continue;
            if (!isValidExtension(ext, registered_extensions)) return error.UnrecognisedExtension;

            const page = try parsePageFile(a, dir, entry.name, rel_prefix, ext, base_url, registered_extensions, default_slugify);
            if (page.meta.draft and !site_draft or page.meta.debug and !site_debug) {
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
            if (isHidden(entry.name)) continue;
            const ext = fs.path.extension(entry.name);
            const stem = entry.name[0 .. entry.name.len - ext.len];
            if (isSection(stem)) continue;
            if (!isValidExtension(ext, registered_extensions)) return error.UnrecognisedExtension;

            const page = try parsePageFile(a, dir, entry.name, rel_prefix, ext, base_url, registered_extensions, default_slugify);
            if (page.meta.draft and !site_draft) continue;
            if (page.meta.debug and !site_debug) continue;

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
            if (isHidden(entry.name)) continue;

            const sub_prefix = if (rel_prefix.len > 0)
                try std.fmt.allocPrint(a, "{s}/{s}", .{ rel_prefix, entry.name })
            else
                try a.dupe(u8, entry.name);

            var sub_dir = dir.openDir(entry.name, .{ .iterate = true }) catch continue;
            defer sub_dir.close();

            try walkDir(a, sub_dir, sub_prefix, base_url, site_draft, site_debug, registered_extensions, entries, output_paths, gated_dirs, default_slugify);
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
    default_slugify: bool,
) !PageEntry {
    _ = registered_extensions;

    const source = try dir.readFileAlloc(a, filename, 4 * 1024 * 1024);
    const fm_result = try frontmatter.parse(a, source);
    if (fm_result == null) return error.MissingFrontmatter;
    const fm = fm_result.?;

    const canonical_fm = try frontmatter.normalizeWigPageFrontmatter(a, fm.data);

    const meta = try page_meta_mod.parsePageMeta(a, canonical_fm);
    const fm_toupee = try context_mod.combToToupee(a, canonical_fm);
    const stem = filename[0 .. filename.len - ext.len];

    const should_slugify = (meta.slugify orelse default_slugify) and !slug_mod.isSpecialStem(stem);

    const slugified_stem = if (should_slugify) try slug_mod.slugifyStem(a, stem) else try a.dupe(u8, stem);
    const slugified_path = if (should_slugify and rel_prefix.len > 0)
        try std.fmt.allocPrint(a, "{s}/{s}{s}", .{ rel_prefix, slugified_stem, ext })
    else if (rel_prefix.len > 0)
        try std.fmt.allocPrint(a, "{s}/{s}", .{ rel_prefix, filename })
    else if (should_slugify)
        try std.fmt.allocPrint(a, "{s}{s}", .{ slugified_stem, ext })
    else
        try a.dupe(u8, filename);

    const rel_path = if (rel_prefix.len > 0)
        try std.fmt.allocPrint(a, "{s}/{s}", .{ rel_prefix, filename })
    else
        try a.dupe(u8, filename);

    const output_file = try deriveOutputPath(a, slugified_path);
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
        .raw_frontmatter = fm_toupee,
        .collection_key = collection_key,
        .meta = meta,
        .is_section = isSection(stem),
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

/// Stems that should never be slugified: _index, index, _NNN error pages.
fn isSpecialStem(stem: []const u8) bool {
    if (std.mem.eql(u8, stem, "_index") or std.mem.eql(u8, stem, "index")) return true;
    if (stem.len >= 2 and stem[0] == '_') {
        for (stem[1..]) |c| {
            if (!std.ascii.isDigit(c)) return false;
        }
        return true;
    }
    return false;
}

/// Skip dot-prefixed names (e.g. `._foo`, macOS AppleDouble metadata; `.git`).
fn isHidden(name: []const u8) bool {
    return name.len > 0 and name[0] == '.';
}

fn getBool(val: comb.Value, key: []const u8) bool {
    const v = val.get(key) orelse return false;
    return switch (v) {
        .boolean => |b| b,
        else => false,
    };
}

/// Resolves slugify for a page: page frontmatter overrides the cascade default.
fn pageSlugify(canonical_fm: comb.Value, default_slugify: bool) bool {
    const doc = canonical_fm.get("document") orelse return default_slugify;
    const val = doc.get("slugify") orelse return default_slugify;
    return switch (val) {
        .boolean => |b| b,
        else => default_slugify,
    };
}

/// Converts a filename stem to a URL-friendly slug: underscores → hyphens, lowercased.
fn slugifyStem(a: Allocator, stem: []const u8) ![]u8 {
    const buf = try a.alloc(u8, stem.len);
    for (stem, buf) |c, *out| {
        out.* = if (c == '_') '-' else std.ascii.toLower(c);
    }
    return buf;
}

fn getBoolInDocument(root: comb.Value, key: []const u8) bool {
    const doc = root.get("document") orelse return false;
    return getBool(doc, key);
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

/// Parent path segment for a `pages/` relative path: `posts/a.dj` → `posts`, `a.dj` → `""`.
/// Used for section children (siblings in the same directory) and gated-dir checks on `rel_prefix`.
pub fn pagesParentDir(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |idx| return path[0..idx];
    return "";
}


// ── Tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

test "pagesParentDir" {
    try testing.expectEqualStrings("", pagesParentDir("about.dj"));
    try testing.expectEqualStrings("posts", pagesParentDir("posts/a.dj"));
    try testing.expectEqualStrings("docs/guide", pagesParentDir("docs/guide/_index.dj"));
}

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

    const pages_root = result.collections.get("pages") orelse return error.TestUnexpectedResult;
    try testing.expect(pages_root == .map);
    const posts_map = pages_root.map.get("posts") orelse return error.TestUnexpectedResult;
    try testing.expect(posts_map == .map);
    const items_val = posts_map.map.get("items") orelse return error.TestUnexpectedResult;
    try testing.expect(items_val == .list);
    try testing.expectEqual(@as(usize, 1), items_val.list.len);
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

test "scan: invalid page frontmatter root is an error" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("pages");
    var pages_dir = try tmp.dir.openDir("pages", .{ .iterate = true });
    defer pages_dir.close();

    var f = try pages_dir.createFile("bad.dj", .{});
    try f.writeAll("---\n42\n---\nbody");
    f.close();

    const exts = [_][]const u8{".dj"};
    const result = scan(testing.allocator, pages_dir, "https://example.com", false, false, &exts);
    try testing.expectError(error.InvalidWigPageFrontmatter, result);
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

    const pages_root = result.collections.get("pages") orelse return error.TestUnexpectedResult;
    const posts_map = pages_root.map.get("posts") orelse return error.TestUnexpectedResult;
    try testing.expect(posts_map.map.get("document") != null);
    const items_val = posts_map.map.get("items") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 1), items_val.list.len);
}

test "scan: children_map groups leaves by pages parent directory" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("pages/posts");
    var pages_dir = try tmp.dir.openDir("pages", .{ .iterate = true });
    defer pages_dir.close();

    var posts_dir = try pages_dir.openDir("posts", .{});
    defer posts_dir.close();

    var idx = try posts_dir.createFile("_index.dj", .{});
    try idx.writeAll("---\ntitle: Hub\n---\nhub");
    idx.close();

    var a = try posts_dir.createFile("a.dj", .{});
    try a.writeAll("---\ntitle: A\n---\na");
    a.close();

    var b = try posts_dir.createFile("b.dj", .{});
    try b.writeAll("---\ntitle: B\n---\nb");
    b.close();

    const exts = [_][]const u8{".dj"};
    var result = try scan(testing.allocator, pages_dir, "https://example.com", false, false, &exts);
    defer result.deinit();

    const children = result.children_map.get("posts") orelse {
        return error.TestUnexpectedResult;
    };
    try testing.expectEqual(@as(usize, 2), children.len);
}

test "scan: children_map matches spec 13 style slugs" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("pages/posts");
    var pages_dir = try tmp.dir.openDir("pages", .{ .iterate = true });
    defer pages_dir.close();

    var root_idx = try pages_dir.createFile("_index.dj", .{});
    try root_idx.writeAll("---\ntitle: Root\n---\nroot");
    root_idx.close();

    var posts_dir = try pages_dir.openDir("posts", .{});
    defer posts_dir.close();

    var idx = try posts_dir.createFile("_index.dj", .{});
    try idx.writeAll("---\ntitle: Post List\n---\nWelcome.");
    idx.close();

    var first = try posts_dir.createFile("001_first.dj", .{});
    try first.writeAll("---\ntitle: First Post\n---\nBody.");
    first.close();

    var second = try posts_dir.createFile("002_second.dj", .{});
    try second.writeAll("---\ntitle: Second Post\n---\nBody.");
    second.close();

    const exts = [_][]const u8{".dj"};
    var result = try scan(testing.allocator, pages_dir, "https://example.com", false, false, &exts);
    defer result.deinit();

    const children = result.children_map.get("posts") orelse {
        return error.TestUnexpectedResult;
    };
    try testing.expectEqual(@as(usize, 2), children.len);

    for (result.pages) |page| {
        const derived = try deriveUrlPath(testing.allocator, page.output_file);
        defer testing.allocator.free(derived);
        try testing.expectEqualStrings(derived, page.url_path);
    }
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

    const pages_root = result.collections.get("pages") orelse return error.TestUnexpectedResult;
    const posts_map = pages_root.map.get("posts") orelse return error.TestUnexpectedResult;
    const items_val = posts_map.map.get("items") orelse return error.TestUnexpectedResult;
    const posts = items_val.list;
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
