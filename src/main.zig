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
    } else if (std.mem.eql(u8, command, "validate")) {
        const path = args.next() orelse ".";
        var site = try wig.Site.init(a, .{ .root = path });
        defer site.deinit();
        const external = hasFlag(&args, "--external");
        try site.validate(.{ .external_links = external });
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
        std.debug.print("wig styles: not implemented\n", .{});
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
        \\  install <name|url>           Install a style from wig-stand or URL
        \\  add style <name>             Create a new empty style
        \\  add block <style> <name>     Add a block pattern to a style
        \\  styles <name> manifest       List asset bundle files for a style
        \\  validate [path] [--external] Validate without building
        \\
    , .{});
}

fn hasFlag(args: *std.process.ArgIterator, flag: []const u8) bool {
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, flag)) return true;
    }
    return false;
}
