//! Tiny scalar helpers shared across the algorithm modules.
//!
//! The vector versions of `pavgb` / `absDiff` / `subSat` live in `simd.zig`;
//! this file is the scalar twin so each kernel's SIMD-body + scalar-tail
//! pair can call matching primitives without redefining one-liners in
//! every file.
//!
//! Generic over the pixel type via `anytype` — the supported set is any
//! unsigned integer (u8 for 8-bit, u16 for 10/12/16-bit pixel storage).
//! Element type is inferred from the arguments; widening for `pavgb` is
//! `std.meta.Int(.unsigned, bitSize*2)`.

const std = @import("std");

/// `|a - b|`. Element type is inferred from `a`.
pub inline fn absDiff(a: anytype, b: @TypeOf(a)) @TypeOf(a) {
    return if (a > b) a - b else b - a;
}

/// Saturating subtract: `max(a - b, 0)`. Element type is inferred from `a`.
pub inline fn subSat(a: anytype, b: @TypeOf(a)) @TypeOf(a) {
    return if (a > b) a - b else 0;
}

/// `(a + b + 1) >> 1` — rounded average, matches the x86 `pavgb`
/// instruction (and `simd.pavgb` for the vector form). Widens to
/// double-width internally to avoid overflow.
pub inline fn pavgb(a: anytype, b: @TypeOf(a)) @TypeOf(a) {
    const T = @TypeOf(a);
    const WideT = std.meta.Int(.unsigned, @bitSizeOf(T) * 2);
    return @intCast((@as(WideT, a) + @as(WideT, b) + 1) >> 1);
}

// ---------------------------------------------------------------------------
test "absDiff matches |a - b| both directions" {
    try std.testing.expectEqual(@as(u8, 5), absDiff(@as(u8, 10), 5));
    try std.testing.expectEqual(@as(u8, 5), absDiff(@as(u8, 5), 10));
    try std.testing.expectEqual(@as(u8, 0), absDiff(@as(u8, 7), 7));
    try std.testing.expectEqual(@as(u8, 255), absDiff(@as(u8, 0), 255));
}

test "absDiff works on u16" {
    try std.testing.expectEqual(@as(u16, 500), absDiff(@as(u16, 1000), 500));
    try std.testing.expectEqual(@as(u16, 65535), absDiff(@as(u16, 0), 65535));
}

test "subSat saturates at zero" {
    try std.testing.expectEqual(@as(u8, 5), subSat(@as(u8, 10), 5));
    try std.testing.expectEqual(@as(u8, 0), subSat(@as(u8, 5), 10));
    try std.testing.expectEqual(@as(u8, 0), subSat(@as(u8, 0), 1));
}

test "pavgb rounds up — matches x86 pavgb" {
    try std.testing.expectEqual(@as(u8, 5), pavgb(@as(u8, 4), 5));
    try std.testing.expectEqual(@as(u8, 255), pavgb(@as(u8, 255), 255));
    try std.testing.expectEqual(@as(u8, 128), pavgb(@as(u8, 0), 255));
    try std.testing.expectEqual(@as(u8, 6), pavgb(@as(u8, 5), 6)); // (5+6+1)/2 = 6
}

test "pavgb works on u16 without overflow" {
    try std.testing.expectEqual(@as(u16, 65535), pavgb(@as(u16, 65535), 65535));
    try std.testing.expectEqual(@as(u16, 32768), pavgb(@as(u16, 0), 65535));
    try std.testing.expectEqual(@as(u16, 513), pavgb(@as(u16, 512), 513)); // (512+513+1)/2 = 513
}
