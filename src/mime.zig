const std = @import("std");

pub fn fromExtension(ext: []const u8) []const u8 {
    const map = std.StaticStringMap([]const u8).initComptime(.{
        .{ ".html", "text/html; charset=utf-8" },
        .{ ".htm", "text/html; charset=utf-8" },
        .{ ".css", "text/css; charset=utf-8" },
        .{ ".js", "text/javascript; charset=utf-8" },
        .{ ".mjs", "text/javascript; charset=utf-8" },
        .{ ".json", "application/json" },
        .{ ".xml", "application/xml" },
        .{ ".atom", "application/atom+xml" },
        .{ ".rss", "application/rss+xml" },
        .{ ".svg", "image/svg+xml" },
        .{ ".png", "image/png" },
        .{ ".jpg", "image/jpeg" },
        .{ ".jpeg", "image/jpeg" },
        .{ ".gif", "image/gif" },
        .{ ".webp", "image/webp" },
        .{ ".avif", "image/avif" },
        .{ ".ico", "image/x-icon" },
        .{ ".woff", "font/woff" },
        .{ ".woff2", "font/woff2" },
        .{ ".ttf", "font/ttf" },
        .{ ".otf", "font/otf" },
        .{ ".txt", "text/plain; charset=utf-8" },
        .{ ".md", "text/plain; charset=utf-8" },
        .{ ".wasm", "application/wasm" },
        .{ ".map", "application/json" },
        .{ ".webmanifest", "application/manifest+json" },
    });
    return map.get(ext) orelse "application/octet-stream";
}

pub fn fromPath(path: []const u8) []const u8 {
    return fromExtension(std.fs.path.extension(path));
}

test "known extensions" {
    try std.testing.expectEqualStrings("text/html; charset=utf-8", fromExtension(".html"));
    try std.testing.expectEqualStrings("text/css; charset=utf-8", fromExtension(".css"));
    try std.testing.expectEqualStrings("text/javascript; charset=utf-8", fromExtension(".js"));
    try std.testing.expectEqualStrings("application/json", fromExtension(".json"));
    try std.testing.expectEqualStrings("image/png", fromExtension(".png"));
    try std.testing.expectEqualStrings("image/svg+xml", fromExtension(".svg"));
    try std.testing.expectEqualStrings("font/woff2", fromExtension(".woff2"));
    try std.testing.expectEqualStrings("application/atom+xml", fromExtension(".atom"));
}

test "unknown extension returns octet-stream" {
    try std.testing.expectEqualStrings("application/octet-stream", fromExtension(".xyz"));
    try std.testing.expectEqualStrings("application/octet-stream", fromExtension(""));
}

test "fromPath extracts extension" {
    try std.testing.expectEqualStrings("text/html; charset=utf-8", fromPath("index.html"));
    try std.testing.expectEqualStrings("text/css; charset=utf-8", fromPath("assets/style.css"));
    try std.testing.expectEqualStrings("application/octet-stream", fromPath("Makefile"));
}
