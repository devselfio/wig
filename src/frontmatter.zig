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

/// Detects YAML frontmatter (--- delimited) at the start of file content.
/// Returns the parsed YAML data and the remaining content body.
/// Returns null if no frontmatter is present.
pub fn parse(a: Allocator, source: []const u8) !?FrontmatterResult {
    _ = a;
    _ = source;
    return error.NotImplemented;
}

/// Returns true if the source starts with "---\n".
pub fn hasFrontmatter(source: []const u8) bool {
    return source.len >= 4 and std.mem.eql(u8, source[0..4], "---\n");
}

const NotImplemented = error{NotImplemented};

test "frontmatter: detection" {
    try std.testing.expect(hasFrontmatter("---\ntitle: hello\n---\nbody"));
    try std.testing.expect(!hasFrontmatter("no frontmatter here"));
    try std.testing.expect(!hasFrontmatter("--\n"));
    try std.testing.expect(!hasFrontmatter(""));
}
