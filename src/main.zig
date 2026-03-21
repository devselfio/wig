const std = @import("std");
const wig = @import("wig");

pub fn main() !void {
    const a = std.heap.page_allocator;
    var args = std.process.args();
    _ = args.next(); // skip executable name

    const command = args.next() orelse {
        printUsage();
        return;
    };

    if (std.mem.eql(u8, command, "init")) {
        const path = args.next() orelse ".";
        try wig.scaffold.init(a, path);
    } else if (std.mem.eql(u8, command, "build")) {
        const opts = parsePathAndClean(&args);
        var site = try wig.Site.init(a, .{ .root = opts.path });
        defer site.deinit();
        site.buildAll(.{ .clean = opts.clean }) catch |err| {
            std.debug.print("wig build: failed ({any})\n", .{err});
            return err;
        };
        std.debug.print("wig build: ok → {s}/zig-out/site/\n", .{opts.path});
    } else if (std.mem.eql(u8, command, "validate")) {
        const path = args.next() orelse ".";
        var site = try wig.Site.init(a, .{ .root = path });
        defer site.deinit();
        const external = hasFlag(&args, "--external");
        const diags = try site.validate(.{ .external_links = external });
        defer site.allocator.free(diags);
    } else if (std.mem.eql(u8, command, "install")) {
        const name_or_url = args.next() orelse {
            std.debug.print("wig install: missing style name or URL\n", .{});
            return;
        };
        const force = hasFlag(&args, "--force");
        const pages = hasFlag(&args, "--pages");
        try wig.scaffold.install(a, name_or_url, ".", .{ .force = force, .include_pages = pages });
    } else if (std.mem.eql(u8, command, "add")) {
        const sub = args.next() orelse {
            std.debug.print("wig add: specify 'style' or 'block'\n", .{});
            return;
        };
        if (std.mem.eql(u8, sub, "style")) {
            const name = args.next() orelse {
                std.debug.print("wig add style: missing style name\n", .{});
                return;
            };
            try wig.scaffold.addStyle(a, "styles", name);
        } else if (std.mem.eql(u8, sub, "block")) {
            const style = args.next() orelse {
                std.debug.print("wig add block: missing style name\n", .{});
                return;
            };
            const block = args.next() orelse {
                std.debug.print("wig add block: missing block name\n", .{});
                return;
            };
            try wig.scaffold.addBlock(a, "styles", style, block);
        } else {
            std.debug.print("wig add: unknown subcommand '{s}'\n", .{sub});
        }
    } else if (std.mem.eql(u8, command, "styles")) {
        return error.NotImplemented;
    } else {
        std.debug.print("wig: unknown command '{s}'\n", .{command});
        printUsage();
    }
}

fn printUsage() void {
    std.debug.print(
        \\Usage: wig <command> [options]
        \\
        \\Commands:
        \\  init [path]                  Scaffold a new Wig project
        \\  build [path] [--clean]       Build static site to zig-out/site/
        \\  install <name|url>          Install a style from wig-stand or URL
        \\  add style <name>             Create a new empty style
        \\  add block <style> <name>     Add a block pattern to a style
        \\  styles <name> manifest       List asset bundle files for a style
        \\  validate [path] [--external] Validate without building
        \\
    , .{});
}

const PathAndClean = struct {
    path: []const u8,
    clean: bool,
};

/// Parses optional `[path]` and `--clean` in any order after the subcommand.
fn parsePathAndClean(args: *std.process.ArgIterator) PathAndClean {
    var path: ?[]const u8 = null;
    var clean = false;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--clean")) {
            clean = true;
        } else if (arg.len > 0 and arg[0] == '-') {
            std.debug.print("wig build: unknown option '{s}'\n", .{arg});
        } else if (path == null) {
            path = arg;
        } else {
            std.debug.print("wig build: unexpected extra argument '{s}'\n", .{arg});
        }
    }
    return .{ .path = path orelse ".", .clean = clean };
}

fn hasFlag(args: *std.process.ArgIterator, flag: []const u8) bool {
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, flag)) return true;
    }
    return false;
}
