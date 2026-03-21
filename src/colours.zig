const std = @import("std");
const comb = @import("comb");
const toupee = @import("toupee");

const Allocator = std.mem.Allocator;
const ValueMap = std.StringArrayHashMapUnmanaged(toupee.Value);

/// A loaded colour scheme file: the scheme name and its parsed YAML data.
pub const SchemeFile = struct {
    name: []const u8,
    data: comb.Value,
};

/// A parsed scheme spec: "solarized.dark" -> { .scheme = "solarized", .mode = "dark" }.
pub const SchemeSpec = struct {
    scheme: []const u8,
    mode: []const u8,
};

/// Owns the resolved colour data and the arena that backs it.
pub const ColourResult = struct {
    value: toupee.Value,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *ColourResult) void {
        self.arena.deinit();
    }
};

/// Splits a "scheme.mode" string (e.g. "solarized.dark") into its parts.
/// Returns null if the spec is malformed (no dot, empty parts).
pub fn parseSchemeSpec(spec: []const u8) ?SchemeSpec {
    const dot = std.mem.indexOfScalar(u8, spec, '.') orelse return null;
    if (dot == 0 or dot >= spec.len - 1) return null;
    return .{
        .scheme = spec[0..dot],
        .mode = spec[dot + 1 ..],
    };
}

/// Resolves colour scheme palette indirection for a style's highlights config.
///
/// `highlights` is the `highlights:` section from a style manifest (raw comb.Value).
/// `scheme_files` provides the parsed YAML for each colour scheme file.
///
/// Returns a toupee.Value map with:
///   - `default_id`: string (e.g. "solarized-dark")
///   - `default_scheme`: string (e.g. "solarized")
///   - `default_mode`: string (e.g. "dark")
///   - `schemes`: list of resolved scheme maps, each containing:
///     - `id`, `scheme`, `mode`, `name`, `html`, `is_default`
///     - `text`: map of role -> hex (from styles.text)
///     - `bg`: map of role -> hex (from styles.background)
///     - `syntax`: map of role -> hex
pub fn resolve(
    backing: Allocator,
    highlights: comb.Value,
    scheme_files: []const SchemeFile,
) !ColourResult {
    var arena = std.heap.ArenaAllocator.init(backing);
    errdefer arena.deinit();
    const a = arena.allocator();

    const default_hl = highlights.get("default") orelse
        return error.MissingHighlightsDefault;
    const default_scheme = default_hl.getStr("scheme") orelse
        return error.MissingHighlightsDefault;
    const default_mode = default_hl.getStr("mode") orelse
        return error.MissingHighlightsDefault;
    const default_id = try std.fmt.allocPrint(a, "{s}-{s}", .{ default_scheme, default_mode });

    const schemes_array = highlights.getArray("schemes");
    if (schemes_array == null) {
        var result_map: ValueMap = .{};
        try result_map.put(a, "default_id", .{ .string = default_id });
        try result_map.put(a, "default_scheme", .{ .string = default_scheme });
        try result_map.put(a, "default_mode", .{ .string = default_mode });
        try result_map.put(a, "schemes", .{ .list = &.{} });
        return .{ .value = .{ .map = result_map }, .arena = arena };
    }
    const schemes_list = schemes_array.?;

    var resolved: std.ArrayListUnmanaged(toupee.Value) = .{};
    for (schemes_list) |entry| {
        const spec_str = switch (entry) {
            .string => |s| s,
            else => continue,
        };
        const spec = parseSchemeSpec(spec_str) orelse return error.InvalidSchemeSpec;
        const scheme_data = findScheme(spec.scheme, scheme_files) orelse
            return error.SchemeNotFound;
        const variant = scheme_data.get(spec.mode) orelse
            return error.VariantNotFound;
        const palette = variant.get("palette") orelse
            return error.MissingPalette;

        const meta = variant.get("meta");
        const name = if (meta) |m| m.getStr("name") orelse spec_str else spec_str;
        const html = if (meta) |m| m.getStr("html") orelse name else name;
        const is_default = std.mem.eql(u8, spec.scheme, default_scheme) and
            std.mem.eql(u8, spec.mode, default_mode);
        const id = try std.fmt.allocPrint(a, "{s}-{s}", .{ spec.scheme, spec.mode });

        var scheme_map: ValueMap = .{};
        try scheme_map.put(a, "id", .{ .string = id });
        try scheme_map.put(a, "scheme", .{ .string = spec.scheme });
        try scheme_map.put(a, "mode", .{ .string = spec.mode });
        try scheme_map.put(a, "name", .{ .string = name });
        try scheme_map.put(a, "html", .{ .string = html });
        try scheme_map.put(a, "is_default", .{ .boolean = is_default });

        if (variant.get("styles")) |styles| {
            if (styles.get("text")) |text| {
                const text_map = try resolveRoles(a, text, palette);
                try scheme_map.put(a, "text", .{ .map = text_map });
            }
            if (styles.get("background")) |bg| {
                const bg_map = try resolveRoles(a, bg, palette);
                try scheme_map.put(a, "bg", .{ .map = bg_map });
            }
        }

        if (variant.get("syntax")) |syntax| {
            const syntax_map = try resolveRoles(a, syntax, palette);
            try scheme_map.put(a, "syntax", .{ .map = syntax_map });
        }

        try resolved.append(a, .{ .map = scheme_map });
    }

    const schemes_slice = try a.dupe(toupee.Value, resolved.items);

    var result_map: ValueMap = .{};
    try result_map.put(a, "default_id", .{ .string = default_id });
    try result_map.put(a, "default_scheme", .{ .string = default_scheme });
    try result_map.put(a, "default_mode", .{ .string = default_mode });
    try result_map.put(a, "schemes", .{ .list = schemes_slice });

    return .{ .value = .{ .map = result_map }, .arena = arena };
}

/// Resolves palette indirection in `data/colors/` (or legacy `data/colours/`) merged as the top-level `colors` / `colours` map.
/// Replaces style role values (e.g. "black") with hex from palette (e.g. "#000000").
pub fn resolveColoursData(a: Allocator, colours_val: toupee.Value) !toupee.Value {
    if (colours_val != .map) return colours_val;
    var result = ValueMap{};
    var it = colours_val.map.iterator();
    while (it.next()) |entry| {
        const scheme_name = entry.key_ptr.*;
        const scheme_val = entry.value_ptr.*;
        if (scheme_val != .map) {
            try result.put(a, scheme_name, scheme_val);
            continue;
        }
        var resolved_scheme = ValueMap{};
        var var_it = scheme_val.map.iterator();
        while (var_it.next()) |var_entry| {
            const variant_name = var_entry.key_ptr.*;
            const variant_val = var_entry.value_ptr.*;
            if (variant_val != .map) {
                try resolved_scheme.put(a, variant_name, variant_val);
                continue;
            }
            const palette_val = variant_val.map.get("palette") orelse {
                try resolved_scheme.put(a, variant_name, variant_val);
                continue;
            };
            if (palette_val != .map) {
                try resolved_scheme.put(a, variant_name, variant_val);
                continue;
            }
            var resolved_variant = ValueMap{};
            var vv_it = variant_val.map.iterator();
            while (vv_it.next()) |vv_entry| {
                if (std.mem.eql(u8, vv_entry.key_ptr.*, "styles")) {
                    const styles_val = vv_entry.value_ptr.*;
                    if (styles_val != .map) {
                        try resolved_variant.put(a, "styles", styles_val);
                        continue;
                    }
                    var resolved_styles = ValueMap{};
                    var cat_it = styles_val.map.iterator();
                    while (cat_it.next()) |cat_entry| {
                        const cat_val = cat_entry.value_ptr.*;
                        if (cat_val != .map) {
                            try resolved_styles.put(a, cat_entry.key_ptr.*, cat_val);
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
                        try resolved_styles.put(a, cat_entry.key_ptr.*, .{ .map = resolved_cat });
                    }
                    try resolved_variant.put(a, "styles", .{ .map = resolved_styles });
                } else {
                    try resolved_variant.put(a, vv_entry.key_ptr.*, vv_entry.value_ptr.*);
                }
            }
            try resolved_scheme.put(a, variant_name, .{ .map = resolved_variant });
        }
        try result.put(a, scheme_name, .{ .map = resolved_scheme });
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
    default_scheme: []const u8,
    default_mode: []const u8,
    scheme_specs: []const comb.Value,
) [3]comb.Entry {
    return .{
        .{ .key = .{ .string = "default" }, .value = .{ .object = &.{
            .{ .key = .{ .string = "scheme" }, .value = .{ .string = default_scheme } },
            .{ .key = .{ .string = "mode" }, .value = .{ .string = default_mode } },
        } } },
        .{ .key = .{ .string = "schemes" }, .value = .{ .array = scheme_specs } },
        .{ .key = .{ .string = "css" }, .value = .{ .string = "true" } },
    };
}

const test_scheme_yaml =
    \\light:
    \\  meta:
    \\    name: Test Light
    \\    html: Test Light
    \\  palette:
    \\    white: '#ffffff'
    \\    black: '#000000'
    \\    blue: '#0066cc'
    \\    grey: '#999999'
    \\  styles:
    \\    text:
    \\      primary: black
    \\      link: blue
    \\    background:
    \\      primary: white
    \\      secondary: grey
    \\  syntax:
    \\    keyword: blue
    \\    comment: grey
    \\dark:
    \\  meta:
    \\    name: Test Dark
    \\    html: Test Dark
    \\  palette:
    \\    white: '#ffffff'
    \\    black: '#000000'
    \\    red: '#ff3333'
    \\    darkgrey: '#333333'
    \\  styles:
    \\    text:
    \\      primary: white
    \\      link: red
    \\    background:
    \\      primary: black
    \\      secondary: darkgrey
    \\  syntax:
    \\    keyword: red
    \\    comment: darkgrey
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

test "parseSchemeSpec: valid spec" {
    const spec = parseSchemeSpec("solarized.dark").?;
    try testing.expectEqualStrings("solarized", spec.scheme);
    try testing.expectEqualStrings("dark", spec.mode);
}

test "parseSchemeSpec: multiple dots uses first" {
    const spec = parseSchemeSpec("some.scheme.name").?;
    try testing.expectEqualStrings("some", spec.scheme);
    try testing.expectEqualStrings("scheme.name", spec.mode);
}

test "parseSchemeSpec: no dot returns null" {
    try testing.expect(parseSchemeSpec("nodot") == null);
}

test "parseSchemeSpec: leading dot returns null" {
    try testing.expect(parseSchemeSpec(".dark") == null);
}

test "parseSchemeSpec: trailing dot returns null" {
    try testing.expect(parseSchemeSpec("solarized.") == null);
}

test "parseSchemeSpec: empty string returns null" {
    try testing.expect(parseSchemeSpec("") == null);
}

test "resolve: single scheme light" {
    const a = testing.allocator;
    var parsed = try comb.parse(a, test_scheme_yaml);
    defer parsed.deinit();

    const specs = [_]comb.Value{.{ .string = "test.light" }};
    var hl_entries = makeHighlights("test", "light", &specs);
    const highlights = comb.Value{ .object = &hl_entries };
    const scheme_files = [_]SchemeFile{.{ .name = "test", .data = parsed.value }};

    var result = try resolve(a, highlights, &scheme_files);
    defer result.deinit();

    try testing.expectEqualStrings("test-light", getMapStr(result.value, "default_id").?);
    try testing.expectEqualStrings("test", getMapStr(result.value, "default_scheme").?);
    try testing.expectEqualStrings("light", getMapStr(result.value, "default_mode").?);

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
    var parsed = try comb.parse(a, test_scheme_yaml);
    defer parsed.deinit();

    const specs = [_]comb.Value{.{ .string = "test.dark" }};
    var hl_entries = makeHighlights("test", "dark", &specs);
    const highlights = comb.Value{ .object = &hl_entries };
    const scheme_files = [_]SchemeFile{.{ .name = "test", .data = parsed.value }};

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
    var parsed = try comb.parse(a, test_scheme_yaml);
    defer parsed.deinit();

    const specs = [_]comb.Value{
        .{ .string = "test.light" },
        .{ .string = "test.dark" },
    };
    var hl_entries = makeHighlights("test", "dark", &specs);
    const highlights = comb.Value{ .object = &hl_entries };
    const scheme_files = [_]SchemeFile{.{ .name = "test", .data = parsed.value }};

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
    var parsed_test = try comb.parse(a, test_scheme_yaml);
    defer parsed_test.deinit();

    const alt_yaml =
        \\light:
        \\  meta:
        \\    name: Alt Light
        \\    html: Alt Light
        \\  palette:
        \\    fg: '#111111'
        \\    bg: '#eeeeee'
        \\  styles:
        \\    text:
        \\      primary: fg
        \\    background:
        \\      primary: bg
        \\  syntax:
        \\    keyword: fg
    ;
    var parsed_alt = try comb.parse(a, alt_yaml);
    defer parsed_alt.deinit();

    const specs = [_]comb.Value{
        .{ .string = "test.dark" },
        .{ .string = "alt.light" },
    };
    var hl_entries = makeHighlights("test", "dark", &specs);
    const highlights = comb.Value{ .object = &hl_entries };
    const scheme_files = [_]SchemeFile{
        .{ .name = "test", .data = parsed_test.value },
        .{ .name = "alt", .data = parsed_alt.value },
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
    const specs = [_]comb.Value{.{ .string = "missing.dark" }};
    var hl_entries = makeHighlights("missing", "dark", &specs);
    const highlights = comb.Value{ .object = &hl_entries };

    const result = resolve(a, highlights, &.{});
    try testing.expectError(error.SchemeNotFound, result);
}

test "resolve: missing variant returns error" {
    const a = testing.allocator;
    var parsed = try comb.parse(a, test_scheme_yaml);
    defer parsed.deinit();

    const specs = [_]comb.Value{.{ .string = "test.midnight" }};
    var hl_entries = makeHighlights("test", "midnight", &specs);
    const highlights = comb.Value{ .object = &hl_entries };
    const scheme_files = [_]SchemeFile{.{ .name = "test", .data = parsed.value }};

    const result = resolve(a, highlights, &scheme_files);
    try testing.expectError(error.VariantNotFound, result);
}

test "resolve: missing palette key returns error" {
    const a = testing.allocator;
    const bad_yaml =
        \\light:
        \\  meta:
        \\    name: Bad
        \\    html: Bad
        \\  palette:
        \\    white: '#ffffff'
        \\  styles:
        \\    text:
        \\      primary: nonexistent
        \\    background:
        \\      primary: white
        \\  syntax:
        \\    keyword: white
    ;
    var parsed = try comb.parse(a, bad_yaml);
    defer parsed.deinit();

    const specs = [_]comb.Value{.{ .string = "bad.light" }};
    var hl_entries = makeHighlights("bad", "light", &specs);
    const highlights = comb.Value{ .object = &hl_entries };
    const scheme_files = [_]SchemeFile{.{ .name = "bad", .data = parsed.value }};

    const result = resolve(a, highlights, &scheme_files);
    try testing.expectError(error.PaletteKeyNotFound, result);
}

test "resolve: invalid scheme spec returns error" {
    const a = testing.allocator;
    const specs = [_]comb.Value{.{ .string = "nodot" }};
    var hl_entries = makeHighlights("test", "dark", &specs);
    const highlights = comb.Value{ .object = &hl_entries };

    const result = resolve(a, highlights, &.{});
    try testing.expectError(error.InvalidSchemeSpec, result);
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
    var hl_entries = makeHighlights("test", "dark", &.{});
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
        .{ .key = .{ .string = "default" }, .value = .{ .object = &.{
            .{ .key = .{ .string = "scheme" }, .value = .{ .string = "test" } },
            .{ .key = .{ .string = "mode" }, .value = .{ .string = "dark" } },
        } } },
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
        \\light:
        \\  meta:
        \\    name: Rose Pine
        \\    html: "Ros&eacute; Pine"
        \\  palette:
        \\    fg: '#575279'
        \\    bg: '#faf4ed'
        \\  styles:
        \\    text:
        \\      primary: fg
        \\    background:
        \\      primary: bg
        \\  syntax:
        \\    keyword: fg
    ;
    var parsed = try comb.parse(a, yaml);
    defer parsed.deinit();

    const specs = [_]comb.Value{.{ .string = "rose.light" }};
    var hl_entries = makeHighlights("rose", "light", &specs);
    const highlights = comb.Value{ .object = &hl_entries };
    const scheme_files = [_]SchemeFile{.{ .name = "rose", .data = parsed.value }};

    var result = try resolve(a, highlights, &scheme_files);
    defer result.deinit();

    const schemes = getMapList(result.value, "schemes").?;
    try testing.expectEqualStrings("Rose Pine", getMapStr(schemes[0], "name").?);
    try testing.expectEqualStrings("Ros&eacute; Pine", getMapStr(schemes[0], "html").?);
}

test "resolve: scheme without meta uses spec as name" {
    const a = testing.allocator;
    const yaml =
        \\light:
        \\  palette:
        \\    fg: '#000000'
        \\    bg: '#ffffff'
        \\  styles:
        \\    text:
        \\      primary: fg
        \\    background:
        \\      primary: bg
        \\  syntax:
        \\    keyword: fg
    ;
    var parsed = try comb.parse(a, yaml);
    defer parsed.deinit();

    const specs = [_]comb.Value{.{ .string = "minimal.light" }};
    var hl_entries = makeHighlights("minimal", "light", &specs);
    const highlights = comb.Value{ .object = &hl_entries };
    const scheme_files = [_]SchemeFile{.{ .name = "minimal", .data = parsed.value }};

    var result = try resolve(a, highlights, &scheme_files);
    defer result.deinit();

    const schemes = getMapList(result.value, "schemes").?;
    try testing.expectEqualStrings("minimal.light", getMapStr(schemes[0], "name").?);
}

test "resolve: missing palette section returns error" {
    const a = testing.allocator;
    const yaml =
        \\light:
        \\  meta:
        \\    name: No Palette
        \\    html: No Palette
        \\  styles:
        \\    text:
        \\      primary: black
        \\    background:
        \\      primary: white
    ;
    var parsed = try comb.parse(a, yaml);
    defer parsed.deinit();

    const specs = [_]comb.Value{.{ .string = "bad.light" }};
    var hl_entries = makeHighlights("bad", "light", &specs);
    const highlights = comb.Value{ .object = &hl_entries };
    const scheme_files = [_]SchemeFile{.{ .name = "bad", .data = parsed.value }};

    const result = resolve(a, highlights, &scheme_files);
    try testing.expectError(error.MissingPalette, result);
}
