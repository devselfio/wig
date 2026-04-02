const std = @import("std");
const Allocator = std.mem.Allocator;
const fs = std.fs;

pub const Link = struct {
    url: []const u8,
};

pub const Issue = struct {
    output_path: []const u8,
    source_path: ?[]const u8,
    target_url: []const u8,
    kind: Kind,

    pub const Kind = enum { broken_path, broken_fragment };
};

const SourceMap = std.StringArrayHashMapUnmanaged([]const u8);

/// Walks all `.html` files in `output_dir`, extracts internal links, and
/// checks each against the output tree. Returns a list of broken-link issues.
/// `source_map` maps output file paths to source content paths for diagnostics.
pub fn checkSite(a: Allocator, output_dir: fs.Dir, source_map: SourceMap) ![]Issue {
    var issues: std.ArrayListUnmanaged(Issue) = .{};
    var html_files: std.ArrayListUnmanaged([]const u8) = .{};
    try collectHtmlFiles(a, output_dir, "", &html_files);

    for (html_files.items) |rel_path| {
        const html = output_dir.readFileAlloc(a, rel_path, 16 * 1024 * 1024) catch continue;
        const links = extractLinks(a, html);
        const src = source_map.get(rel_path);

        for (links) |link| {
            const sep = std.mem.indexOfScalar(u8, link.url, '#');
            const path_part = if (sep) |i| link.url[0..i] else link.url;
            const fragment = if (sep) |i| link.url[i + 1 ..] else null;

            if (path_part.len == 0) {
                if (fragment) |frag| {
                    if (!hasAnchorId(html, frag)) {
                        try issues.append(a, .{
                            .output_path = rel_path,
                            .source_path = src,
                            .target_url = link.url,
                            .kind = .broken_fragment,
                        });
                    }
                }
                continue;
            }

            const resolved = resolvePath(a, rel_path, path_part) catch continue;
            if (!fileExists(output_dir, resolved)) {
                try issues.append(a, .{
                    .output_path = rel_path,
                    .source_path = src,
                    .target_url = link.url,
                    .kind = .broken_path,
                });
                continue;
            }

            if (fragment) |frag| {
                const target_html = output_dir.readFileAlloc(a, resolved, 16 * 1024 * 1024) catch continue;
                if (!hasAnchorId(target_html, frag)) {
                    try issues.append(a, .{
                        .output_path = rel_path,
                        .source_path = src,
                        .target_url = link.url,
                        .kind = .broken_fragment,
                    });
                }
            }
        }
    }

    return issues.items;
}

/// Extracts internal `href` and `src` attribute values from HTML.
/// Skips external URLs, empty hrefs, and fragment-only anchors are kept.
pub fn extractLinks(a: Allocator, html: []const u8) []Link {
    var links: std.ArrayListUnmanaged(Link) = .{};
    const patterns = [_][]const u8{ "href=\"", "src=\"" };

    var pos: usize = 0;
    while (pos < html.len) {
        const lt = std.mem.indexOfScalarPos(u8, html, pos, '<') orelse break;
        const gt = std.mem.indexOfScalarPos(u8, html, lt, '>') orelse break;
        const tag = html[lt..gt + 1];

        for (patterns) |pat| {
            var search_pos: usize = 0;
            while (std.mem.indexOfPos(u8, tag, search_pos, pat)) |attr_start| {
                const val_start = attr_start + pat.len;
                const val_end = std.mem.indexOfScalarPos(u8, tag, val_start, '"') orelse break;
                const url = tag[val_start..val_end];
                search_pos = val_end + 1;

                if (url.len == 0) continue;
                if (isExternal(url)) continue;

                links.append(a, .{ .url = url }) catch continue;
            }
        }

        pos = gt + 1;
    }

    return links.items;
}

/// Returns true if `html` contains `id="id_val"` or `name="id_val"`.
pub fn hasAnchorId(html: []const u8, id_val: []const u8) bool {
    const id_patterns = [_][]const u8{ "id=\"", "name=\"" };
    for (id_patterns) |prefix| {
        var pos: usize = 0;
        while (std.mem.indexOfPos(u8, html, pos, prefix)) |start| {
            const val_start = start + prefix.len;
            const val_end = std.mem.indexOfScalarPos(u8, html, val_start, '"') orelse break;
            if (std.mem.eql(u8, html[val_start..val_end], id_val)) return true;
            pos = val_end + 1;
        }
    }
    return false;
}

fn isExternal(url: []const u8) bool {
    if (std.mem.startsWith(u8, url, "http://")) return true;
    if (std.mem.startsWith(u8, url, "https://")) return true;
    if (std.mem.startsWith(u8, url, "//")) return true;
    if (std.mem.startsWith(u8, url, "mailto:")) return true;
    if (std.mem.startsWith(u8, url, "tel:")) return true;
    if (std.mem.startsWith(u8, url, "javascript:")) return true;
    if (std.mem.startsWith(u8, url, "data:")) return true;
    return false;
}

/// Resolves a link path relative to the output directory.
/// Absolute paths (starting with `/`) strip the leading slash.
/// Directory paths (ending with `/`) append `index.html`.
/// Relative paths resolve against the directory containing `from_file`.
fn resolvePath(a: Allocator, from_file: []const u8, path: []const u8) ![]const u8 {
    var resolved: []const u8 = undefined;

    if (path[0] == '/') {
        resolved = if (path.len > 1) path[1..] else "";
    } else {
        const dir = if (std.mem.lastIndexOfScalar(u8, from_file, '/')) |i|
            from_file[0 .. i + 1]
        else
            "";
        resolved = try std.fmt.allocPrint(a, "{s}{s}", .{ dir, path });
    }

    if (resolved.len == 0) {
        return try a.dupe(u8, "index.html");
    }

    if (resolved[resolved.len - 1] == '/') {
        return try std.fmt.allocPrint(a, "{s}index.html", .{resolved});
    }

    if (std.fs.path.extension(resolved).len == 0) {
        return try std.fmt.allocPrint(a, "{s}/index.html", .{resolved});
    }

    return resolved;
}

fn fileExists(dir: fs.Dir, path: []const u8) bool {
    dir.access(path, .{}) catch return false;
    return true;
}

fn collectHtmlFiles(a: Allocator, dir: fs.Dir, prefix: []const u8, out: *std.ArrayListUnmanaged([]const u8)) !void {
    var it = dir.iterate();
    while (try it.next()) |entry| {
        const rel = if (prefix.len > 0)
            try std.fmt.allocPrint(a, "{s}/{s}", .{ prefix, entry.name })
        else
            try a.dupe(u8, entry.name);

        switch (entry.kind) {
            .file => {
                if (std.mem.endsWith(u8, entry.name, ".html")) {
                    try out.append(a, rel);
                }
            },
            .directory => {
                var sub = dir.openDir(entry.name, .{ .iterate = true }) catch continue;
                defer sub.close();
                try collectHtmlFiles(a, sub, rel, out);
            },
            else => {},
        }
    }
}

// ── Tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

test "extractLinks: finds href and src attributes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const html =
        \\<a href="/about/">About</a>
        \\<a href="/blog/post/">Post</a>
        \\<img src="/images/logo.png">
        \\<link href="/css/style.css">
        \\<script src="/js/app.js"></script>
    ;
    const links = extractLinks(a, html);
    try testing.expectEqual(@as(usize, 5), links.len);
    try testing.expectEqualStrings("/about/", links[0].url);
    try testing.expectEqualStrings("/blog/post/", links[1].url);
    try testing.expectEqualStrings("/images/logo.png", links[2].url);
    try testing.expectEqualStrings("/css/style.css", links[3].url);
    try testing.expectEqualStrings("/js/app.js", links[4].url);
}

test "extractLinks: skips external URLs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const html =
        \\<a href="https://example.com">Ext</a>
        \\<a href="http://foo.com">Ext2</a>
        \\<a href="//cdn.com/lib.js">Proto</a>
        \\<a href="mailto:a@b.com">Mail</a>
        \\<a href="tel:+123">Phone</a>
        \\<a href="javascript:void(0)">JS</a>
        \\<a href="data:text/html,hi">Data</a>
        \\<a href="/internal/">Keep</a>
    ;
    const links = extractLinks(a, html);
    try testing.expectEqual(@as(usize, 1), links.len);
    try testing.expectEqualStrings("/internal/", links[0].url);
}

test "extractLinks: handles fragment links" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const html =
        \\<a href="#section">Frag only</a>
        \\<a href="/page/#anchor">Path+frag</a>
    ;
    const links = extractLinks(a, html);
    try testing.expectEqual(@as(usize, 2), links.len);
    try testing.expectEqualStrings("#section", links[0].url);
    try testing.expectEqualStrings("/page/#anchor", links[1].url);
}

test "hasAnchorId: finds id and name attributes" {
    const html =
        \\<h2 id="introduction">Intro</h2>
        \\<a name="legacy">Legacy</a>
    ;
    try testing.expect(hasAnchorId(html, "introduction"));
    try testing.expect(hasAnchorId(html, "legacy"));
    try testing.expect(!hasAnchorId(html, "missing"));
}

test "hasAnchorId: no false positives on partial matches" {
    const html = "<h2 id=\"section-one\">S1</h2>";
    try testing.expect(hasAnchorId(html, "section-one"));
    try testing.expect(!hasAnchorId(html, "section"));
    try testing.expect(!hasAnchorId(html, "one"));
}

test "resolvePath: absolute paths" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r1 = try resolvePath(a, "blog/post/index.html", "/about/");
    try testing.expectEqualStrings("about/index.html", r1);

    const r2 = try resolvePath(a, "index.html", "/css/style.css");
    try testing.expectEqualStrings("css/style.css", r2);

    const r3 = try resolvePath(a, "index.html", "/");
    try testing.expectEqualStrings("index.html", r3);
}

test "resolvePath: extensionless paths get index.html" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r1 = try resolvePath(arena.allocator(), "index.html", "/about");
    try testing.expectEqualStrings("about/index.html", r1);
}

test "isExternal: recognises external schemes" {
    try testing.expect(isExternal("https://example.com"));
    try testing.expect(isExternal("http://example.com"));
    try testing.expect(isExternal("//cdn.com/foo.js"));
    try testing.expect(isExternal("mailto:user@host"));
    try testing.expect(isExternal("tel:+1234"));
    try testing.expect(isExternal("javascript:void(0)"));
    try testing.expect(isExternal("data:text/html,hi"));
    try testing.expect(!isExternal("/about/"));
    try testing.expect(!isExternal("relative/path"));
    try testing.expect(!isExternal("#fragment"));
}
