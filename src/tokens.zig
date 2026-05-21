const std = @import("std");
const comb = @import("comb");
const toupee = @import("toupee");

const Allocator = std.mem.Allocator;
const ValueMap = std.StringArrayHashMapUnmanaged(toupee.Value);

pub const TokenParams = struct {
    viewport_min: f64 = 320,
    viewport_max: f64 = 1240,
    base_min: f64 = 18,
    base_max: f64 = 20,
    scale_min: f64 = 1.2,
    scale_max: f64 = 1.25,
    steps_above: u32 = 5,
    steps_below: u32 = 2,
    accessibility_check: bool = true,
    negative_multipliers: []const f64 = &.{ 0.75, 0.5, 0.25 },
    positive_multipliers: []const f64 = &.{ 1.5, 2, 3, 4, 6 },
    custom_pairs: []const []const u8 = &.{},
};

pub const WcagViolation = struct {
    step: i32,
    min_size: f64,
    max_size: f64,
    viewport_low: f64,
    viewport_high: f64,
};

/// Holds computed token values and owns all allocated memory via an arena.
pub const TokenResult = struct {
    value: toupee.Value,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *TokenResult) void {
        self.arena.deinit();
    }
};

/// Extracts TokenParams from a Comb YAML value (the `tokens:` section of a style manifest).
pub fn extractParams(val: comb.Value, a: Allocator) !TokenParams {
    var params = TokenParams{};

    if (val.get("viewport")) |vp| {
        if (getFloat(vp, "min")) |v| params.viewport_min = v;
        if (getFloat(vp, "max")) |v| params.viewport_max = v;
    }

    if (val.get("typography")) |typo| {
        if (typo.get("base")) |base| {
            if (getFloat(base, "min")) |v| params.base_min = v;
            if (getFloat(base, "max")) |v| params.base_max = v;
        }
        if (typo.get("scale")) |scale| {
            if (getFloat(scale, "min")) |v| params.scale_min = v;
            if (getFloat(scale, "max")) |v| params.scale_max = v;
        }
        if (typo.get("steps")) |steps| {
            if (getInt(steps, "above")) |v| params.steps_above = @intCast(v);
            if (getInt(steps, "below")) |v| params.steps_below = @intCast(v);
        }
        if (typo.get("accessibility_check")) |check| {
            switch (check) {
                .boolean => |b| params.accessibility_check = b,
                else => {},
            }
        }
    }

    if (val.get("spacing")) |spacing| {
        if (spacing.getArray("negative")) |arr| {
            params.negative_multipliers = try extractFloatArray(a, arr);
        }
        if (spacing.getArray("positive")) |arr| {
            params.positive_multipliers = try extractFloatArray(a, arr);
        }
        if (spacing.getArray("pairs")) |arr| {
            const pairs = try a.alloc([]const u8, arr.len);
            var count: usize = 0;
            for (arr) |item| {
                switch (item) {
                    .string => |s| {
                        pairs[count] = s;
                        count += 1;
                    },
                    else => {},
                }
            }
            params.custom_pairs = pairs[0..count];
        }
    }

    return params;
}

fn getFloat(val: comb.Value, key: []const u8) ?f64 {
    return switch (val.get(key) orelse return null) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        else => null,
    };
}

fn getInt(val: comb.Value, key: []const u8) ?i64 {
    return switch (val.get(key) orelse return null) {
        .integer => |i| i,
        else => null,
    };
}

fn extractFloatArray(a: Allocator, arr: []const comb.Value) ![]const f64 {
    const floats = try a.alloc(f64, arr.len);
    var count: usize = 0;
    for (arr) |item| {
        const v: ?f64 = switch (item) {
            .float => |f| f,
            .integer => |i| @floatFromInt(i),
            else => null,
        };
        if (v) |f| {
            floats[count] = f;
            count += 1;
        }
    }
    return floats[0..count];
}

/// Computes fluid typography and spacing tokens from scale parameters.
/// Returns a TokenResult owning all allocated memory via an internal arena.
/// The result's `.value` is a Toupee map:
///   `{ typography: [{name, value}, ...], spacing: {individual, pairs, custom} }`
pub fn compute(backing: Allocator, params: TokenParams) !TokenResult {
    var arena = std.heap.ArenaAllocator.init(backing);
    errdefer arena.deinit();
    const a = arena.allocator();

    var result = ValueMap{};

    const typo = try computeTypography(a, params);
    try result.put(a, "typography", typo);

    const spacing = try computeSpacing(a, params);
    try result.put(a, "spacing", spacing);

    return .{ .value = .{ .map = result }, .arena = arena };
}

/// Checks WCAG 1.4.4 "Resize Text" compliance for all type scale steps.
/// Returns null if all steps pass, or the first violation found.
pub fn checkAccessibility(params: TokenParams) ?WcagViolation {
    if (!params.accessibility_check) return null;

    const total: i32 = @as(i32, @intCast(params.steps_below)) + @as(i32, @intCast(params.steps_above)) + 1;
    const base_step: i32 = @intCast(params.steps_below);

    var i: i32 = 0;
    while (i < total) : (i += 1) {
        const step = i - base_step;
        const min_size = params.base_min * std.math.pow(f64, params.scale_min, @floatFromInt(step));
        const max_size = params.base_max * std.math.pow(f64, params.scale_max, @floatFromInt(step));

        if (checkStepAccessibility(min_size, max_size, params.viewport_min, params.viewport_max)) |range| {
            return .{
                .step = step,
                .min_size = min_size,
                .max_size = max_size,
                .viewport_low = range[0],
                .viewport_high = range[1],
            };
        }
    }
    return null;
}

fn computeTypography(a: Allocator, params: TokenParams) !toupee.Value {
    const total: usize = params.steps_below + params.steps_above + 1;
    const steps = try a.alloc(toupee.Value, total);

    const base_step: i32 = @intCast(params.steps_below);

    for (0..total) |i| {
        const step: i32 = @as(i32, @intCast(i)) - base_step;
        const min_size = params.base_min * std.math.pow(f64, params.scale_min, @floatFromInt(step));
        const max_size = params.base_max * std.math.pow(f64, params.scale_max, @floatFromInt(step));

        const name = try std.fmt.allocPrint(a, "step-{d}", .{step});
        const value = try formatClamp(a, min_size, max_size, params.viewport_min, params.viewport_max);

        var entry = ValueMap{};
        try entry.put(a, "name", .{ .string = name });
        try entry.put(a, "value", .{ .string = value });
        steps[i] = .{ .map = entry };
    }

    return .{ .list = steps };
}

fn computeSpacing(a: Allocator, params: TokenParams) !toupee.Value {
    var result = ValueMap{};

    const neg_count = params.negative_multipliers.len;
    const pos_count = params.positive_multipliers.len;
    const individual_count = neg_count + 1 + pos_count;

    const individual = try a.alloc(toupee.Value, individual_count);

    for (0..neg_count) |i| {
        const mult_idx = neg_count - 1 - i;
        const mult = params.negative_multipliers[mult_idx];
        const label = try spaceLabel(a, -@as(i32, @intCast(neg_count - i)));
        const min_size = params.base_min * mult;
        const max_size = params.base_max * mult;
        const value = try formatClamp(a, min_size, max_size, params.viewport_min, params.viewport_max);

        var entry = ValueMap{};
        try entry.put(a, "name", .{ .string = label });
        try entry.put(a, "value", .{ .string = value });
        individual[i] = .{ .map = entry };
    }

    {
        const value = try formatClamp(a, params.base_min, params.base_max, params.viewport_min, params.viewport_max);
        var entry = ValueMap{};
        try entry.put(a, "name", .{ .string = try a.dupe(u8, "s") });
        try entry.put(a, "value", .{ .string = value });
        individual[neg_count] = .{ .map = entry };
    }

    for (0..pos_count) |i| {
        const mult = params.positive_multipliers[i];
        const label = try spaceLabel(a, @as(i32, @intCast(i)) + 1);
        const min_size = params.base_min * mult;
        const max_size = params.base_max * mult;
        const value = try formatClamp(a, min_size, max_size, params.viewport_min, params.viewport_max);

        var entry = ValueMap{};
        try entry.put(a, "name", .{ .string = label });
        try entry.put(a, "value", .{ .string = value });
        individual[neg_count + 1 + i] = .{ .map = entry };
    }

    try result.put(a, "individual", .{ .list = individual });

    if (individual_count > 1) {
        const pair_count = individual_count - 1;
        const pairs = try a.alloc(toupee.Value, pair_count);

        for (0..pair_count) |i| {
            const small_name = individual[i].map.get("name").?.string;
            const large_name = individual[i + 1].map.get("name").?.string;
            const name = try std.fmt.allocPrint(a, "{s}-{s}", .{ small_name, large_name });

            const small_min = getMinSize(params, i, neg_count);
            const large_max = getMaxSize(params, i + 1, neg_count);
            const value = try formatClamp(a, small_min, large_max, params.viewport_min, params.viewport_max);

            var entry = ValueMap{};
            try entry.put(a, "name", .{ .string = name });
            try entry.put(a, "value", .{ .string = value });
            pairs[i] = .{ .map = entry };
        }

        try result.put(a, "pairs", .{ .list = pairs });
    }

    if (params.custom_pairs.len > 0) {
        const custom = try a.alloc(toupee.Value, params.custom_pairs.len);
        var count: usize = 0;

        for (params.custom_pairs) |pair_str| {
            const dash = std.mem.indexOfScalar(u8, pair_str, '-') orelse continue;
            const from_label = pair_str[0..dash];
            const to_label = pair_str[dash + 1 ..];

            const from_idx = labelToIndex(from_label, params) orelse continue;
            const to_idx = labelToIndex(to_label, params) orelse continue;

            const min_size = getMinSize(params, from_idx, params.negative_multipliers.len);
            const max_size = getMaxSize(params, to_idx, params.negative_multipliers.len);
            const value = try formatClamp(a, min_size, max_size, params.viewport_min, params.viewport_max);

            var entry = ValueMap{};
            try entry.put(a, "name", .{ .string = try a.dupe(u8, pair_str) });
            try entry.put(a, "value", .{ .string = value });
            custom[count] = .{ .map = entry };
            count += 1;
        }

        try result.put(a, "custom", .{ .list = custom[0..count] });
    }

    return .{ .map = result };
}

fn getMinSize(params: TokenParams, idx: usize, neg_count: usize) f64 {
    if (idx < neg_count) {
        return params.base_min * params.negative_multipliers[neg_count - 1 - idx];
    } else if (idx == neg_count) {
        return params.base_min;
    } else {
        return params.base_min * params.positive_multipliers[idx - neg_count - 1];
    }
}

fn getMaxSize(params: TokenParams, idx: usize, neg_count: usize) f64 {
    if (idx < neg_count) {
        return params.base_max * params.negative_multipliers[neg_count - 1 - idx];
    } else if (idx == neg_count) {
        return params.base_max;
    } else {
        return params.base_max * params.positive_multipliers[idx - neg_count - 1];
    }
}

fn labelToIndex(label: []const u8, params: TokenParams) ?usize {
    const neg_count = params.negative_multipliers.len;

    const known = [_]struct { step: i32, label: []const u8 }{
        .{ .step = -1, .label = "xs" },
        .{ .step = 0, .label = "s" },
        .{ .step = 1, .label = "m" },
        .{ .step = 2, .label = "l" },
        .{ .step = 3, .label = "xl" },
    };

    for (known) |entry| {
        if (std.mem.eql(u8, label, entry.label)) {
            return stepToIndex(entry.step, neg_count, params.positive_multipliers.len);
        }
    }

    if (std.mem.endsWith(u8, label, "xs")) {
        const n = std.fmt.parseInt(u32, label[0 .. label.len - 2], 10) catch return null;
        return stepToIndex(-@as(i32, @intCast(n)), neg_count, params.positive_multipliers.len);
    } else if (std.mem.endsWith(u8, label, "xl")) {
        const n = std.fmt.parseInt(u32, label[0 .. label.len - 2], 10) catch return null;
        return stepToIndex(@as(i32, @intCast(n)) + 2, neg_count, params.positive_multipliers.len);
    }

    return null;
}

fn stepToIndex(step: i32, neg_count: usize, pos_count: usize) ?usize {
    if (step < 0) {
        const neg_idx: usize = @intCast(-step);
        if (neg_idx <= neg_count) return neg_count - neg_idx;
    } else {
        const idx: usize = @intCast(step);
        if (idx == 0) return neg_count;
        if (idx - 1 < pos_count) return neg_count + idx;
    }
    return null;
}

/// Generates a t-shirt size label for a spacing step.
/// Always allocates; caller must free (or use an arena).
pub fn spaceLabel(a: Allocator, step: i32) ![]const u8 {
    return switch (step) {
        -1 => try a.dupe(u8, "xs"),
        0 => try a.dupe(u8, "s"),
        1 => try a.dupe(u8, "m"),
        2 => try a.dupe(u8, "l"),
        3 => try a.dupe(u8, "xl"),
        else => if (step > 3)
            try std.fmt.allocPrint(a, "{d}xl", .{step - 2})
        else
            try std.fmt.allocPrint(a, "{d}xs", .{@as(i32, 0) - step}),
    };
}

/// Produces a CSS `clamp()` value for fluid scaling between two viewport widths.
/// All sizes in px; output in rem (divides by 16).
pub fn formatClamp(a: Allocator, min_size: f64, max_size: f64, min_vp: f64, max_vp: f64) ![]const u8 {
    const d = 16.0;
    const is_neg = min_size > max_size;
    const clamp_min = if (is_neg) max_size else min_size;
    const clamp_max = if (is_neg) min_size else max_size;

    const slope = (max_size / d - min_size / d) / (max_vp / d - min_vp / d);
    const intercept = -(min_vp / d) * slope + min_size / d;

    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);

    try w.writeAll("clamp(");
    try writeRoundedFloat(&w, clamp_min / d);
    try w.writeAll("rem, ");
    try writeRoundedFloat(&w, intercept);
    try w.writeAll("rem + ");
    try writeRoundedFloat(&w, slope * 100.0);
    try w.writeAll("vw, ");
    try writeRoundedFloat(&w, clamp_max / d);
    try w.writeAll("rem)");

    return try a.dupe(u8, w.buffered());
}

fn writeRoundedFloat(writer: anytype, val: f64) !void {
    const rounded = @round(val * 10000.0) / 10000.0;
    if (rounded == @trunc(rounded)) {
        try writer.print("{d}", .{@as(i64, @intFromFloat(rounded))});
    } else {
        var float_buf: [32]u8 = undefined;
        const float_str = try std.fmt.bufPrint(&float_buf, "{d:.4}", .{rounded});
        var end: usize = float_str.len;
        while (end > 0 and float_str[end - 1] == '0') end -= 1;
        if (end > 0 and float_str[end - 1] == '.') end -= 1;
        try writer.writeAll(float_str[0..end]);
    }
}

/// WCAG 1.4.4 "Resize Text" check for a single type scale step.
fn checkStepAccessibility(min_size: f64, max_size: f64, min_vp: f64, max_vp: f64) ?[2]f64 {
    var mn = min_size;
    var mx = max_size;
    var mn_w = min_vp;
    var mx_w = max_vp;

    if (mn_w > mx_w) {
        const tw = mn_w;
        mn_w = mx_w;
        mx_w = tw;
        const ts = mn;
        mn = mx;
        mx = ts;
    }

    const slope = (mx - mn) / (mx_w - mn_w);
    if (slope == 0) return null;

    const intercept = mn - mn_w * slope;
    const lh = (5.0 * mn - 2.0 * intercept) / (2.0 * slope);
    const rh = (5.0 * intercept - 2.0 * mx) / (-slope);
    const lh2 = 3.0 * intercept / slope;

    if (intercept >= 0) {
        if (lh2 >= mn_w and lh2 <= mx_w) return .{ mn_w, lh2 };
    } else {
        const low = @max(mn_w, @min(lh, rh));
        const high = @min(mx_w, @max(lh, rh));
        if (low < high) return .{ low, high };
    }

    return null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "spaceLabel: standard labels" {
    const a = std.testing.allocator;
    const xs = try spaceLabel(a, -1);
    defer a.free(xs);
    try std.testing.expectEqualStrings("xs", xs);

    const s = try spaceLabel(a, 0);
    defer a.free(s);
    try std.testing.expectEqualStrings("s", s);

    const m = try spaceLabel(a, 1);
    defer a.free(m);
    try std.testing.expectEqualStrings("m", m);

    const l = try spaceLabel(a, 2);
    defer a.free(l);
    try std.testing.expectEqualStrings("l", l);

    const xl = try spaceLabel(a, 3);
    defer a.free(xl);
    try std.testing.expectEqualStrings("xl", xl);
}

test "spaceLabel: extended labels" {
    const a = std.testing.allocator;

    const label_2xl = try spaceLabel(a, 4);
    defer a.free(label_2xl);
    try std.testing.expectEqualStrings("2xl", label_2xl);

    const label_3xl = try spaceLabel(a, 5);
    defer a.free(label_3xl);
    try std.testing.expectEqualStrings("3xl", label_3xl);

    const label_2xs = try spaceLabel(a, -2);
    defer a.free(label_2xs);
    try std.testing.expectEqualStrings("2xs", label_2xs);

    const label_3xs = try spaceLabel(a, -3);
    defer a.free(label_3xs);
    try std.testing.expectEqualStrings("3xs", label_3xs);
}

test "formatClamp: basic formula" {
    const a = std.testing.allocator;
    const result = try formatClamp(a, 18, 20, 320, 1240);
    defer a.free(result);

    try std.testing.expect(std.mem.startsWith(u8, result, "clamp("));
    try std.testing.expect(std.mem.endsWith(u8, result, "rem)"));
    try std.testing.expect(std.mem.indexOf(u8, result, "vw") != null);
}

test "formatClamp: inverted sizes (min > max)" {
    const a = std.testing.allocator;
    const result = try formatClamp(a, 30, 20, 320, 1240);
    defer a.free(result);

    try std.testing.expect(std.mem.startsWith(u8, result, "clamp("));
}

test "writeRoundedFloat: integer values" {
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeRoundedFloat(&w, 3.0);
    try std.testing.expectEqualStrings("3", w.buffered());
}

test "writeRoundedFloat: decimal values with trailing zero trimming" {
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeRoundedFloat(&w, 1.125);
    try std.testing.expectEqualStrings("1.125", w.buffered());
}

test "compute: default params produce expected structure" {
    const a = std.testing.allocator;
    const params = TokenParams{};
    var result = try compute(a, params);
    defer result.deinit();

    const typo = result.value.map.get("typography") orelse return error.TestUnexpectedResult;
    try std.testing.expect(typo == .list);
    try std.testing.expectEqual(@as(usize, 8), typo.list.len);

    const spacing = result.value.map.get("spacing") orelse return error.TestUnexpectedResult;
    try std.testing.expect(spacing == .map);

    const ind = spacing.map.get("individual") orelse return error.TestUnexpectedResult;
    try std.testing.expect(ind == .list);
    try std.testing.expectEqual(@as(usize, 9), ind.list.len);
}

test "compute: typography step names" {
    const a = std.testing.allocator;
    const params = TokenParams{ .steps_below = 1, .steps_above = 2 };
    var result = try compute(a, params);
    defer result.deinit();

    const typo = result.value.map.get("typography").?;
    try std.testing.expectEqualStrings("step--1", typo.list[0].map.get("name").?.string);
    try std.testing.expectEqualStrings("step-0", typo.list[1].map.get("name").?.string);
    try std.testing.expectEqualStrings("step-1", typo.list[2].map.get("name").?.string);
    try std.testing.expectEqualStrings("step-2", typo.list[3].map.get("name").?.string);
}

test "compute: spacing individual labels" {
    const a = std.testing.allocator;
    const params = TokenParams{
        .negative_multipliers = &.{ 0.75, 0.5 },
        .positive_multipliers = &.{ 1.5, 2 },
    };
    var result = try compute(a, params);
    defer result.deinit();

    const ind = result.value.map.get("spacing").?.map.get("individual").?;
    try std.testing.expectEqualStrings("2xs", ind.list[0].map.get("name").?.string);
    try std.testing.expectEqualStrings("xs", ind.list[1].map.get("name").?.string);
    try std.testing.expectEqualStrings("s", ind.list[2].map.get("name").?.string);
    try std.testing.expectEqualStrings("m", ind.list[3].map.get("name").?.string);
    try std.testing.expectEqualStrings("l", ind.list[4].map.get("name").?.string);
}

test "compute: spacing pairs (one-up adjacent)" {
    const a = std.testing.allocator;
    const params = TokenParams{
        .negative_multipliers = &.{0.75},
        .positive_multipliers = &.{1.5},
    };
    var result = try compute(a, params);
    defer result.deinit();

    const pairs = result.value.map.get("spacing").?.map.get("pairs").?;
    try std.testing.expectEqual(@as(usize, 2), pairs.list.len);
    try std.testing.expectEqualStrings("xs-s", pairs.list[0].map.get("name").?.string);
    try std.testing.expectEqualStrings("s-m", pairs.list[1].map.get("name").?.string);
}

test "compute: custom pairs" {
    const a = std.testing.allocator;
    const params = TokenParams{
        .negative_multipliers = &.{ 0.75, 0.5, 0.25 },
        .positive_multipliers = &.{ 1.5, 2, 3, 4, 6 },
        .custom_pairs = &.{"s-l"},
    };
    var result = try compute(a, params);
    defer result.deinit();

    const custom = result.value.map.get("spacing").?.map.get("custom").?;
    try std.testing.expectEqual(@as(usize, 1), custom.list.len);
    try std.testing.expectEqualStrings("s-l", custom.list[0].map.get("name").?.string);
    const value = custom.list[0].map.get("value").?.string;
    try std.testing.expect(std.mem.startsWith(u8, value, "clamp("));
}

test "checkAccessibility: default params pass" {
    const params = TokenParams{};
    try std.testing.expect(checkAccessibility(params) == null);
}

test "checkAccessibility: disabled returns null" {
    const params = TokenParams{ .accessibility_check = false };
    try std.testing.expect(checkAccessibility(params) == null);
}

test "checkAccessibility: extreme scale detects violation" {
    const params = TokenParams{
        .scale_min = 1.5,
        .scale_max = 1.8,
        .steps_above = 8,
    };
    const violation = checkAccessibility(params);
    try std.testing.expect(violation != null);
}

test "extractParams: reads manifest YAML" {
    const yaml =
        \\viewport:
        \\  min: 320
        \\  max: 1240
        \\typography:
        \\  base:
        \\    min: 18
        \\    max: 20
        \\  scale:
        \\    min: 1.2
        \\    max: 1.25
        \\  steps:
        \\    above: 5
        \\    below: 2
        \\spacing:
        \\  negative: [0.75, 0.5, 0.25]
        \\  positive: [1.5, 2, 3, 4, 6]
        \\  pairs: [s-l]
    ;

    const a = std.testing.allocator;
    var parsed = try comb.parse(a, yaml);
    defer parsed.deinit();

    const params = try extractParams(parsed.value, a);
    defer a.free(params.negative_multipliers);
    defer a.free(params.positive_multipliers);
    defer a.free(params.custom_pairs);

    try std.testing.expectEqual(@as(f64, 320), params.viewport_min);
    try std.testing.expectEqual(@as(f64, 1240), params.viewport_max);
    try std.testing.expectEqual(@as(f64, 18), params.base_min);
    try std.testing.expectEqual(@as(f64, 20), params.base_max);
    try std.testing.expectEqual(@as(f64, 1.2), params.scale_min);
    try std.testing.expectEqual(@as(f64, 1.25), params.scale_max);
    try std.testing.expectEqual(@as(u32, 5), params.steps_above);
    try std.testing.expectEqual(@as(u32, 2), params.steps_below);
    try std.testing.expectEqual(@as(usize, 3), params.negative_multipliers.len);
    try std.testing.expectEqual(@as(usize, 5), params.positive_multipliers.len);
    try std.testing.expectEqual(@as(usize, 1), params.custom_pairs.len);
    try std.testing.expectEqualStrings("s-l", params.custom_pairs[0]);
}

test "extractParams: defaults for missing fields" {
    const yaml = "viewport:\n  min: 400";
    const a = std.testing.allocator;
    var parsed = try comb.parse(a, yaml);
    defer parsed.deinit();

    const params = try extractParams(parsed.value, a);

    try std.testing.expectEqual(@as(f64, 400), params.viewport_min);
    try std.testing.expectEqual(@as(f64, 1240), params.viewport_max);
    try std.testing.expectEqual(@as(f64, 18), params.base_min);
    try std.testing.expect(params.accessibility_check);
}

test "checkStepAccessibility: safe step passes" {
    const result = checkStepAccessibility(18, 20, 320, 1240);
    try std.testing.expect(result == null);
}
