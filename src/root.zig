const std = @import("std");
pub const toupee = @import("toupee");
pub const comb = @import("comb");
pub const zjot = @import("zjot");

fn combToToupee(val: comb.Value) toupee.Value {
    return switch (val) {
        .string => |s| .{ .string = s },
        .integer => |i| .{ .integer = i },
        .boolean => |b| .{ .boolean = b },
        .float => |f| .{ .float = f },
        .null_val => .nil,
        .array => |arr| blk: {
            var list: []const toupee.Value = &.{};
            _ = arr;
            _ = &list;
            break :blk .{ .list = list };
        },
        else => .nil,
    };
}

test "dependency verification: all three deps compile and work together" {
    const a = std.testing.allocator;

    const yaml_input =
        \\title: My Site
        \\url: https://example.com
        \\draft: true
        \\count: 42
    ;
    var parsed = try comb.parse(a, yaml_input);
    defer parsed.deinit();

    const root = parsed.value;
    try std.testing.expect(root == .object);

    var ctx = toupee.Context.init(a);
    defer ctx.deinit();

    for (root.object) |entry| {
        const key = switch (entry.key) {
            .string => |s| s,
            else => continue,
        };
        try ctx.put(key, combToToupee(entry.value));
    }

    try std.testing.expectEqual(true, ctx.resolve("draft").?.boolean);
    try std.testing.expectEqual(42, ctx.resolve("count").?.integer);
    try std.testing.expectEqualStrings("My Site", ctx.resolve("title").?.string);

    const template = "<h1><t-var name=\"title\">fallback</t-var></h1>";
    const resolver: toupee.Resolver = .{};
    const html = try toupee.render(a, template, &ctx, resolver.loader(), .{});
    defer a.free(html);
    try std.testing.expectEqualStrings("<h1>My Site</h1>", html);

    const djot_input = "# Hello World\n\nA paragraph.\n";
    const djot_html = try zjot.toHtml(a, djot_input);
    defer a.free(djot_html);
    try std.testing.expect(std.mem.indexOf(u8, djot_html, "Hello World") != null);
    try std.testing.expect(std.mem.indexOf(u8, djot_html, "<p>A paragraph.</p>") != null);
}

test "dependency verification: toupee engine caches and renders" {
    const a = std.testing.allocator;

    var engine = try toupee.Engine.init(a);
    defer engine.deinit();

    try engine.addTemplate("greeting.html",
        \\<h1>Hello <t-var name="name">World</t-var></h1>
    );

    var ctx = toupee.Context.init(a);
    defer ctx.deinit();
    try ctx.put("name", .{ .string = "Wig" });

    const resolver: toupee.Resolver = .{};
    const result = try engine.renderTemplate(a, "greeting.html", &ctx, resolver.loader(), .{});
    defer a.free(result);
    try std.testing.expectEqualStrings("<h1>Hello Wig</h1>", result);
}

test "dependency verification: toupee conditional with missing key" {
    const a = std.testing.allocator;

    var ctx = toupee.Context.init(a);
    defer ctx.deinit();

    const template =
        \\<t-if var="hide">hidden</t-if>
    ;
    const resolver: toupee.Resolver = .{};
    const result = try toupee.render(a, template, &ctx, resolver.loader(), .{});
    defer a.free(result);
    try std.testing.expectEqualStrings("", result);
}

test "dependency verification: toupee conditional with present key" {
    const a = std.testing.allocator;

    var ctx = toupee.Context.init(a);
    defer ctx.deinit();
    try ctx.put("show", .{ .string = "yes" });

    const template =
        \\<t-if var="show">visible</t-if>
    ;
    const resolver: toupee.Resolver = .{};
    const result = try toupee.render(a, template, &ctx, resolver.loader(), .{});
    defer a.free(result);
    try std.testing.expectEqualStrings("visible", result);
}

test "dependency verification: toupee boolean false is still present" {
    const a = std.testing.allocator;

    var ctx = toupee.Context.init(a);
    defer ctx.deinit();
    try ctx.put("draft", .{ .boolean = true });
    try ctx.put("debug", .{ .boolean = false });

    const template =
        \\<t-if var="draft">draft</t-if><t-if var="debug">debug</t-if>
    ;
    const resolver: toupee.Resolver = .{};
    const result = try toupee.render(a, template, &ctx, resolver.loader(), .{});
    defer a.free(result);
    try std.testing.expectEqualStrings("draftdebug", result);
}

test "dependency verification: toupee putAt for nested context" {
    const a = std.testing.allocator;

    var ctx = toupee.Context.init(a);
    defer ctx.deinit();
    try ctx.putAt("page.title", .{ .string = "About" });
    try ctx.putAt("page.url", .{ .string = "/about/" });
    try ctx.putAt("site.name", .{ .string = "My Site" });

    try std.testing.expectEqualStrings("About", ctx.resolve("page.title").?.string);
    try std.testing.expectEqualStrings("/about/", ctx.resolve("page.url").?.string);
    try std.testing.expectEqualStrings("My Site", ctx.resolve("site.name").?.string);

    const template =
        \\<title><t-var name="page.title" /> | <t-var name="site.name" /></title>
    ;
    const resolver: toupee.Resolver = .{};
    const result = try toupee.render(a, template, &ctx, resolver.loader(), .{});
    defer a.free(result);
    try std.testing.expectEqualStrings("<title>About | My Site</title>", result);
}

test "dependency verification: zjot heading ids on sections" {
    const a = std.testing.allocator;

    const input = "# My Heading\n\nSome text.\n";
    const html = try zjot.toHtml(a, input);
    defer a.free(html);

    try std.testing.expect(std.mem.indexOf(u8, html, "id=") != null);
}

test "dependency verification: zjot raw html pass-through" {
    const a = std.testing.allocator;

    const input = "A paragraph with `<b>bold</b>`{=html} inside.\n";
    const html = try zjot.toHtml(a, input);
    defer a.free(html);

    try std.testing.expect(std.mem.indexOf(u8, html, "<b>bold</b>") != null);
}

test "dependency verification: comb v1.0.0 get() and value types" {
    const a = std.testing.allocator;

    const yaml =
        \\ratio: 1.25
        \\empty:
        \\nested:
        \\  inner: value
    ;
    var parsed = try comb.parse(a, yaml);
    defer parsed.deinit();

    const ratio = parsed.value.get("ratio") orelse return error.TestUnexpectedResult;
    try std.testing.expect(ratio == .float);
    try std.testing.expectApproxEqAbs(1.25, ratio.float, 0.001);

    const empty = parsed.value.get("empty") orelse return error.TestUnexpectedResult;
    try std.testing.expect(empty == .null_val);

    try std.testing.expectEqualStrings("value", parsed.value.get("nested").?.get("inner").?.string);
    try std.testing.expect(parsed.value.get("nonexistent") == null);
    try std.testing.expectEqualStrings("value", parsed.value.get("nested").?.getStr("inner").?);
}

test "dependency verification: toupee raw output for css templates" {
    const a = std.testing.allocator;

    var ctx = toupee.Context.init(a);
    defer ctx.deinit();
    try ctx.put("color", .{ .string = "#839496" });

    const template = ":root { --text: <t-raw name=\"color\" />; }";
    const resolver: toupee.Resolver = .{};
    const result = try toupee.render(a, template, &ctx, resolver.loader(), .{});
    defer a.free(result);
    try std.testing.expectEqualStrings(":root { --text: #839496; }", result);
}

test "dependency verification: toupee chain loader" {
    const a = std.testing.allocator;

    const fsl1: toupee.FileSystemLoader = .{ .base_path = "/nonexistent/path1" };
    const fsl2: toupee.FileSystemLoader = .{ .base_path = "/nonexistent/path2" };
    const chain: toupee.ChainLoader = .{ .loaders = &.{ fsl1.loader(), fsl2.loader() } };
    const loader = chain.loader();

    const result = try loader.getSource(a, "missing.html");
    try std.testing.expect(result == null);
}

test "dependency verification: toupee value has float" {
    const a = std.testing.allocator;

    var ctx = toupee.Context.init(a);
    defer ctx.deinit();
    try ctx.put("ratio", .{ .float = 1.25 });

    try std.testing.expectApproxEqAbs(1.25, ctx.resolve("ratio").?.float, 0.001);
}
