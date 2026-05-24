//! Tiny scalar helpers shared across the algorithm modules.
//!
//! The vector versions of `pavgb` / `absDiff` / `subSat` live in `simd.zig`;
//! this file is the scalar twin so each kernel's SIMD-body + scalar-tail
//! pair can call matching primitives without redefining one-liners in
//! every file.

const std = @import("std");

/// `|a - b|` for two u8 values.
pub inline fn absDiff(a: u8, b: u8) u8 {
    return if (a > b) a - b else b - a;
}

/// Saturating subtract: `max(a - b, 0)`.
pub inline fn subSat(a: u8, b: u8) u8 {
    return if (a > b) a - b else 0;
}

/// `(a + b + 1) >> 1` — rounded average, matches the x86 `pavgb`
/// instruction (and `simd.pavgb` for the vector form).
pub inline fn pavgb(a: u8, b: u8) u8 {
    return @intCast((@as(u16, a) + @as(u16, b) + 1) >> 1);
}

// ---------------------------------------------------------------------------
test "absDiff matches |a - b| both directions" {
    try std.testing.expectEqual(@as(u8, 5), absDiff(10, 5));
    try std.testing.expectEqual(@as(u8, 5), absDiff(5, 10));
    try std.testing.expectEqual(@as(u8, 0), absDiff(7, 7));
    try std.testing.expectEqual(@as(u8, 255), absDiff(0, 255));
}

test "subSat saturates at zero" {
    try std.testing.expectEqual(@as(u8, 5), subSat(10, 5));
    try std.testing.expectEqual(@as(u8, 0), subSat(5, 10));
    try std.testing.expectEqual(@as(u8, 0), subSat(0, 1));
}

test "pavgb rounds up — matches x86 pavgb" {
    try std.testing.expectEqual(@as(u8, 5), pavgb(4, 5));
    try std.testing.expectEqual(@as(u8, 255), pavgb(255, 255));
    try std.testing.expectEqual(@as(u8, 128), pavgb(0, 255));
    try std.testing.expectEqual(@as(u8, 6), pavgb(5, 6)); // (5+6+1)/2 = 6
}
