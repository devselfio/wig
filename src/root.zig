const std = @import("std");
pub const toupee = @import("toupee");
pub const comb = @import("comb");
pub const zjot = @import("zjot");

const Allocator = std.mem.Allocator;

pub const config = @import("config.zig");
pub const context = @import("context.zig");
pub const tokens = @import("tokens.zig");
pub const colours = @import("colours.zig");
pub const frontmatter = @import("frontmatter.zig");
pub const bundles = @import("bundles.zig");
pub const scanner = @import("scanner.zig");
pub const taxonomies = @import("taxonomies.zig");
pub const pages = @import("pages.zig");
pub const toc_mod = @import("toc.zig");
pub const search = @import("search.zig");
pub const feeds = @import("feeds.zig");
pub const patterns = @import("patterns.zig");
pub const app = @import("app.zig");
pub const router = @import("router.zig");
pub const handler = @import("handler.zig");
pub const session = @import("session.zig");
pub const scaffold = @import("scaffold.zig");

pub const WigError = error{
    NotImplemented,
    InvalidConfig,
    MissingConfig,
    MissingUrl,
    DualConfig,
    MissingFrontmatter,
    PathCollision,
    UnrecognisedExtension,
    MissingTemplate,
    BuildFailed,
};

pub const ContentParser = pages.ContentParser;
pub const ContentParserEntry = pages.ContentParserEntry;

pub fn zjotParser(a: Allocator, source: []const u8) anyerror![]const u8 {
    return zjot.toHtml(a, source);
}

pub const SiteOptions = struct {
    root: []const u8 = ".",
    draft: bool = false,
    debug: bool = false,
    content_parsers: []const ContentParserEntry = &.{
        .{ .extension = ".dj", .parse = zjotParser },
    },
};

pub const BuildOptions = struct {
    clean: bool = false,
};

pub const ValidateOptions = struct {
    external_links: bool = false,
};

/// Two-phase site struct. `init()` loads config (phase 1).
/// `buildAll()` computes tokens, builds CSS, renders pages (phase 2).
/// After `buildAll()`, the engine and build state are available for
/// custom route handlers in the dev server.
pub const Site = struct {
    allocator: Allocator,
    options: SiteOptions,
    engine: ?toupee.Engine = null,

    pub fn init(a: Allocator, options: SiteOptions) WigError!Site {
        _ = options.root;
        return .{ .allocator = a, .options = options };
    }

    pub fn deinit(self: *Site) void {
        if (self.engine) |*e| e.deinit();
    }

    pub fn buildAll(self: *Site, options: BuildOptions) !void {
        _ = self;
        _ = options;
        return error.NotImplemented;
    }

    pub fn validate(self: *const Site, options: ValidateOptions) !void {
        _ = self;
        _ = options;
        return error.NotImplemented;
    }
};

pub fn devServer(site: *Site) !*app.App {
    _ = site;
    return error.NotImplemented;
}

test {
    _ = config;
    _ = context;
    _ = tokens;
    _ = colours;
    _ = frontmatter;
    _ = bundles;
    _ = scanner;
    _ = taxonomies;
    _ = pages;
    _ = toc_mod;
    _ = search;
    _ = feeds;
    _ = patterns;
    _ = app;
    _ = router;
    _ = handler;
    _ = session;
    _ = scaffold;
}

test "E2E: data pipeline loads config, computes tokens, renders template" {
    const testing_alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(testing_alloc);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("data");
    try tmp.dir.makePath("styles/default");

    {
        var dir = try tmp.dir.openDir("data", .{});
        defer dir.close();
        var f = try dir.createFile("site.yaml", .{});
        try f.writeAll("url: https://example.com\ntitle: E2E Test");
        f.close();
    }
    {
        var dir = try tmp.dir.openDir("styles/default", .{});
        defer dir.close();
        var f = try dir.createFile("style.yaml", .{});
        try f.writeAll(
            \\viewport:
            \\  min: 320
            \\  max: 1240
            \\typography:
            \\  base:
            \\    min: 18
            \\    max: 20
            \\  scale:
            \\    min: 1.2
            \\    max: 1.25
            \\  steps:
            \\    above: 2
            \\    below: 1
        );
        f.close();
    }

    const abs = try tmp.dir.realpathAlloc(a, ".");

    var site_cfg = try config.loadSiteConfig(a, abs);
    defer site_cfg.deinit();

    const style_cfgs = try config.loadStyleConfigs(a, abs);
    try std.testing.expect(style_cfgs.len == 1);

    const params = try tokens.extractParams(style_cfgs[0].raw, a);
    var token_result = try tokens.compute(a, params);
    defer token_result.deinit();

    var ctx = toupee.Context.init(a);
    const site_val = try context.combToToupee(a, site_cfg.raw);
    try ctx.put("site", site_val);
    try ctx.put("tokens", token_result.value);

    var resolver: toupee.Resolver = .{};
    const html = try toupee.render(
        a,
        "<h1><t-var name=\"site.title\">default</t-var></h1>",
        &ctx,
        resolver.loader(),
        .{},
    );
    try std.testing.expectEqualStrings("<h1>E2E Test</h1>", html);

    const html2 = try toupee.render(
        a,
        "<t-if var=\"tokens.typography\">has-tokens</t-if>",
        &ctx,
        resolver.loader(),
        .{},
    );
    try std.testing.expectEqualStrings("has-tokens", html2);
}
