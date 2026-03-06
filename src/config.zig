const std = @import("std");
const comb = @import("comb");
const context_mod = @import("context.zig");
const toupee = @import("toupee");

const Allocator = std.mem.Allocator;
const fs = std.fs;

const ValueMap = std.StringArrayHashMapUnmanaged(toupee.Value);

pub const FeedConfig = struct {
    name: []const u8,
    collection_path: []const u8,
    title: []const u8,
};

/// Parsed site-level configuration from `data/site.yaml` or `data/site.json`.
pub const SiteConfig = struct {
    url: []const u8,
    title: []const u8,
    taxonomies: []const []const u8,
    feeds: []const FeedConfig,
    raw: comb.Value,
    _parsed: comb.Parsed(comb.Value),
    _source: []const u8,
    _allocator: Allocator,

    pub fn deinit(self: *SiteConfig) void {
        if (self.taxonomies.len > 0) self._allocator.free(self.taxonomies);
        if (self.feeds.len > 0) self._allocator.free(self.feeds);
        self._parsed.deinit();
        self._allocator.free(self._source);
    }
};

/// Parsed style manifest from `styles/{name}/style.yaml`.
pub const StyleConfig = struct {
    name: []const u8,
    raw: comb.Value,
    _parsed: comb.Parsed(comb.Value),
    _source: []const u8,
    _allocator: Allocator,

    pub fn deinit(self: *StyleConfig) void {
        self._parsed.deinit();
        self._allocator.free(self._source);
        self._allocator.free(self.name);
    }
};

const ExtractedConfig = struct {
    url: []const u8,
    title: []const u8,
    taxonomies: []const []const u8,
    feeds: []const FeedConfig,
};

const ParsedFile = struct {
    source: []const u8,
    parsed: comb.Parsed(comb.Value),
};

/// All data files from `data/` (excluding site config), translated to
/// Toupee values in a nested namespace map.
pub const DataResult = struct {
    value: toupee.Value,
    _files: std.ArrayListUnmanaged(ParsedFile),
    _owned_keys: std.ArrayListUnmanaged([]const u8),
    _allocator: Allocator,

    pub fn deinit(self: *DataResult) void {
        freeValueMap(self._allocator, &self.value.map);
        for (self._owned_keys.items) |k| self._allocator.free(k);
        self._owned_keys.deinit(self._allocator);
        for (self._files.items) |*f| {
            f.parsed.deinit();
            self._allocator.free(f.source);
        }
        self._files.deinit(self._allocator);
    }
};

/// Recursively frees all ValueMap entries and nested maps/lists.
fn freeValueMap(a: Allocator, map: *ValueMap) void {
    for (map.values()) |*v| {
        freeValue(a, v);
    }
    map.deinit(a);
}

fn freeValue(a: Allocator, v: *toupee.Value) void {
    switch (v.*) {
        .map => |*m| freeValueMap(a, m),
        .list => |items| {
            for (@constCast(items)) |*item| freeValue(a, item);
            a.free(items);
        },
        else => {},
    }
}

fn extractConfig(val: comb.Value, a: Allocator) !ExtractedConfig {
    const url = val.getStr("url") orelse
        return error.MissingUrl;

    const title = val.getStr("title") orelse "";

    const taxonomies = if (val.getArray("taxonomies")) |arr| blk: {
        const items = try a.alloc([]const u8, arr.len);
        var count: usize = 0;
        for (arr) |item| {
            switch (item) {
                .string => |s| {
                    items[count] = s;
                    count += 1;
                },
                else => {},
            }
        }
        break :blk items[0..count];
    } else &[_][]const u8{};

    const feeds = if (val.get("feeds")) |feeds_val| blk: {
        const entries = switch (feeds_val) {
            .object => |o| o,
            else => break :blk &[_]FeedConfig{},
        };
        const items = try a.alloc(FeedConfig, entries.len);
        var count: usize = 0;
        for (entries) |entry| {
            const name = switch (entry.key) {
                .string => |s| s,
                else => continue,
            };
            const feed_obj = entry.value;
            items[count] = .{
                .name = name,
                .collection_path = feed_obj.getStr("collection") orelse continue,
                .title = feed_obj.getStr("title") orelse name,
            };
            count += 1;
        }
        break :blk items[0..count];
    } else &[_]FeedConfig{};

    return .{
        .url = url,
        .title = title,
        .taxonomies = taxonomies,
        .feeds = feeds,
    };
}

pub fn loadSiteConfig(a: Allocator, root: []const u8) !SiteConfig {
    const data_path = try fs.path.join(a, &.{ root, "data" });
    defer a.free(data_path);

    var data_dir = fs.openDirAbsolute(data_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return error.MissingConfig,
        else => return err,
    };
    defer data_dir.close();

    const has_yaml = fileExists(data_dir, "site.yaml");
    const has_json = fileExists(data_dir, "site.json");

    if (has_yaml and has_json) return error.DualConfig;
    if (!has_yaml and !has_json) return error.MissingConfig;

    const filename: []const u8 = if (has_yaml) "site.yaml" else "site.json";
    const contents = try data_dir.readFileAlloc(a, filename, 1024 * 1024);
    errdefer a.free(contents);

    var parsed = comb.parse(a, contents) catch
        return error.InvalidConfig;
    errdefer parsed.deinit();

    const extracted = try extractConfig(parsed.value, a);

    return .{
        .url = extracted.url,
        .title = extracted.title,
        .taxonomies = extracted.taxonomies,
        .feeds = extracted.feeds,
        .raw = parsed.value,
        ._parsed = parsed,
        ._source = contents,
        ._allocator = a,
    };
}

pub fn loadStyleConfigs(a: Allocator, root: []const u8) ![]StyleConfig {
    const styles_path = try fs.path.join(a, &.{ root, "styles" });
    defer a.free(styles_path);

    var styles_dir = fs.openDirAbsolute(styles_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return &[_]StyleConfig{},
        else => return err,
    };
    defer styles_dir.close();

    var configs: std.ArrayListUnmanaged(StyleConfig) = .empty;
    errdefer {
        for (configs.items) |*c| c.deinit();
        configs.deinit(a);
    }

    var it = styles_dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .directory) continue;

        var sub_dir = styles_dir.openDir(entry.name, .{}) catch continue;
        defer sub_dir.close();

        if (!fileExists(sub_dir, "style.yaml")) continue;

        const contents = sub_dir.readFileAlloc(a, "style.yaml", 1024 * 1024) catch continue;
        errdefer a.free(contents);

        var parsed = comb.parse(a, contents) catch {
            a.free(contents);
            continue;
        };
        errdefer parsed.deinit();

        try configs.append(a, .{
            .name = try a.dupe(u8, entry.name),
            .raw = parsed.value,
            ._parsed = parsed,
            ._source = contents,
            ._allocator = a,
        });
    }

    return try configs.toOwnedSlice(a);
}

/// Loads all data files from `data/` into a nested Toupee value namespace.
/// Both `.yaml`/`.yml` and `.json` files are parsed via Comb.
pub fn loadDataFiles(a: Allocator, root: []const u8) !DataResult {
    const data_path = try fs.path.join(a, &.{ root, "data" });
    defer a.free(data_path);

    var namespace = ValueMap{};
    var files: std.ArrayListUnmanaged(ParsedFile) = .empty;
    var owned_keys: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        freeValueMap(a, &namespace);
        for (owned_keys.items) |k| a.free(k);
        owned_keys.deinit(a);
        for (files.items) |*f| {
            f.parsed.deinit();
            a.free(f.source);
        }
        files.deinit(a);
    }

    var data_dir = fs.openDirAbsolute(data_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return .{
            .value = .{ .map = namespace },
            ._files = files,
            ._owned_keys = owned_keys,
            ._allocator = a,
        },
        else => return err,
    };
    defer data_dir.close();

    try scanDataDir(a, data_dir, &namespace, &files, &owned_keys, true);

    return .{
        .value = .{ .map = namespace },
        ._files = files,
        ._owned_keys = owned_keys,
        ._allocator = a,
    };
}

/// Recursively scans a data directory, loading files into the namespace map.
/// `is_root` controls whether site config files (site.yaml/json) are skipped.
fn scanDataDir(
    a: Allocator,
    dir: fs.Dir,
    namespace: *ValueMap,
    files: *std.ArrayListUnmanaged(ParsedFile),
    owned_keys: *std.ArrayListUnmanaged([]const u8),
    is_root: bool,
) !void {
    var it = dir.iterate();
    while (try it.next()) |entry| {
        switch (entry.kind) {
            .file => {
                const ext = fs.path.extension(entry.name);
                const is_data_file = std.mem.eql(u8, ext, ".yaml") or
                    std.mem.eql(u8, ext, ".yml") or
                    std.mem.eql(u8, ext, ".json");
                if (!is_data_file) continue;

                if (is_root and isSiteConfigFile(entry.name)) continue;

                const stem = entry.name[0 .. entry.name.len - ext.len];
                if (namespace.contains(stem)) return error.PathCollision;

                const contents = try dir.readFileAlloc(a, entry.name, 1024 * 1024);
                errdefer a.free(contents);

                var parsed = try comb.parse(a, contents);
                errdefer parsed.deinit();

                const toupee_val = try context_mod.combToToupee(a, parsed.value);

                const key = try a.dupe(u8, stem);
                errdefer a.free(key);
                try owned_keys.append(a, key);

                try namespace.put(a, key, toupee_val);
                try files.append(a, .{ .source = contents, .parsed = parsed });
            },
            .directory => {
                const key = try a.dupe(u8, entry.name);
                errdefer a.free(key);
                try owned_keys.append(a, key);

                if (namespace.contains(key)) return error.PathCollision;

                var sub_map = ValueMap{};
                errdefer freeValueMap(a, &sub_map);

                var sub_dir = try dir.openDir(entry.name, .{ .iterate = true });
                defer sub_dir.close();

                try scanDataDir(a, sub_dir, &sub_map, files, owned_keys, false);
                try namespace.put(a, key, .{ .map = sub_map });
            },
            else => {},
        }
    }
}

fn isSiteConfigFile(name: []const u8) bool {
    return std.mem.eql(u8, name, "site.yaml") or
        std.mem.eql(u8, name, "site.json") or
        std.mem.eql(u8, name, "site.yml");
}

fn fileExists(dir: fs.Dir, name: []const u8) bool {
    dir.access(name, .{}) catch return false;
    return true;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "extractConfig: valid YAML with all fields" {
    const yaml =
        \\url: https://example.com
        \\title: My Site
        \\taxonomies:
        \\  - tags
        \\  - categories
        \\feeds:
        \\  blog:
        \\    collection: pages.posts
        \\    title: Blog Feed
    ;

    var parsed = try comb.parse(std.testing.allocator, yaml);
    defer parsed.deinit();

    const cfg = try extractConfig(parsed.value, std.testing.allocator);
    defer std.testing.allocator.free(cfg.taxonomies);
    defer std.testing.allocator.free(cfg.feeds);

    try std.testing.expectEqualStrings("https://example.com", cfg.url);
    try std.testing.expectEqualStrings("My Site", cfg.title);
    try std.testing.expectEqual(@as(usize, 2), cfg.taxonomies.len);
    try std.testing.expectEqualStrings("tags", cfg.taxonomies[0]);
    try std.testing.expectEqualStrings("categories", cfg.taxonomies[1]);
    try std.testing.expectEqual(@as(usize, 1), cfg.feeds.len);
    try std.testing.expectEqualStrings("blog", cfg.feeds[0].name);
    try std.testing.expectEqualStrings("pages.posts", cfg.feeds[0].collection_path);
    try std.testing.expectEqualStrings("Blog Feed", cfg.feeds[0].title);
}

test "extractConfig: valid JSON" {
    const json =
        \\{"url": "https://example.com", "title": "JSON Site"}
    ;

    var parsed = try comb.parse(std.testing.allocator, json);
    defer parsed.deinit();

    const cfg = try extractConfig(parsed.value, std.testing.allocator);

    try std.testing.expectEqualStrings("https://example.com", cfg.url);
    try std.testing.expectEqualStrings("JSON Site", cfg.title);
}

test "extractConfig: missing url returns error" {
    const yaml =
        \\title: No URL
    ;

    var parsed = try comb.parse(std.testing.allocator, yaml);
    defer parsed.deinit();

    const result = extractConfig(parsed.value, std.testing.allocator);
    try std.testing.expectError(error.MissingUrl, result);
}

test "extractConfig: minimal config with only url" {
    const yaml =
        \\url: https://example.com
    ;

    var parsed = try comb.parse(std.testing.allocator, yaml);
    defer parsed.deinit();

    const cfg = try extractConfig(parsed.value, std.testing.allocator);

    try std.testing.expectEqualStrings("https://example.com", cfg.url);
    try std.testing.expectEqualStrings("", cfg.title);
    try std.testing.expectEqual(@as(usize, 0), cfg.taxonomies.len);
    try std.testing.expectEqual(@as(usize, 0), cfg.feeds.len);
}

test "extractConfig: feeds with default title" {
    const yaml =
        \\url: https://example.com
        \\feeds:
        \\  blog:
        \\    collection: pages.posts
    ;

    var parsed = try comb.parse(std.testing.allocator, yaml);
    defer parsed.deinit();

    const cfg = try extractConfig(parsed.value, std.testing.allocator);
    defer std.testing.allocator.free(cfg.feeds);

    try std.testing.expectEqual(@as(usize, 1), cfg.feeds.len);
    try std.testing.expectEqualStrings("blog", cfg.feeds[0].title);
}

test "loadSiteConfig: missing data directory" {
    const result = loadSiteConfig(std.testing.allocator, "/nonexistent/path");
    try std.testing.expectError(error.MissingConfig, result);
}

test "loadSiteConfig: dual config error" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("data");
    var data_dir = try tmp.dir.openDir("data", .{});
    defer data_dir.close();

    var f1 = try data_dir.createFile("site.yaml", .{});
    try f1.writeAll("url: https://example.com");
    f1.close();
    var f2 = try data_dir.createFile("site.json", .{});
    try f2.writeAll("{\"url\": \"https://example.com\"}");
    f2.close();

    const abs = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(abs);

    const result = loadSiteConfig(std.testing.allocator, abs);
    try std.testing.expectError(error.DualConfig, result);
}

test "loadSiteConfig: loads YAML" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("data");
    var data_dir = try tmp.dir.openDir("data", .{});
    defer data_dir.close();
    var f = try data_dir.createFile("site.yaml", .{});
    try f.writeAll("url: https://example.com\ntitle: Test Site");
    f.close();

    const abs = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(abs);

    var cfg = try loadSiteConfig(std.testing.allocator, abs);
    defer cfg.deinit();

    try std.testing.expectEqualStrings("https://example.com", cfg.url);
    try std.testing.expectEqualStrings("Test Site", cfg.title);
}

test "loadSiteConfig: loads JSON" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("data");
    var data_dir = try tmp.dir.openDir("data", .{});
    defer data_dir.close();
    var f = try data_dir.createFile("site.json", .{});
    try f.writeAll("{\"url\": \"https://example.com\", \"title\": \"JSON\"}");
    f.close();

    const abs = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(abs);

    var cfg = try loadSiteConfig(std.testing.allocator, abs);
    defer cfg.deinit();

    try std.testing.expectEqualStrings("https://example.com", cfg.url);
    try std.testing.expectEqualStrings("JSON", cfg.title);
}

test "loadStyleConfigs: discovers style directories" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("styles/_core");
    try tmp.dir.makePath("styles/default");

    var default_dir = try tmp.dir.openDir("styles/default", .{});
    defer default_dir.close();
    var f = try default_dir.createFile("style.yaml", .{});
    try f.writeAll("name: Default\ntokens:\n  viewport:\n    min: 320");
    f.close();

    const abs = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(abs);

    const configs = try loadStyleConfigs(std.testing.allocator, abs);
    defer {
        for (configs) |*c| @constCast(c).deinit();
        std.testing.allocator.free(configs);
    }

    try std.testing.expectEqual(@as(usize, 1), configs.len);
    try std.testing.expectEqualStrings("default", configs[0].name);
}

test "loadStyleConfigs: skips directories without style.yaml" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("styles/_core");
    try tmp.dir.makePath("styles/empty");

    const abs = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(abs);

    const configs = try loadStyleConfigs(std.testing.allocator, abs);
    defer std.testing.allocator.free(configs);

    try std.testing.expectEqual(@as(usize, 0), configs.len);
}

test "loadDataFiles: loads nested namespace" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("data/colours");

    var colours_dir = try tmp.dir.openDir("data/colours", .{});
    defer colours_dir.close();
    var cf = try colours_dir.createFile("solarized.yaml", .{});
    try cf.writeAll("name: Solarized\ntype: dark");
    cf.close();

    const abs = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(abs);

    var result = try loadDataFiles(std.testing.allocator, abs);
    defer result.deinit();

    const colours_val = result.value.map.get("colours") orelse
        return error.TestUnexpectedResult;
    const solarized = colours_val.map.get("solarized") orelse
        return error.TestUnexpectedResult;
    const name = solarized.map.get("name") orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("Solarized", name.string);
}

test "loadDataFiles: skips site.yaml" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("data");
    var data_dir = try tmp.dir.openDir("data", .{});
    defer data_dir.close();

    var sf = try data_dir.createFile("site.yaml", .{});
    try sf.writeAll("url: https://example.com");
    sf.close();

    var af = try data_dir.createFile("authors.yaml", .{});
    try af.writeAll("name: Alice");
    af.close();

    const abs = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(abs);

    var result = try loadDataFiles(std.testing.allocator, abs);
    defer result.deinit();

    try std.testing.expect(result.value.map.get("site") == null);
    try std.testing.expect(result.value.map.get("authors") != null);
}

test "loadDataFiles: empty data directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("data");

    const abs = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(abs);

    var result = try loadDataFiles(std.testing.allocator, abs);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.value.map.count());
}

test "loadDataFiles: missing data directory returns empty" {
    var result = try loadDataFiles(std.testing.allocator, "/nonexistent/path");
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 0), result.value.map.count());
}

test "loadDataFiles: loads JSON files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("data");
    var data_dir = try tmp.dir.openDir("data", .{});
    defer data_dir.close();

    var jf = try data_dir.createFile("authors.json", .{});
    try jf.writeAll("{\"name\": \"Alice\"}");
    jf.close();

    const abs = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(abs);

    var result = try loadDataFiles(std.testing.allocator, abs);
    defer result.deinit();

    const authors = result.value.map.get("authors") orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("Alice", authors.map.get("name").?.string);
}

test "isSiteConfigFile: identifies site config files" {
    try std.testing.expect(isSiteConfigFile("site.yaml"));
    try std.testing.expect(isSiteConfigFile("site.json"));
    try std.testing.expect(isSiteConfigFile("site.yml"));
    try std.testing.expect(!isSiteConfigFile("authors.yaml"));
}
