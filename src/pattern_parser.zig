const std = @import("std");
const comb = @import("comb");
const toupee = @import("toupee");
const frontmatter = @import("frontmatter.zig");
const context_mod = @import("context.zig");

const Allocator = std.mem.Allocator;
const ValueMap = std.StringArrayHashMapUnmanaged(toupee.Value);

pub const Variant = struct {
    name: []const u8,
    content: []const u8,
};

pub const PatternFile = struct {
    metadata: toupee.Value,
    example: []const u8,
    variants: []const Variant,
};

/// Parses an HTML pattern file with YAML front-matter and variant delimiters.
///
/// Front-matter is extracted via `---` fences. The body is split on
/// `^<!-- variant: NAME -->$` lines. Content before the first variant
/// delimiter is the default example. Front-matter-only files (empty body)
/// produce an empty example and no variants.
pub fn parsePatternFile(a: Allocator, source: []const u8) !PatternFile {
    const fm_result = try frontmatter.parse(a, source) orelse
        return error.MissingFrontmatter;

    const metadata = try context_mod.combToToupee(a, fm_result.data);
    const body = std.mem.trim(u8, fm_result.content, " \t\r\n");

    if (body.len == 0) {
        return .{
            .metadata = metadata,
            .example = "",
            .variants = &.{},
        };
    }

    var example_end: usize = body.len;
    var variants = std.ArrayListUnmanaged(Variant).empty;

    var line_start: usize = 0;
    var current_variant_name: ?[]const u8 = null;
    var current_variant_start: usize = 0;

    while (line_start <= body.len) {
        const line_end = std.mem.indexOfScalarPos(u8, body, line_start, '\n') orelse body.len;
        const line = body[line_start..line_end];

        if (parseVariantDelimiter(line)) |name| {
            if (current_variant_name) |prev_name| {
                const content = std.mem.trim(u8, body[current_variant_start..line_start], " \t\r\n");
                try variants.append(a, .{ .name = prev_name, .content = content });
            } else {
                example_end = line_start;
            }
            current_variant_name = try a.dupe(u8, name);
            current_variant_start = if (line_end < body.len) line_end + 1 else line_end;
        }

        if (line_end >= body.len) break;
        line_start = line_end + 1;
    }

    if (current_variant_name) |name| {
        const content = std.mem.trim(u8, body[current_variant_start..], " \t\r\n");
        try variants.append(a, .{ .name = name, .content = content });
    }

    const example = std.mem.trim(u8, body[0..example_end], " \t\r\n");

    return .{
        .metadata = metadata,
        .example = example,
        .variants = try a.dupe(Variant, variants.items),
    };
}

/// Checks if a line matches `^<!-- variant: NAME -->$` exactly.
/// Leading whitespace prevents matching (escape mechanism for showing
/// the delimiter in example content). Trailing whitespace is tolerated.
fn parseVariantDelimiter(raw_line: []const u8) ?[]const u8 {
    const prefix = "<!-- variant: ";
    const suffix = " -->";
    if (!std.mem.startsWith(u8, raw_line, prefix)) return null;
    const trimmed_end = std.mem.trimEnd(u8, raw_line, " \t\r");
    if (!std.mem.endsWith(u8, trimmed_end, suffix)) return null;
    const name = trimmed_end[prefix.len .. trimmed_end.len - suffix.len];
    if (name.len == 0) return null;
    return name;
}

// ── Tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

test "parsePatternFile: metadata and example" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const source =
        \\---
        \\name: Button
        \\description: A clickable button
        \\---
        \\<button class="button">Click me</button>
    ;

    const result = try parsePatternFile(a, source);

    try testing.expectEqualStrings("Button", result.metadata.map.get("name").?.string);
    try testing.expectEqualStrings("A clickable button", result.metadata.map.get("description").?.string);
    try testing.expectEqualStrings("<button class=\"button\">Click me</button>", result.example);
    try testing.expectEqual(@as(usize, 0), result.variants.len);
}

test "parsePatternFile: with variants" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const source =
        \\---
        \\name: Button
        \\---
        \\<button class="button">Default</button>
        \\
        \\<!-- variant: primary -->
        \\<button class="button" data-variant="primary">Primary</button>
        \\
        \\<!-- variant: ghost -->
        \\<button class="button" data-variant="ghost">Ghost</button>
    ;

    const result = try parsePatternFile(a, source);

    try testing.expectEqualStrings("Button", result.metadata.map.get("name").?.string);
    try testing.expectEqualStrings("<button class=\"button\">Default</button>", result.example);
    try testing.expectEqual(@as(usize, 2), result.variants.len);
    try testing.expectEqualStrings("primary", result.variants[0].name);
    try testing.expectEqualStrings("<button class=\"button\" data-variant=\"primary\">Primary</button>", result.variants[0].content);
    try testing.expectEqualStrings("ghost", result.variants[1].name);
    try testing.expectEqualStrings("<button class=\"button\" data-variant=\"ghost\">Ghost</button>", result.variants[1].content);
}

test "parsePatternFile: front-matter only" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const source =
        \\---
        \\name: Reset
        \\description: CSS reset for consistent defaults
        \\---
    ;

    const result = try parsePatternFile(a, source);

    try testing.expectEqualStrings("Reset", result.metadata.map.get("name").?.string);
    try testing.expectEqualStrings("", result.example);
    try testing.expectEqual(@as(usize, 0), result.variants.len);
}

test "parsePatternFile: missing front-matter returns error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = parsePatternFile(arena.allocator(), "<button>No front-matter</button>");
    try testing.expectError(error.MissingFrontmatter, result);
}

test "parsePatternFile: empty body with newline" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const source = "---\nname: Tokens\n---\n";

    const result = try parsePatternFile(a, source);

    try testing.expectEqualStrings("Tokens", result.metadata.map.get("name").?.string);
    try testing.expectEqualStrings("", result.example);
    try testing.expectEqual(@as(usize, 0), result.variants.len);
}

test "parsePatternFile: variant immediately after front-matter" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const source =
        \\---
        \\name: Widget
        \\---
        \\<!-- variant: alt -->
        \\<div class="widget alt">Alt only</div>
    ;

    const result = try parsePatternFile(a, source);

    try testing.expectEqualStrings("", result.example);
    try testing.expectEqual(@as(usize, 1), result.variants.len);
    try testing.expectEqualStrings("alt", result.variants[0].name);
}

test "parsePatternFile: multiline example and variants" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const source =
        \\---
        \\name: Card
        \\---
        \\<div class="card">
        \\  <h2>Title</h2>
        \\  <p>Content</p>
        \\</div>
        \\
        \\<!-- variant: compact -->
        \\<div class="card" data-variant="compact">
        \\  <p>Compact</p>
        \\</div>
    ;

    const result = try parsePatternFile(a, source);

    try testing.expect(std.mem.startsWith(u8, result.example, "<div class=\"card\">"));
    try testing.expect(std.mem.endsWith(u8, result.example, "</div>"));
    try testing.expectEqual(@as(usize, 1), result.variants.len);
    try testing.expectEqualStrings("compact", result.variants[0].name);
    try testing.expect(std.mem.indexOf(u8, result.variants[0].content, "data-variant=\"compact\"") != null);
}

test "parseVariantDelimiter: valid" {
    try testing.expectEqualStrings("primary", parseVariantDelimiter("<!-- variant: primary -->").?);
    try testing.expectEqualStrings("ghost", parseVariantDelimiter("<!-- variant: ghost -->").?);
    try testing.expectEqualStrings("icon-only", parseVariantDelimiter("<!-- variant: icon-only -->").?);
}

test "parseVariantDelimiter: with trailing whitespace" {
    try testing.expectEqualStrings("spaced", parseVariantDelimiter("<!-- variant: spaced -->  ").?);
}

test "parseVariantDelimiter: leading whitespace prevents match" {
    try testing.expect(parseVariantDelimiter("  <!-- variant: spaced -->") == null);
}

test "parseVariantDelimiter: invalid" {
    try testing.expect(parseVariantDelimiter("<!-- not a variant -->") == null);
    try testing.expect(parseVariantDelimiter("<!-- variant:  -->") == null);
    try testing.expect(parseVariantDelimiter("<div>not a comment</div>") == null);
    try testing.expect(parseVariantDelimiter("") == null);
}

test "parseVariantDelimiter: single leading space escapes" {
    try testing.expect(parseVariantDelimiter(" <!-- variant: escaped -->") == null);
}

test "parseVariantDelimiter: empty name rejected" {
    try testing.expect(parseVariantDelimiter("<!-- variant:  -->") == null);
}
