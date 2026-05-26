//! Small helpers for the `@Vector(N, T)` SIMD kernels.
//!
//! The pure-C kernels in the algorithm modules are kept as the bit-exact
//! reference for `tests/integration/test_upstream_compare.py`. The SIMD
//! variants must produce **identical** bytes per pixel; that's the contract
//! the upstream-compare test enforces on every CI run.
//!
//! Generic over the pixel storage type via `anytype`. Element type is
//! inferred from the vector arguments through `std.meta.Child`. The
//! supported set is `u8` (8-bit pipelines) and `u16` (10/12/16-bit
//! pipelines where the upper bits of the u16 storage are zero).

const std = @import("std");

/// `(a + b + 1) >> 1` element-wise, matching the x86 `pavgb` semantics
/// (rounding average of two vectors). Widens to double-width per lane
/// to avoid overflow, then narrows back to the input element type.
pub inline fn pavgb(comptime N: usize, a: anytype, b: @TypeOf(a)) @TypeOf(a) {
    const T = std.meta.Child(@TypeOf(a));
    const WideT = std.meta.Int(.unsigned, @bitSizeOf(T) * 2);
    const ShiftT = std.math.Log2Int(WideT);
    const a_w: @Vector(N, WideT) = a;
    const b_w: @Vector(N, WideT) = b;
    return @intCast((a_w + b_w + @as(@Vector(N, WideT), @splat(1))) >> @as(@Vector(N, ShiftT), @splat(1)));
}

/// `|a - b|` element-wise (= max(a,b) - min(a,b)).
pub inline fn absDiff(comptime N: usize, a: anytype, b: @TypeOf(a)) @TypeOf(a) {
    comptime std.debug.assert(@typeInfo(@TypeOf(a)).vector.len == N);
    return @max(a, b) - @min(a, b);
}

/// Saturating subtract: `max(a - b, 0)`, element-wise. Matches `psubusb`
/// / `psubusw`.
pub inline fn subSat(comptime N: usize, a: anytype, b: @TypeOf(a)) @TypeOf(a) {
    comptime std.debug.assert(@typeInfo(@TypeOf(a)).vector.len == N);
    return @max(a, b) - b;
}

/// Duplicate each lane: `[x0, x1, ..., xN-1]` ->
/// `[x0, x0, x1, x1, ..., xN-1, xN-1]`. Used to broadcast chroma stats
/// to their two paired luma lanes (4:2:0/4:2:2 only — for 4:4:4 chroma
/// is same-rate and this helper isn't needed).
pub inline fn expandPairs(comptime N: usize, v: anytype) @Vector(N * 2, std.meta.Child(@TypeOf(v))) {
    const T = std.meta.Child(@TypeOf(v));
    comptime var mask: [N * 2]i32 = undefined;
    comptime {
        for (0..N) |i| {
            mask[i * 2] = @intCast(i);
            mask[i * 2 + 1] = @intCast(i);
        }
    }
    return @shuffle(T, v, undefined, mask);
}

/// Load `N` contiguous samples from `ptr + offset` as a vector. Element
/// type and return vector type are inferred from `ptr`'s pointee type.
pub inline fn load(comptime N: usize, ptr: anytype, offset: usize) @Vector(N, std.meta.Child(@TypeOf(ptr))) {
    return ptr[offset..][0..N].*;
}

/// Store a vector to `ptr + offset`.
pub inline fn store(comptime N: usize, ptr: anytype, offset: usize, v: anytype) void {
    ptr[offset..][0..N].* = v;
}

/// Vector counterpart to `scalar.toMapByte` — downscale `@Vector(N, T)` to
/// `@Vector(N, u8)` by shifting right `bits - 8`. For T=u8 this is identity.
pub inline fn toMapByteVec(comptime T: type, comptime bits: u8, comptime N: usize, v: @Vector(N, T)) @Vector(N, u8) {
    if (T == u8) return v;
    const ShiftT = std.math.Log2Int(T);
    return @intCast(v >> @as(@Vector(N, ShiftT), @splat(@intCast(bits - 8))));
}

// ---------------------------------------------------------------------------
test "pavgb matches scalar (a + b + 1) / 2 (u8)" {
    const a: @Vector(16, u8) = .{ 0, 1, 2, 3, 255, 254, 100, 50, 80, 70, 60, 200, 150, 10, 20, 30 };
    const b: @Vector(16, u8) = .{ 0, 0, 0, 5, 255, 1, 100, 60, 80, 80, 70, 100, 130, 30, 10, 10 };
    const got = pavgb(16, a, b);
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        const expected: u8 = @intCast((@as(u16, a[i]) + @as(u16, b[i]) + 1) >> 1);
        try std.testing.expectEqual(expected, got[i]);
    }
}

test "pavgb u16 lanes — no overflow at 65535" {
    const a: @Vector(8, u16) = .{ 65535, 0, 1023, 512, 4095, 65000, 100, 50000 };
    const b: @Vector(8, u16) = .{ 65535, 65535, 512, 1023, 0, 1, 200, 1000 };
    const got = pavgb(8, a, b);
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        const expected: u16 = @intCast((@as(u32, a[i]) + @as(u32, b[i]) + 1) >> 1);
        try std.testing.expectEqual(expected, got[i]);
    }
}

test "absDiff matches |a - b| (u8)" {
    const a: @Vector(8, u8) = .{ 10, 200, 0, 255, 80, 80, 100, 20 };
    const b: @Vector(8, u8) = .{ 90, 100, 0, 0, 80, 100, 20, 100 };
    const got = absDiff(8, a, b);
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        const e: u8 = if (a[i] > b[i]) a[i] - b[i] else b[i] - a[i];
        try std.testing.expectEqual(e, got[i]);
    }
}

test "absDiff u16" {
    const a: @Vector(4, u16) = .{ 1000, 65535, 256, 0 };
    const b: @Vector(4, u16) = .{ 500, 0, 256, 65535 };
    const got = absDiff(4, a, b);
    const want = @Vector(4, u16){ 500, 65535, 0, 65535 };
    try std.testing.expectEqual(want, got);
}

test "subSat saturates at zero (u8)" {
    const a: @Vector(8, u8) = .{ 10, 50, 100, 250, 0, 200, 1, 255 };
    const b: @Vector(8, u8) = .{ 20, 50, 80, 5, 200, 200, 1, 0 };
    const got = subSat(8, a, b);
    const want = @Vector(8, u8){ 0, 0, 20, 245, 0, 0, 0, 255 };
    try std.testing.expectEqual(want, got);
}

test "expandPairs duplicates each lane (u8)" {
    const v = @Vector(4, u8){ 7, 11, 13, 17 };
    const got = expandPairs(4, v);
    const want = @Vector(8, u8){ 7, 7, 11, 11, 13, 13, 17, 17 };
    try std.testing.expectEqual(want, got);
}

test "expandPairs u16" {
    const v = @Vector(4, u16){ 100, 1000, 10000, 65535 };
    const got = expandPairs(4, v);
    const want = @Vector(8, u16){ 100, 100, 1000, 1000, 10000, 10000, 65535, 65535 };
    try std.testing.expectEqual(want, got);
}

test "load/store u16" {
    var buf = [_]u16{ 10, 20, 30, 40, 50, 60, 70, 80 };
    const v = load(4, @as([*]const u16, &buf), 2);
    try std.testing.expectEqual(@Vector(4, u16){ 30, 40, 50, 60 }, v);
    const w = @Vector(4, u16){ 100, 200, 300, 400 };
    store(4, @as([*]u16, &buf), 4, w);
    try std.testing.expectEqual(@as(u16, 100), buf[4]);
    try std.testing.expectEqual(@as(u16, 400), buf[7]);
}
