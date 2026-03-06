const std = @import("std");
const toupee = @import("toupee");
const scanner_mod = @import("scanner.zig");

const Allocator = std.mem.Allocator;
const root = @import("root.zig");

pub const RenderResult = struct {
    output_html: []const u8,
    search_content: []const u8,
};

/// Renders all pages in parallel. Returns search content for post-build indexing.
pub fn renderAll(
    a: Allocator,
    pages: []const scanner_mod.PageEntry,
    engine: *const toupee.Engine,
    base_ctx: *const toupee.Context,
    loader: toupee.Loader,
    content_parsers: []const root.ContentParserEntry,
    output_dir: []const u8,
) ![]RenderResult {
    _ = a;
    _ = pages;
    _ = engine;
    _ = base_ctx;
    _ = loader;
    _ = content_parsers;
    _ = output_dir;
    return error.NotImplemented;
}

/// Renders a single page through the full pipeline.
pub fn renderOne(
    a: Allocator,
    entry: scanner_mod.PageEntry,
    engine: *const toupee.Engine,
    base_ctx: *const toupee.Context,
    loader: toupee.Loader,
    content_parsers: []const root.ContentParserEntry,
) !RenderResult {
    _ = a;
    _ = entry;
    _ = engine;
    _ = base_ctx;
    _ = loader;
    _ = content_parsers;
    return error.NotImplemented;
}

const NotImplemented = error{NotImplemented};

test "pages: placeholder" {
    // Populated in Phase 6
}
