const std = @import("std");
const toupee = @import("toupee");
const config = @import("config.zig");

const Allocator = std.mem.Allocator;
const fs = std.fs;

/// Resolves template names relative to a style during rendering.
/// Explicit paths: `layouts/X.html`, `blocks/X.html` resolve within the current style.
/// Cross-style: `style:path` (e.g. `_core:layouts/base.html`) resolves from another style.
/// Short names (e.g. `page.html`) try layouts then blocks.
pub const StyleLoader = struct {
    templates: *const std.StringArrayHashMapUnmanaged([]const u8),
    style_name: []const u8,

    pub fn loader(self: *const StyleLoader) toupee.Loader {
        return .{
            .ptr = @ptrCast(self),
            .getSourceFn = getSource,
        };
    }

    fn getSource(ptr: *const anyopaque, a: Allocator, name: []const u8) Allocator.Error!?[]const u8 {
        const self: *const StyleLoader = @ptrCast(@alignCast(ptr));

        if (std.mem.indexOf(u8, name, ":")) |colon_pos| {
            const target_style = name[0..colon_pos];
            const path = name[colon_pos + 1 ..];
            const full = try std.fmt.allocPrint(a, "{s}/templates/{s}", .{ target_style, path });
            defer a.free(full);
            if (self.templates.get(full)) |src| return try a.dupe(u8, src);
            return null;
        }

        if (self.templates.get(name)) |src| return try a.dupe(u8, src);

        if (std.mem.indexOf(u8, name, "/") != null) {
            const full = try std.fmt.allocPrint(a, "{s}/templates/{s}", .{ self.style_name, name });
            defer a.free(full);
            if (self.templates.get(full)) |src| return try a.dupe(u8, src);
            return null;
        }

        for ([_][]const u8{ "layouts/", "blocks/" }) |subdir| {
            const full = try std.fmt.allocPrint(a, "{s}/templates/{s}{s}", .{ self.style_name, subdir, name });
            defer a.free(full);
            if (self.templates.get(full)) |src| return try a.dupe(u8, src);
        }

        return null;
    }
};

/// Scans templates from disk into both an Engine (for rendering) and a template map (for StyleLoader).
/// Used by both `buildAll` and `validate` to avoid duplicating directory-walking logic.
pub fn loadTemplates(
    ba: Allocator,
    a: Allocator,
    abs_root: []const u8,
    style_cfgs: []config.StyleConfig,
    engine: *toupee.Engine,
    template_map: *std.StringArrayHashMapUnmanaged([]const u8),
) !void {
    const styles_path = try fs.path.join(a, &.{ abs_root, "styles" });
    defer a.free(styles_path);

    const styles_dir = fs.openDirAbsolute(styles_path, .{ .iterate = true }) catch return;
    var dir = styles_dir;
    defer dir.close();

    for ([_][]const u8{ "templates/layouts", "templates/blocks" }) |subdir| {
        const core_subdir = try std.fmt.allocPrint(ba, "_core/{s}", .{subdir});
        if (dir.openDir(core_subdir, .{ .iterate = true })) |cd| {
            var core_dir = cd;
            defer core_dir.close();
            var cit = core_dir.iterate();
            while (try cit.next()) |entry| {
                if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".html")) continue;
                const tmpl_name = try std.fmt.allocPrint(ba, "_core/{s}/{s}", .{ subdir, entry.name });
                const content = try core_dir.readFileAlloc(ba, entry.name, 4 * 1024 * 1024);
                try engine.addTemplate(tmpl_name, content);
                try template_map.put(ba, tmpl_name, content);
            }
        } else |_| {}
    }

    for (style_cfgs) |style_cfg| {
        for ([_][]const u8{ "templates/layouts", "templates/blocks" }) |subdir| {
            const style_subdir = try std.fmt.allocPrint(ba, "{s}/{s}", .{ style_cfg.name, subdir });
            if (dir.openDir(style_subdir, .{ .iterate = true })) |sd| {
                var tmpl_dir = sd;
                defer tmpl_dir.close();
                var tit = tmpl_dir.iterate();
                while (try tit.next()) |entry| {
                    if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".html")) continue;
                    const tmpl_name = try std.fmt.allocPrint(ba, "{s}/{s}/{s}", .{ style_cfg.name, subdir, entry.name });
                    const content = try tmpl_dir.readFileAlloc(ba, entry.name, 4 * 1024 * 1024);
                    try engine.addTemplate(tmpl_name, content);
                    try template_map.put(ba, tmpl_name, content);
                }
            } else |_| {}
        }
    }
}
