const std = @import("std");
const comb = @import("comb");

const Allocator = std.mem.Allocator;

pub const SiteConfig = struct {
    url: []const u8,
    title: []const u8 = "",
    taxonomies: []const []const u8 = &.{},
    raw: comb.Value = .{ .null_val = {} },
};

pub const StyleConfig = struct {
    name: []const u8,
    manifest_path: []const u8,
    raw: comb.Value = .{ .null_val = {} },
};

pub fn loadSiteConfig(a: Allocator, root: []const u8) !SiteConfig {
    _ = a;
    _ = root;
    return error.NotImplemented;
}

pub fn loadStyleConfigs(a: Allocator, root: []const u8) ![]StyleConfig {
    _ = a;
    _ = root;
    return error.NotImplemented;
}

pub fn loadDataFiles(a: Allocator, root: []const u8) !void {
    _ = a;
    _ = root;
    return error.NotImplemented;
}

const NotImplemented = error{NotImplemented};

test {
    _ = SiteConfig;
    _ = StyleConfig;
}
