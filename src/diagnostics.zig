const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Diagnostic = struct {
    kind: Kind = .err,
    message: []const u8,
    source: ?[]const u8 = null,
    help: ?[]const u8 = null,
    template_name: ?[]const u8 = null,

    pub const Kind = enum { err, warning };

    pub fn format(self: *const Diagnostic, a: Allocator) ![]const u8 {
        var buf = std.ArrayListUnmanaged(u8).empty;
        const w = buf.writer(a);
        const prefix: []const u8 = switch (self.kind) {
            .err => "error",
            .warning => "warning",
        };
        try w.print("[{s}] {s}", .{ prefix, self.message });
        if (self.source) |src| try w.print(" ({s})", .{src});
        if (self.template_name) |tn| try w.print(" [template: {s}]", .{tn});
        if (self.help) |h| try w.print("\n  help: {s}", .{h});
        return buf.items;
    }
};

pub const Collector = struct {
    items: std.ArrayListUnmanaged(Diagnostic) = .empty,

    pub fn err(self: *Collector, a: Allocator, msg: []const u8) !void {
        try self.items.append(a, .{ .kind = .err, .message = msg });
    }

    pub fn warn(self: *Collector, a: Allocator, msg: []const u8) !void {
        try self.items.append(a, .{ .kind = .warning, .message = msg });
    }

    pub fn warnWithHelp(self: *Collector, a: Allocator, msg: []const u8, help: []const u8) !void {
        try self.items.append(a, .{ .kind = .warning, .message = msg, .help = help });
    }

    pub fn warnFmt(self: *Collector, a: Allocator, comptime fmt: []const u8, args: anytype) !void {
        const msg = try std.fmt.allocPrint(a, fmt, args);
        try self.warn(a, msg);
    }

    pub fn errFmt(self: *Collector, a: Allocator, comptime fmt: []const u8, args: anytype) !void {
        const msg = try std.fmt.allocPrint(a, fmt, args);
        try self.err(a, msg);
    }

    pub fn hasErrors(self: *const Collector) bool {
        for (self.items.items) |item| {
            if (item.kind == .err) return true;
        }
        return false;
    }
};

const testing = std.testing;

test "Collector: err and warn" {
    var c = Collector{};
    try c.err(testing.allocator, "bad thing");
    try c.warn(testing.allocator, "heads up");
    try testing.expectEqual(@as(usize, 2), c.items.items.len);
    try testing.expect(c.items.items[0].kind == .err);
    try testing.expect(c.items.items[1].kind == .warning);
    try testing.expectEqualStrings("bad thing", c.items.items[0].message);
    try testing.expectEqualStrings("heads up", c.items.items[1].message);
    c.items.deinit(testing.allocator);
}

test "Collector: hasErrors" {
    var c = Collector{};
    try c.warn(testing.allocator, "just a warning");
    try testing.expect(!c.hasErrors());
    try c.err(testing.allocator, "an error");
    try testing.expect(c.hasErrors());
    c.items.deinit(testing.allocator);
}

test "Collector: warnFmt" {
    var c = Collector{};
    try c.warnFmt(testing.allocator, "page {d} of {d}", .{ 3, 10 });
    try testing.expectEqualStrings("page 3 of 10", c.items.items[0].message);
    testing.allocator.free(c.items.items[0].message);
    c.items.deinit(testing.allocator);
}

test "Diagnostic: format" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const d = Diagnostic{
        .kind = .err,
        .message = "missing layout",
        .source = "about.dj",
        .template_name = "layouts/base.html",
        .help = "check style.yaml",
    };
    const out = try d.format(a);
    try testing.expect(std.mem.indexOf(u8, out, "[error] missing layout") != null);
    try testing.expect(std.mem.indexOf(u8, out, "(about.dj)") != null);
    try testing.expect(std.mem.indexOf(u8, out, "[template: layouts/base.html]") != null);
    try testing.expect(std.mem.indexOf(u8, out, "help: check style.yaml") != null);
}
