const std = @import("std");
const toupee = @import("toupee");

const Allocator = std.mem.Allocator;

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

/// Computes fluid typography and spacing tokens from scale parameters.
/// Returns a Toupee Value map suitable for injection into template context.
pub fn compute(a: Allocator, params: TokenParams) !toupee.Value {
    _ = a;
    _ = params;
    return error.NotImplemented;
}

test "tokens: placeholder" {
    // Populated in Phase 2.5
}
