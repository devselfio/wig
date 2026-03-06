const std = @import("std");
const comb = @import("comb");
const toupee = @import("toupee");

const Allocator = std.mem.Allocator;

/// Resolves colour scheme palette indirection.
/// Takes highlight config (scheme names) and colour data files,
/// resolves role -> palette key -> hex, returns Toupee Value.
pub fn resolve(a: Allocator, highlights: []const []const u8, colour_data: anytype) !toupee.Value {
    _ = a;
    _ = highlights;
    _ = colour_data;
    return error.NotImplemented;
}

const NotImplemented = error{NotImplemented};

test "colours: placeholder" {
    // Populated in Phase 2.6
}
