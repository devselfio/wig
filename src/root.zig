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
