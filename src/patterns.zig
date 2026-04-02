const std = @import("std");
const scanner_mod = @import("scanner.zig");

const Allocator = std.mem.Allocator;

pub const PatternDoc = struct {
    name: []const u8,
    description: []const u8,
    custom_properties: []const []const u8,
    exceptions: []const []const u8,
    source_file: []const u8,
};

/// Parses CSS doc comments from a CSS file.
///
/// A doc comment is a `/* ... */` block where the first line is the pattern
/// name, subsequent non-property lines form the description, lines starting
/// with `--` are custom properties, and lines starting with `[data-` are
/// exceptions.
pub fn parseDocComments(a: Allocator, css_source: []const u8, source_file: []const u8) ![]PatternDoc {
    var docs: std.ArrayListUnmanaged(PatternDoc) = .{};
    defer docs.deinit(a);

    var pos: usize = 0;
    while (pos < css_source.len) {
        const open = std.mem.indexOfPos(u8, css_source, pos, "/*") orelse break;
        const close = std.mem.indexOfPos(u8, css_source, open + 2, "*/") orelse break;

        const body = css_source[open + 2 .. close];
        pos = close + 2;

        const doc = parseCommentBody(a, body, source_file) catch continue;
        if (doc) |d| try docs.append(a, d);
    }

    return try a.dupe(PatternDoc, docs.items);
}

fn parseCommentBody(a: Allocator, body: []const u8, source_file: []const u8) !?PatternDoc {
    var name: ?[]const u8 = null;
    var desc_lines: std.ArrayListUnmanaged([]const u8) = .{};
    defer desc_lines.deinit(a);
    var props: std.ArrayListUnmanaged([]const u8) = .{};
    defer props.deinit(a);
    var exceptions: std.ArrayListUnmanaged([]const u8) = .{};
    defer exceptions.deinit(a);

    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r*");
        if (line.len == 0) continue;

        if (name == null) {
            name = try a.dupe(u8, line);
            continue;
        }

        if (std.mem.startsWith(u8, line, "--")) {
            try props.append(a, try a.dupe(u8, line));
        } else if (std.mem.startsWith(u8, line, "[data-")) {
            try exceptions.append(a, try a.dupe(u8, line));
        } else {
            try desc_lines.append(a, try a.dupe(u8, line));
        }
    }

    if (name == null) return null;

    const description = try std.mem.join(a, "\n", desc_lines.items);

    return .{
        .name = name.?,
        .description = description,
        .custom_properties = try a.dupe([]const u8, props.items),
        .exceptions = try a.dupe([]const u8, exceptions.items),
        .source_file = source_file,
    };
}

/// Generates virtual PageEntry structs for pattern library pages.
///
/// Each PatternDoc produces a page at `/patterns/{style_name}/{slug}/`.
pub fn generatePages(a: Allocator, docs: []const PatternDoc, style_name: []const u8) ![]scanner_mod.PageEntry {
    var pages: std.ArrayListUnmanaged(scanner_mod.PageEntry) = .{};
    defer pages.deinit(a);

    for (docs) |doc| {
        const slug = try slugify(a, doc.name);
        const output_file = try std.fmt.allocPrint(a, "patterns/{s}/{s}/index.html", .{ style_name, slug });
        const url_path = try std.fmt.allocPrint(a, "/patterns/{s}/{s}/", .{ style_name, slug });

        try pages.append(a, .{
            .source_path = doc.source_file,
            .output_file = output_file,
            .url_path = url_path,
            .absolute_url = url_path,
            .content_body = doc.description,
            .extension = ".css",
            .raw_frontmatter = .{ .string = doc.name },
            .collection_key = try std.fmt.allocPrint(a, "patterns.{s}", .{style_name}),
        });
    }

    return try a.dupe(scanner_mod.PageEntry, pages.items);
}

fn slugify(a: Allocator, name: []const u8) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .{};
    defer buf.deinit(a);
    for (name) |c| {
        if (std.ascii.isAlphanumeric(c)) {
            try buf.append(a, std.ascii.toLower(c));
        } else if (c == ' ' or c == '-' or c == '_') {
            if (buf.items.len > 0 and buf.items[buf.items.len - 1] != '-') {
                try buf.append(a, '-');
            }
        }
    }
    while (buf.items.len > 0 and buf.items[buf.items.len - 1] == '-') {
        _ = buf.pop();
    }
    return try a.dupe(u8, buf.items);
}

// ── Tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

test "parseDocComments: single doc comment" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const css =
        \\/* Card
        \\ * A card component for content.
        \\ * --card-padding
        \\ * --card-radius
        \\ * [data-variant="outlined"]
        \\ */
        \\.card { padding: var(--card-padding); }
    ;

    const docs = try parseDocComments(a, css, "blocks/card.css");

    try testing.expectEqual(@as(usize, 1), docs.len);
    try testing.expectEqualStrings("Card", docs[0].name);
    try testing.expectEqualStrings("A card component for content.", docs[0].description);
    try testing.expectEqual(@as(usize, 2), docs[0].custom_properties.len);
    try testing.expectEqualStrings("--card-padding", docs[0].custom_properties[0]);
    try testing.expectEqualStrings("--card-radius", docs[0].custom_properties[1]);
    try testing.expectEqual(@as(usize, 1), docs[0].exceptions.len);
    try testing.expectEqualStrings("[data-variant=\"outlined\"]", docs[0].exceptions[0]);
    try testing.expectEqualStrings("blocks/card.css", docs[0].source_file);
}

test "parseDocComments: missing description" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const css =
        \\/* Spacer
        \\ * --spacer-size
        \\ */
        \\.spacer {}
    ;

    const docs = try parseDocComments(a, css, "utils/spacer.css");

    try testing.expectEqual(@as(usize, 1), docs.len);
    try testing.expectEqualStrings("Spacer", docs[0].name);
    try testing.expectEqualStrings("", docs[0].description);
    try testing.expectEqual(@as(usize, 1), docs[0].custom_properties.len);
}

test "parseDocComments: multiple docs in one file" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const css =
        \\/* Button
        \\ * Primary button.
        \\ */
        \\.button {}
        \\
        \\/* Badge
        \\ * Small label badge.
        \\ * --badge-color
        \\ */
        \\.badge {}
    ;

    const docs = try parseDocComments(a, css, "blocks.css");

    try testing.expectEqual(@as(usize, 2), docs.len);
    try testing.expectEqualStrings("Button", docs[0].name);
    try testing.expectEqualStrings("Badge", docs[1].name);
}

test "parseDocComments: empty comment ignored" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const css =
        \\/* */
        \\.foo {}
    ;

    const docs = try parseDocComments(a, css, "test.css");

    try testing.expectEqual(@as(usize, 0), docs.len);
}

test "generatePages: creates page entries" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const docs = &[_]PatternDoc{
        .{
            .name = "Card",
            .description = "A card.",
            .custom_properties = &.{},
            .exceptions = &.{},
            .source_file = "card.css",
        },
    };

    const pages = try generatePages(a, docs, "default");

    try testing.expectEqual(@as(usize, 1), pages.len);
    try testing.expectEqualStrings("/patterns/default/card/", pages[0].url_path);
    try testing.expectEqualStrings("patterns/default/card/index.html", pages[0].output_file);
}

test "slugify: converts name to URL slug" {
    const s1 = try slugify(testing.allocator, "Hero Banner");
    defer testing.allocator.free(s1);
    try testing.expectEqualStrings("hero-banner", s1);

    const s2 = try slugify(testing.allocator, "Card");
    defer testing.allocator.free(s2);
    try testing.expectEqualStrings("card", s2);
}
