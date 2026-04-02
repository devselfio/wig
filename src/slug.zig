const std = @import("std");
const Allocator = std.mem.Allocator;

/// Converts a filename stem to a URL-friendly slug: underscores to hyphens, lowercased.
pub fn slugifyStem(a: Allocator, stem: []const u8) ![]u8 {
    const buf = try a.alloc(u8, stem.len);
    for (stem, buf) |c, *out| {
        out.* = if (c == '_') '-' else std.ascii.toLower(c);
    }
    return buf;
}

/// Stems that should never be slugified: _index, index, _NNN error pages.
pub fn isSpecialStem(stem: []const u8) bool {
    if (std.mem.eql(u8, stem, "_index") or std.mem.eql(u8, stem, "index")) return true;
    if (stem.len >= 2 and stem[0] == '_') {
        for (stem[1..]) |c| {
            if (!std.ascii.isDigit(c)) return false;
        }
        return true;
    }
    return false;
}

/// Slugifies a taxonomy term: lowercase ASCII, spaces to hyphens.
pub fn slugifyTerm(a: Allocator, term: []const u8) ![]const u8 {
    const buf = try a.alloc(u8, term.len);
    for (term, 0..) |c, i| {
        buf[i] = if (c == ' ') '-' else std.ascii.toLower(c);
    }
    return buf;
}

// ── Tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

test "slugifyStem: underscores to hyphens" {
    const a = testing.allocator;
    const r = try slugifyStem(a, "my_post");
    defer a.free(r);
    try testing.expectEqualStrings("my-post", r);
}

test "slugifyStem: uppercase to lowercase" {
    const a = testing.allocator;
    const r = try slugifyStem(a, "MyPost");
    defer a.free(r);
    try testing.expectEqualStrings("mypost", r);
}

test "slugifyStem: mixed" {
    const a = testing.allocator;
    const r = try slugifyStem(a, "001_First_Post");
    defer a.free(r);
    try testing.expectEqualStrings("001-first-post", r);
}

test "isSpecialStem: _index" {
    try testing.expect(isSpecialStem("_index"));
}

test "isSpecialStem: index" {
    try testing.expect(isSpecialStem("index"));
}

test "isSpecialStem: _404" {
    try testing.expect(isSpecialStem("_404"));
}

test "isSpecialStem: _500" {
    try testing.expect(isSpecialStem("_500"));
}

test "isSpecialStem: regular stems" {
    try testing.expect(!isSpecialStem("about"));
    try testing.expect(!isSpecialStem("my-post"));
    try testing.expect(!isSpecialStem("_draft"));
}

test "slugifyTerm: spaces to hyphens" {
    const a = testing.allocator;
    const r = try slugifyTerm(a, "Hello World");
    defer a.free(r);
    try testing.expectEqualStrings("hello-world", r);
}

test "slugifyTerm: already lowercase" {
    const a = testing.allocator;
    const r = try slugifyTerm(a, "zig");
    defer a.free(r);
    try testing.expectEqualStrings("zig", r);
}
