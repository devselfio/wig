const std = @import("std");
const comb = @import("comb");
const toupee = @import("toupee");

const Allocator = std.mem.Allocator;
const ValueMap = std.StringArrayHashMapUnmanaged(toupee.Value);

/// A loaded color scheme file: the scheme ID and its parsed YAML data.
/// The name matches the file stem (e.g. "solarized-dark" for solarized-dark.yaml).
pub const SchemeFile = struct {
    name: []const u8,
    data: comb.Value,
};

/// Owns the resolved color data and the arena that backs it.
pub const ColorResult = struct {
    value: toupee.Value,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *ColorResult) void {
        self.arena.deinit();
    }
};

/// Resolves color scheme palette indirection for a style's highlights config.
///
/// `highlights` is the `highlights:` section from a style manifest (raw comb.Value).
/// `scheme_files` provides the parsed YAML for each color scheme file.
///
/// `highlights.default` is a scheme ID string (e.g. "solarized-dark").
/// `highlights.schemes` is a list of scheme ID strings.
///
/// Returns a toupee.Value map with:
///   - `default_id`: string (e.g. "solarized-dark")
///   - `schemes`: list of resolved scheme maps, each containing:
///     - `id`, `name`, `html`, `is_default`
///     - `text`: map of role -> hex (from document.text)
///     - `bg`: map of role -> hex (from document.background)
///     - `syntax`: map of role -> hex
pub fn resolve(
    backing: Allocator,
    highlights: comb.Value,
    scheme_files: []const SchemeFile,
) !ColorResult {
    var arena = std.heap.ArenaAllocator.init(backing);
    errdefer arena.deinit();
    const a = arena.allocator();

    const default_val = highlights.get("default") orelse
        return error.MissingHighlightsDefault;
    const default_id: []const u8 = switch (default_val) {
        .string => |s| s,
        else => return error.MissingHighlightsDefault,
    };

    const schemes_array = highlights.getArray("schemes");
    if (schemes_array == null) {
        var result_map: ValueMap = .{};
        try result_map.put(a, "default_id", .{ .string = default_id });
        try result_map.put(a, "schemes", .{ .list = &.{} });
        return .{ .value = .{ .map = result_map }, .arena = arena };
    }
    const schemes_list = schemes_array.?;

    var resolved: std.ArrayListUnmanaged(toupee.Value) = .empty;
    for (schemes_list) |entry| {
        const spec_id: []const u8 = switch (entry) {
            .string => |s| s,
            else => continue,
        };
        const scheme_data = findScheme(spec_id, scheme_files) orelse
            return error.SchemeNotFound;
        const palette = scheme_data.get("palette") orelse
            return error.MissingPalette;

        const meta = scheme_data.get("meta");
        const name = if (meta) |m| m.getStr("name") orelse spec_id else spec_id;
        const html = if (meta) |m| m.getStr("html") orelse name else name;
        const is_default = std.mem.eql(u8, spec_id, default_id);

        var scheme_map: ValueMap = .{};
        try scheme_map.put(a, "id", .{ .string = spec_id });
        try scheme_map.put(a, "name", .{ .string = name });
        try scheme_map.put(a, "html", .{ .string = html });
        try scheme_map.put(a, "is_default", .{ .boolean = is_default });

        if (scheme_data.get("document")) |doc| {
            if (doc.get("text")) |text| {
                const text_map = try resolveRoles(a, text, palette);
                try scheme_map.put(a, "text", .{ .map = text_map });
            }
            if (doc.get("background")) |bg| {
                const bg_map = try resolveRoles(a, bg, palette);
                try scheme_map.put(a, "bg", .{ .map = bg_map });
            }
        }

        if (scheme_data.get("syntax")) |syntax| {
            const syntax_map = try resolveRoles(a, syntax, palette);
            try scheme_map.put(a, "syntax", .{ .map = syntax_map });
        }

        try resolved.append(a, .{ .map = scheme_map });
    }

    const schemes_slice = try a.dupe(toupee.Value, resolved.items);

    var result_map: ValueMap = .{};
    try result_map.put(a, "default_id", .{ .string = default_id });
    try result_map.put(a, "schemes", .{ .list = schemes_slice });

    return .{ .value = .{ .map = result_map }, .arena = arena };
}

/// Resolves palette indirection in `data/colors/` merged as the top-level `colors` map.
/// Each scheme file is a flat variant (no light:/dark: nesting). Palette references in
/// `document:` categories, `syntax:` roles, and the flat **`terminal`** map are replaced
/// with their hex values.
pub fn resolveColorsData(a: Allocator, colors_val: toupee.Value) !toupee.Value {
    if (colors_val != .map) return colors_val;
    var result = ValueMap{};
    var it = colors_val.map.iterator();
    while (it.next()) |entry| {
        const scheme_id = entry.key_ptr.*;
        const scheme_val = entry.value_ptr.*;
        if (scheme_val != .map) {
            try result.put(a, scheme_id, scheme_val);
            continue;
        }
        const palette_val = scheme_val.map.get("palette") orelse {
            try result.put(a, scheme_id, scheme_val);
            continue;
        };
        if (palette_val != .map) {
            try result.put(a, scheme_id, scheme_val);
            continue;
        }
        var resolved_scheme = ValueMap{};
        var vv_it = scheme_val.map.iterator();
        while (vv_it.next()) |vv_entry| {
            if (std.mem.eql(u8, vv_entry.key_ptr.*, "document")) {
                const doc_val = vv_entry.value_ptr.*;
                if (doc_val != .map) {
                    try resolved_scheme.put(a, "document", doc_val);
                    continue;
                }
                var resolved_doc = ValueMap{};
                var cat_it = doc_val.map.iterator();
                while (cat_it.next()) |cat_entry| {
                    const cat_val = cat_entry.value_ptr.*;
                    if (cat_val != .map) {
                        try resolved_doc.put(a, cat_entry.key_ptr.*, cat_val);
                        continue;
                    }
                    var resolved_cat = ValueMap{};
                    var role_it = cat_val.map.iterator();
                    while (role_it.next()) |role_entry| {
                        const role_val = role_entry.value_ptr.*;
                        const hex = if (role_val == .string)
                            palette_val.map.get(role_val.string)
                        else
                            null;
                        if (hex) |h| {
                            try resolved_cat.put(a, role_entry.key_ptr.*, h);
                        } else {
                            try resolved_cat.put(a, role_entry.key_ptr.*, role_val);
                        }
                    }
                    try resolved_doc.put(a, cat_entry.key_ptr.*, .{ .map = resolved_cat });
                }
                try resolved_scheme.put(a, "document", .{ .map = resolved_doc });
            } else if (std.mem.eql(u8, vv_entry.key_ptr.*, "syntax")) {
                const syntax_val = vv_entry.value_ptr.*;
                if (syntax_val != .map) {
                    try resolved_scheme.put(a, "syntax", syntax_val);
                    continue;
                }
                var resolved_syntax = ValueMap{};
                var role_it = syntax_val.map.iterator();
                while (role_it.next()) |role_entry| {
                    const role_val = role_entry.value_ptr.*;
                    const hex = if (role_val == .string)
                        palette_val.map.get(role_val.string)
                    else
                        null;
                    if (hex) |h| {
                        try resolved_syntax.put(a, role_entry.key_ptr.*, h);
                    } else {
                        try resolved_syntax.put(a, role_entry.key_ptr.*, role_val);
                    }
                }
                try resolved_scheme.put(a, "syntax", .{ .map = resolved_syntax });
            } else if (std.mem.eql(u8, vv_entry.key_ptr.*, "terminal")) {
                const terminal_val = vv_entry.value_ptr.*;
                if (terminal_val != .map) {
                    try resolved_scheme.put(a, "terminal", terminal_val);
                    continue;
                }
                var resolved_terminal = ValueMap{};
                var slot_it = terminal_val.map.iterator();
                while (slot_it.next()) |slot_entry| {
                    const slot_val = slot_entry.value_ptr.*;
                    const hex = if (slot_val == .string)
                        palette_val.map.get(slot_val.string)
                    else
                        null;
                    if (hex) |h| {
                        try resolved_terminal.put(a, slot_entry.key_ptr.*, h);
                    } else {
                        try resolved_terminal.put(a, slot_entry.key_ptr.*, slot_val);
                    }
                }
                try resolved_scheme.put(a, "terminal", .{ .map = resolved_terminal });
            } else {
                try resolved_scheme.put(a, vv_entry.key_ptr.*, vv_entry.value_ptr.*);
            }
        }
        try result.put(a, scheme_id, .{ .map = resolved_scheme });
    }
    return .{ .map = result };
}

fn findScheme(name: []const u8, scheme_files: []const SchemeFile) ?comb.Value {
    for (scheme_files) |file| {
        if (std.mem.eql(u8, file.name, name)) return file.data;
    }
    return null;
}

/// Resolves a map of role -> palette_key pairs to role -> hex_value.
fn resolveRoles(a: Allocator, roles: comb.Value, palette: comb.Value) !ValueMap {
    const entries = switch (roles) {
        .object => |o| o,
        else => return .{},
    };
    var map: ValueMap = .{};
    for (entries) |entry| {
        const role = switch (entry.key) {
            .string => |s| s,
            else => continue,
        };
        const palette_key = switch (entry.value) {
            .string => |s| s,
            else => continue,
        };
        const hex = palette.getStr(palette_key) orelse
            return error.PaletteKeyNotFound;
        try map.put(a, role, .{ .string = hex });
    }
    return map;
}

// ── Tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

fn makeHighlights(
    default_id: []const u8,
    scheme_specs: []const comb.Value,
) [3]comb.Entry {
    return .{
        .{ .key = .{ .string = "default" }, .value = .{ .string = default_id } },
        .{ .key = .{ .string = "schemes" }, .value = .{ .array = scheme_specs } },
        .{ .key = .{ .string = "css" }, .value = .{ .string = "true" } },
    };
}

const test_light_yaml =
    \\meta:
    \\  name: Test Light
    \\  html: Test Light
    \\palette:
    \\  white: '#ffffff'
    \\  black: '#000000'
    \\  blue: '#0066cc'
    \\  grey: '#999999'
    \\document:
    \\  text:
    \\    primary: black
    \\    link: blue
    \\  background:
    \\    primary: white
    \\    secondary: grey
    \\syntax:
    \\  keyword: blue
    \\  comment: grey
;

const test_dark_yaml =
    \\meta:
    \\  name: Test Dark
    \\  html: Test Dark
    \\palette:
    \\  white: '#ffffff'
    \\  black: '#000000'
    \\  red: '#ff3333'
    \\  darkgrey: '#333333'
    \\document:
    \\  text:
    \\    primary: white
    \\    link: red
    \\  background:
    \\    primary: black
    \\    secondary: darkgrey
    \\syntax:
    \\  keyword: red
    \\  comment: darkgrey
;

fn getMapStr(val: toupee.Value, key: []const u8) ?[]const u8 {
    const map = switch (val) {
        .map => |m| m,
        else => return null,
    };
    const v = map.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn getMapBool(val: toupee.Value, key: []const u8) ?bool {
    const map = switch (val) {
        .map => |m| m,
        else => return null,
    };
    const v = map.get(key) orelse return null;
    return switch (v) {
        .boolean => |b| b,
        else => null,
    };
}

fn getMapList(val: toupee.Value, key: []const u8) ?[]const toupee.Value {
    const map = switch (val) {
        .map => |m| m,
        else => return null,
    };
    const v = map.get(key) orelse return null;
    return switch (v) {
        .list => |l| l,
        else => null,
    };
}

fn getMapMap(val: toupee.Value, key: []const u8) ?ValueMap {
    const map = switch (val) {
        .map => |m| m,
        else => return null,
    };
    const v = map.get(key) orelse return null;
    return switch (v) {
        .map => |m| m,
        else => null,
    };
}

fn getNestedStr(val: toupee.Value, outer: []const u8, inner: []const u8) ?[]const u8 {
    const outer_map = getMapMap(val, outer) orelse return null;
    const v = outer_map.get(inner) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

test "resolve: single scheme light" {
    const a = testing.allocator;
    var parsed = try comb.parse(a, test_light_yaml);
    defer parsed.deinit();

    const specs = [_]comb.Value{.{ .string = "test-light" }};
    var hl_entries = makeHighlights("test-light", &specs);
    const highlights = comb.Value{ .object = &hl_entries };
    const scheme_files = [_]SchemeFile{.{ .name = "test-light", .data = parsed.value }};

    var result = try resolve(a, highlights, &scheme_files);
    defer result.deinit();

    try testing.expectEqualStrings("test-light", getMapStr(result.value, "default_id").?);

    const schemes = getMapList(result.value, "schemes").?;
    try testing.expectEqual(@as(usize, 1), schemes.len);

    const s = schemes[0];
    try testing.expectEqualStrings("test-light", getMapStr(s, "id").?);
    try testing.expectEqualStrings("Test Light", getMapStr(s, "name").?);
    try testing.expect(getMapBool(s, "is_default").?);

    try testing.expectEqualStrings("#000000", getNestedStr(s, "text", "primary").?);
    try testing.expectEqualStrings("#0066cc", getNestedStr(s, "text", "link").?);
    try testing.expectEqualStrings("#ffffff", getNestedStr(s, "bg", "primary").?);
    try testing.expectEqualStrings("#999999", getNestedStr(s, "bg", "secondary").?);
    try testing.expectEqualStrings("#0066cc", getNestedStr(s, "syntax", "keyword").?);
    try testing.expectEqualStrings("#999999", getNestedStr(s, "syntax", "comment").?);
}

test "resolve: single scheme dark" {
    const a = testing.allocator;
    var parsed = try comb.parse(a, test_dark_yaml);
    defer parsed.deinit();

    const specs = [_]comb.Value{.{ .string = "test-dark" }};
    var hl_entries = makeHighlights("test-dark", &specs);
    const highlights = comb.Value{ .object = &hl_entries };
    const scheme_files = [_]SchemeFile{.{ .name = "test-dark", .data = parsed.value }};

    var result = try resolve(a, highlights, &scheme_files);
    defer result.deinit();

    const schemes = getMapList(result.value, "schemes").?;
    const s = schemes[0];
    try testing.expectEqualStrings("test-dark", getMapStr(s, "id").?);
    try testing.expectEqualStrings("Test Dark", getMapStr(s, "name").?);
    try testing.expect(getMapBool(s, "is_default").?);

    try testing.expectEqualStrings("#ffffff", getNestedStr(s, "text", "primary").?);
    try testing.expectEqualStrings("#ff3333", getNestedStr(s, "text", "link").?);
    try testing.expectEqualStrings("#000000", getNestedStr(s, "bg", "primary").?);
    try testing.expectEqualStrings("#ff3333", getNestedStr(s, "syntax", "keyword").?);
}

test "resolve: multiple schemes with correct default" {
    const a = testing.allocator;
    var parsed_light = try comb.parse(a, test_light_yaml);
    defer parsed_light.deinit();
    var parsed_dark = try comb.parse(a, test_dark_yaml);
    defer parsed_dark.deinit();

    const specs = [_]comb.Value{
        .{ .string = "test-light" },
        .{ .string = "test-dark" },
    };
    var hl_entries = makeHighlights("test-dark", &specs);
    const highlights = comb.Value{ .object = &hl_entries };
    const scheme_files = [_]SchemeFile{
        .{ .name = "test-light", .data = parsed_light.value },
        .{ .name = "test-dark", .data = parsed_dark.value },
    };

    var result = try resolve(a, highlights, &scheme_files);
    defer result.deinit();

    try testing.expectEqualStrings("test-dark", getMapStr(result.value, "default_id").?);

    const schemes = getMapList(result.value, "schemes").?;
    try testing.expectEqual(@as(usize, 2), schemes.len);

    try testing.expect(!getMapBool(schemes[0], "is_default").?);
    try testing.expect(getMapBool(schemes[1], "is_default").?);
}

test "resolve: multiple scheme files" {
    const a = testing.allocator;
    var parsed_test = try comb.parse(a, test_dark_yaml);
    defer parsed_test.deinit();

    const alt_yaml =
        \\meta:
        \\  name: Alt Light
        \\  html: Alt Light
        \\palette:
        \\  fg: '#111111'
        \\  bg: '#eeeeee'
        \\document:
        \\  text:
        \\    primary: fg
        \\  background:
        \\    primary: bg
        \\syntax:
        \\  keyword: fg
    ;
    var parsed_alt = try comb.parse(a, alt_yaml);
    defer parsed_alt.deinit();

    const specs = [_]comb.Value{
        .{ .string = "test-dark" },
        .{ .string = "alt-light" },
    };
    var hl_entries = makeHighlights("test-dark", &specs);
    const highlights = comb.Value{ .object = &hl_entries };
    const scheme_files = [_]SchemeFile{
        .{ .name = "test-dark", .data = parsed_test.value },
        .{ .name = "alt-light", .data = parsed_alt.value },
    };

    var result = try resolve(a, highlights, &scheme_files);
    defer result.deinit();

    const schemes = getMapList(result.value, "schemes").?;
    try testing.expectEqual(@as(usize, 2), schemes.len);

    try testing.expectEqualStrings("test-dark", getMapStr(schemes[0], "id").?);
    try testing.expectEqualStrings("#ffffff", getNestedStr(schemes[0], "text", "primary").?);

    try testing.expectEqualStrings("alt-light", getMapStr(schemes[1], "id").?);
    try testing.expectEqualStrings("#111111", getNestedStr(schemes[1], "text", "primary").?);
    try testing.expectEqualStrings("#eeeeee", getNestedStr(schemes[1], "bg", "primary").?);
}

test "resolve: missing scheme returns error" {
    const a = testing.allocator;
    const specs = [_]comb.Value{.{ .string = "missing-dark" }};
    var hl_entries = makeHighlights("missing-dark", &specs);
    const highlights = comb.Value{ .object = &hl_entries };

    const result = resolve(a, highlights, &.{});
    try testing.expectError(error.SchemeNotFound, result);
}

test "resolve: missing palette key returns error" {
    const a = testing.allocator;
    const bad_yaml =
        \\meta:
        \\  name: Bad
        \\  html: Bad
        \\palette:
        \\  white: '#ffffff'
        \\document:
        \\  text:
        \\    primary: nonexistent
        \\  background:
        \\    primary: white
        \\syntax:
        \\  keyword: white
    ;
    var parsed = try comb.parse(a, bad_yaml);
    defer parsed.deinit();

    const specs = [_]comb.Value{.{ .string = "bad-light" }};
    var hl_entries = makeHighlights("bad-light", &specs);
    const highlights = comb.Value{ .object = &hl_entries };
    const scheme_files = [_]SchemeFile{.{ .name = "bad-light", .data = parsed.value }};

    const result = resolve(a, highlights, &scheme_files);
    try testing.expectError(error.PaletteKeyNotFound, result);
}

test "resolve: missing highlights default returns error" {
    const a = testing.allocator;
    const entries = [_]comb.Entry{
        .{ .key = .{ .string = "schemes" }, .value = .{ .array = &.{} } },
    };
    const highlights = comb.Value{ .object = &entries };

    const result = resolve(a, highlights, &.{});
    try testing.expectError(error.MissingHighlightsDefault, result);
}

test "resolve: empty schemes list returns valid result" {
    const a = testing.allocator;
    var hl_entries = makeHighlights("test-dark", &.{});
    const highlights = comb.Value{ .object = &hl_entries };

    var result = try resolve(a, highlights, &.{});
    defer result.deinit();

    try testing.expectEqualStrings("test-dark", getMapStr(result.value, "default_id").?);
    const schemes = getMapList(result.value, "schemes").?;
    try testing.expectEqual(@as(usize, 0), schemes.len);
}

test "resolve: no schemes key returns valid result" {
    const a = testing.allocator;
    const entries = [_]comb.Entry{
        .{ .key = .{ .string = "default" }, .value = .{ .string = "test-dark" } },
    };
    const highlights = comb.Value{ .object = &entries };

    var result = try resolve(a, highlights, &.{});
    defer result.deinit();

    try testing.expectEqualStrings("test-dark", getMapStr(result.value, "default_id").?);
    const schemes = getMapList(result.value, "schemes").?;
    try testing.expectEqual(@as(usize, 0), schemes.len);
}

test "resolve: meta html differs from name" {
    const a = testing.allocator;
    const yaml =
        \\meta:
        \\  name: Rose Pine
        \\  html: "Ros&eacute; Pine"
        \\palette:
        \\  fg: '#575279'
        \\  bg: '#faf4ed'
        \\document:
        \\  text:
        \\    primary: fg
        \\  background:
        \\    primary: bg
        \\syntax:
        \\  keyword: fg
    ;
    var parsed = try comb.parse(a, yaml);
    defer parsed.deinit();

    const specs = [_]comb.Value{.{ .string = "rose-light" }};
    var hl_entries = makeHighlights("rose-light", &specs);
    const highlights = comb.Value{ .object = &hl_entries };
    const scheme_files = [_]SchemeFile{.{ .name = "rose-light", .data = parsed.value }};

    var result = try resolve(a, highlights, &scheme_files);
    defer result.deinit();

    const schemes = getMapList(result.value, "schemes").?;
    try testing.expectEqualStrings("Rose Pine", getMapStr(schemes[0], "name").?);
    try testing.expectEqualStrings("Ros&eacute; Pine", getMapStr(schemes[0], "html").?);
}

test "resolve: scheme without meta uses spec as name" {
    const a = testing.allocator;
    const yaml =
        \\palette:
        \\  fg: '#000000'
        \\  bg: '#ffffff'
        \\document:
        \\  text:
        \\    primary: fg
        \\  background:
        \\    primary: bg
        \\syntax:
        \\  keyword: fg
    ;
    var parsed = try comb.parse(a, yaml);
    defer parsed.deinit();

    const specs = [_]comb.Value{.{ .string = "minimal-light" }};
    var hl_entries = makeHighlights("minimal-light", &specs);
    const highlights = comb.Value{ .object = &hl_entries };
    const scheme_files = [_]SchemeFile{.{ .name = "minimal-light", .data = parsed.value }};

    var result = try resolve(a, highlights, &scheme_files);
    defer result.deinit();

    const schemes = getMapList(result.value, "schemes").?;
    try testing.expectEqualStrings("minimal-light", getMapStr(schemes[0], "name").?);
}

test "resolve: missing palette section returns error" {
    const a = testing.allocator;
    const yaml =
        \\meta:
        \\  name: No Palette
        \\  html: No Palette
        \\document:
        \\  text:
        \\    primary: black
        \\  background:
        \\    primary: white
    ;
    var parsed = try comb.parse(a, yaml);
    defer parsed.deinit();

    const specs = [_]comb.Value{.{ .string = "bad-light" }};
    var hl_entries = makeHighlights("bad-light", &specs);
    const highlights = comb.Value{ .object = &hl_entries };
    const scheme_files = [_]SchemeFile{.{ .name = "bad-light", .data = parsed.value }};

    const result = resolve(a, highlights, &scheme_files);
    try testing.expectError(error.MissingPalette, result);
}

test "resolveColorsData: resolves terminal palette refs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var palette_map: ValueMap = .{};
    try palette_map.put(a, "accent", .{ .string = "#aabbcc" });
    try palette_map.put(a, "base", .{ .string = "#112233" });

    var terminal_map: ValueMap = .{};
    try terminal_map.put(a, "foreground", .{ .string = "accent" });
    try terminal_map.put(a, "background", .{ .string = "base" });

    var scheme_map: ValueMap = .{};
    try scheme_map.put(a, "palette", .{ .map = palette_map });
    try scheme_map.put(a, "terminal", .{ .map = terminal_map });

    var colors_root: ValueMap = .{};
    try colors_root.put(a, "scheme-a", .{ .map = scheme_map });

    const out = try resolveColorsData(a, .{ .map = colors_root });
    const scm = out.map.get("scheme-a").?.map;
    const term_out = scm.get("terminal").?.map;
    try testing.expectEqualStrings("#aabbcc", term_out.get("foreground").?.string);
    try testing.expectEqualStrings("#112233", term_out.get("background").?.string);
}
