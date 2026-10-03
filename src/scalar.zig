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
//! `@Int(.unsigned, bitSize*2)`.

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
    const WideT = @Int(.unsigned, @bitSizeOf(T) * 2);
    return @intCast((@as(WideT, a) + @as(WideT, b) + 1) >> 1);
}

/// `pavgb` for the *decision* metrics (evalIv / makeDeMap) ONLY: the rounding
/// happens at the 8-bit-map level, so `toMapByte(>> (bits-8))` of the result is
/// identical regardless of storage depth — keeping IVTC field/cadence decisions
/// bit-depth-deterministic. At 8-bit it is exactly `pavgb`. NEVER use on output
/// pixels; those keep the full-precision `pavgb`.
pub inline fn pavgbScore(comptime bits: u8, a: anytype, b: @TypeOf(a)) @TypeOf(a) {
    if (bits == 8) return pavgb(a, b);
    const sh: std.math.Log2Int(@TypeOf(a)) = @intCast(bits - 8);
    return (((a >> sh) + (b >> sh) + 1) >> 1) << sh;
}

/// Downscale a T-typed pixel or diff to a u8 motion/edge-map byte by
/// shifting right by `bits - 8`. For T=u8 this is identity. For u16-storage
/// at bits=10/12/16, the value's upper bits collapse into the u8 range,
/// keeping motion/edge classification thresholds (12, 4, 40, etc.) at their
/// 8-bit semantics.
pub inline fn toMapByte(comptime T: type, comptime bits: u8, v: T) u8 {
    if (T == u8) return v;
    // Saturate: VS does not enforce the nominal range, so a clip labelled
    // 10/12-bit can carry samples with upper bits set; their diffs shift
    // to > 255. (At bits=16 the shift alone already bounds to 255.)
    return @intCast(@min(v >> @intCast(bits - 8), 255));
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

test "toMapByte saturates out-of-nominal-range HBD samples" {
    // A "10-bit" sample with upper bits set (VS doesn't enforce the nominal
    // range): 65535 >> 2 = 16383 would not fit u8 without the clamp.
    try std.testing.expectEqual(@as(u8, 255), toMapByte(u16, 10, 65535));
    try std.testing.expectEqual(@as(u8, 255), toMapByte(u16, 12, 65535));
    try std.testing.expectEqual(@as(u8, 255), toMapByte(u16, 16, 65535));
    // In-range values are unaffected.
    try std.testing.expectEqual(@as(u8, 250), toMapByte(u16, 10, 1000));
    try std.testing.expectEqual(@as(u8, 255), toMapByte(u16, 10, 1023));
}
