const std = @import("std");
const toupee = @import("toupee");
const config = @import("config.zig");
const scanner = @import("scanner.zig");
const pages = @import("pages.zig");
const diagnostics_mod = @import("diagnostics.zig");

const Allocator = std.mem.Allocator;

pub const Hook = *const fn (*BuildContext) anyerror!void;

pub const Hooks = struct {
    pre_scan: []const Hook = &.{},
    post_scan: []const Hook = &.{},
    pre_render: []const Hook = &.{},
    post_render: []const Hook = &.{},
    post_build: []const Hook = &.{},
};

pub const BuildContext = struct {
    allocator: Allocator,
    arena: Allocator,
    abs_root: []const u8,
    site_cfg: *const config.SiteConfig,
    style_cfgs: []config.StyleConfig,
    engine: *toupee.Engine,
    template_map: *std.StringArrayHashMapUnmanaged([]const u8),
    style_ctx: *toupee.Context,
    scan_result: ?*scanner.ScanResult = null,
    content_parsers: []const pages.ContentParserEntry = &.{},
    transform_registry: *const toupee.transform.Registry,
    diagnostics: *diagnostics_mod.Collector,
    hooks: Hooks = .{},
};
