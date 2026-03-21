const std = @import("std");
const comb = @import("comb");

const Allocator = std.mem.Allocator;

pub const FrontmatterResult = struct {
    data: comb.Value,
    content: []const u8,
    parsed: comb.Parsed(comb.Value),

    pub fn deinit(self: *FrontmatterResult) void {
        self.parsed.deinit();
    }
};

/// Detects YAML frontmatter (`---` delimited) at the start of file content.
/// Returns the parsed YAML data and the remaining content body, or null
/// if no frontmatter is present. The returned `content` slice borrows from
/// `source`; the `data` borrows from both the parse tree and `source`.
pub fn parse(a: Allocator, source: []const u8) !?FrontmatterResult {
    if (!hasFrontmatter(source)) return null;

    const after_open = source[4..];
    const close_idx = findClosingFence(after_open) orelse
        return error.UnclosedFrontmatter;

    const yaml_slice = after_open[0..close_idx];
    const content_start = 4 + close_idx + 4;
    const content = if (content_start <= source.len) source[content_start..] else "";

    const parsed = comb.parse(a, yaml_slice) catch
        return error.InvalidFrontmatter;

    return .{
        .data = parsed.value,
        .content = content,
        .parsed = parsed,
    };
}

/// Returns true if the source starts with `---\n`.
pub fn hasFrontmatter(source: []const u8) bool {
    return source.len >= 4 and std.mem.eql(u8, source[0..4], "---\n");
}

/// Finds the closing `---\n` fence in the text after the opening fence.
/// Returns the byte offset of the start of the closing fence, or null.
fn findClosingFence(text: []const u8) ?usize {
    var pos: usize = 0;
    while (pos < text.len) {
        if (pos + 4 <= text.len and std.mem.eql(u8, text[pos .. pos + 4], "---\n")) {
            return pos;
        }
        if (std.mem.indexOfScalar(u8, text[pos..], '\n')) |nl| {
            pos += nl + 1;
        } else {
            break;
        }
    }
    if (text.len >= 3 and std.mem.eql(u8, text[text.len - 3 ..], "---")) {
        return text.len - 3;
    }
    return null;
}

pub const NormalizePageFrontmatterError = error{ InvalidWigPageFrontmatter, OutOfMemory };

/// Normalizes page YAML to the canonical shape the rest of Wig expects: a single top-level
/// `document` mapping whose value is the **YAML root object** (every root key copied under `document`).
///
/// There is no special case for a sole root key `document:` — that key becomes `document.document`
/// in template context (see `test/035_frontmatter_document_key.yaml`). To set `document.title`,
/// use a root-level `title:` key (or any other key name that should live directly under `document`).
///
/// Empty fence body `---\n---` becomes `document: {}`. Scalars, arrays, or `document:` with a
/// non-mapping value at the root are rejected.
pub fn normalizeWigPageFrontmatter(a: Allocator, root: comb.Value) NormalizePageFrontmatterError!comb.Value {
    switch (root) {
        .null_val => {
            const doc_key: comb.Value = .{ .string = try a.dupe(u8, "document") };
            const empty_doc: comb.Value = .{ .object = &.{} };
            const outer = try a.dupe(comb.Entry, &[_]comb.Entry{
                .{ .key = doc_key, .value = empty_doc },
            });
            return .{ .object = outer };
        },
        .object => |entries| {
            if (entries.len == 1) {
                const e0 = entries[0];
                switch (e0.key) {
                    .string => |s| {
                        if (std.mem.eql(u8, s, "document") and e0.value != .object) {
                            return error.InvalidWigPageFrontmatter;
                        }
                    },
                    else => {},
                }
            }
            const doc_key: comb.Value = .{ .string = try a.dupe(u8, "document") };
            const outer = try a.dupe(comb.Entry, &[_]comb.Entry{
                .{ .key = doc_key, .value = .{ .object = entries } },
            });
            return .{ .object = outer };
        },
        else => return error.InvalidWigPageFrontmatter,
    }
}

/// True if `root` is already `{ document: <mapping> }` (post-normalize shape).
pub fn validateWigPageFrontmatterRoot(root: comb.Value) error{InvalidWigPageFrontmatter}!void {
    const entries = switch (root) {
        .object => |o| o,
        else => return error.InvalidWigPageFrontmatter,
    };
    if (entries.len != 1) return error.InvalidWigPageFrontmatter;
    const e0 = entries[0];
    const key_str = switch (e0.key) {
        .string => |s| s,
        else => return error.InvalidWigPageFrontmatter,
    };
    if (!std.mem.eql(u8, key_str, "document")) return error.InvalidWigPageFrontmatter;
    switch (e0.value) {
        .object => {},
        else => return error.InvalidWigPageFrontmatter,
    }
}

// ── Tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

test "hasFrontmatter: valid" {
    try testing.expect(hasFrontmatter("---\ntitle: hello\n---\nbody"));
    try testing.expect(hasFrontmatter("---\n---\n"));
    try testing.expect(hasFrontmatter("---\nkey: val\n---\n"));
}

test "hasFrontmatter: invalid" {
    try testing.expect(!hasFrontmatter("no frontmatter here"));
    try testing.expect(!hasFrontmatter("--\n"));
    try testing.expect(!hasFrontmatter(""));
    try testing.expect(!hasFrontmatter("---"));
    try testing.expect(!hasFrontmatter("-- -\n"));
}

test "parse: simple YAML frontmatter" {
    const source = "---\ntitle: Hello\nauthor: Alice\n---\nBody content here.";
    var result = (try parse(testing.allocator, source)).?;
    defer result.deinit();

    try testing.expectEqualStrings("Hello", result.data.getStr("title").?);
    try testing.expectEqualStrings("Alice", result.data.getStr("author").?);
    try testing.expectEqualStrings("Body content here.", result.content);
}

test "parse: empty frontmatter" {
    const source = "---\n---\nSome content.";
    var result = (try parse(testing.allocator, source)).?;
    defer result.deinit();

    try testing.expectEqualStrings("Some content.", result.content);
}

test "parse: no frontmatter returns null" {
    const result = try parse(testing.allocator, "Just plain text.");
    try testing.expect(result == null);
}

test "parse: frontmatter with no trailing content" {
    const source = "---\nkey: value\n---\n";
    var result = (try parse(testing.allocator, source)).?;
    defer result.deinit();

    try testing.expectEqualStrings("value", result.data.getStr("key").?);
    try testing.expectEqualStrings("", result.content);
}

test "parse: multiline content after frontmatter" {
    const source = "---\ntitle: Test\n---\nLine 1\nLine 2\nLine 3";
    var result = (try parse(testing.allocator, source)).?;
    defer result.deinit();

    try testing.expectEqualStrings("Test", result.data.getStr("title").?);
    try testing.expectEqualStrings("Line 1\nLine 2\nLine 3", result.content);
}

test "parse: unclosed frontmatter returns error" {
    const source = "---\ntitle: Hello\nno closing fence";
    const result = parse(testing.allocator, source);
    try testing.expectError(error.UnclosedFrontmatter, result);
}

test "parse: frontmatter with nested YAML" {
    const source = "---\nmeta:\n  version: 2\n  active: true\n---\ncontent";
    var result = (try parse(testing.allocator, source)).?;
    defer result.deinit();

    const meta = result.data.get("meta").?;
    try testing.expectEqualStrings("content", result.content);
    try testing.expect(meta.get("version") != null);
}

test "parse: frontmatter ending at EOF without trailing newline" {
    const source = "---\nkey: val\n---";
    var result = (try parse(testing.allocator, source)).?;
    defer result.deinit();

    try testing.expectEqualStrings("val", result.data.getStr("key").?);
    try testing.expectEqualStrings("", result.content);
}

test "parse: content with dashes that are not fences" {
    const source = "---\ntitle: Test\n---\nSome text with --- dashes in it.";
    var result = (try parse(testing.allocator, source)).?;
    defer result.deinit();

    try testing.expectEqualStrings("Test", result.data.getStr("title").?);
    try testing.expectEqualStrings("Some text with --- dashes in it.", result.content);
}

test "parse: boolean values in frontmatter" {
    const source = "---\ndraft: true\ndebug: false\n---\nbody";
    var result = (try parse(testing.allocator, source)).?;
    defer result.deinit();

    const draft = result.data.get("draft").?;
    try testing.expect(draft == .boolean);
    try testing.expect(draft.boolean == true);
    try testing.expectEqualStrings("body", result.content);
}

test "findClosingFence: basic" {
    try testing.expectEqual(@as(?usize, 12), findClosingFence("title: Test\n---\n"));
    try testing.expectEqual(@as(?usize, 0), findClosingFence("---\n"));
    try testing.expect(findClosingFence("no fence here") == null);
}

test "normalizeWigPageFrontmatter: flat keys become document.*" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var p = try comb.parse(testing.allocator, "title: Hi\ndraft: true\n");
    defer p.deinit();
    const n = try normalizeWigPageFrontmatter(a, p.value);
    try validateWigPageFrontmatterRoot(n);
    const doc = n.get("document").?;
    try testing.expectEqualStrings("Hi", doc.getStr("title").?);
    try testing.expect(doc.get("draft").?.boolean);
}

test "normalizeWigPageFrontmatter: sole root document: becomes document.document.*" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var p = try comb.parse(testing.allocator, "document:\n  title: Hi\n");
    defer p.deinit();
    const n = try normalizeWigPageFrontmatter(a, p.value);
    try validateWigPageFrontmatterRoot(n);
    const inner = n.get("document").?.get("document").?;
    try testing.expectEqualStrings("Hi", inner.getStr("title").?);
    try testing.expect(n.get("document").?.get("title") == null);
}

test "normalizeWigPageFrontmatter: null root is empty document" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const n = try normalizeWigPageFrontmatter(a, .null_val);
    try validateWigPageFrontmatterRoot(n);
    try testing.expectEqual(@as(usize, 0), n.get("document").?.object.len);
}

test "normalizeWigPageFrontmatter: rejects scalar root" {
    const a = testing.allocator;
    try testing.expectError(error.InvalidWigPageFrontmatter, normalizeWigPageFrontmatter(a, .{ .integer = 42 }));
}

test "normalizeWigPageFrontmatter: rejects document non-map" {
    const a = testing.allocator;
    var p = try comb.parse(a, "document: hello\n");
    defer p.deinit();
    try testing.expectError(error.InvalidWigPageFrontmatter, normalizeWigPageFrontmatter(a, p.value));
}

test "parse + normalize: empty fence body" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = "---\n---\nSome content.";
    var result = (try parse(testing.allocator, source)).?;
    defer result.deinit();
    const n = try normalizeWigPageFrontmatter(a, result.data);
    try validateWigPageFrontmatterRoot(n);
    try testing.expectEqual(@as(usize, 0), n.get("document").?.object.len);
}
