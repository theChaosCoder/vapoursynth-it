//! Small helpers for the `@Vector(N, u8)` SIMD kernels.
//!
//! The pure-C kernels in the algorithm modules are kept as the bit-exact
//! reference for `tests/integration/test_upstream_compare.py`. The SIMD
//! variants must produce **identical** bytes per pixel; that's the contract
//! the upstream-compare test enforces on every CI run.

const std = @import("std");

/// `(a + b + 1) >> 1` element-wise, matching the x86 `pavgb` semantics
/// (rounding average of two u8 vectors).
pub inline fn pavgb(comptime N: usize, a: @Vector(N, u8), b: @Vector(N, u8)) @Vector(N, u8) {
    const a16: @Vector(N, u16) = a;
    const b16: @Vector(N, u16) = b;
    const sum = a16 + b16 + @as(@Vector(N, u16), @splat(1));
    return @intCast(sum >> @as(@Vector(N, u4), @splat(1)));
}

/// `|a - b|` element-wise (= max(a,b) - min(a,b)).
pub inline fn absDiff(comptime N: usize, a: @Vector(N, u8), b: @Vector(N, u8)) @Vector(N, u8) {
    return @max(a, b) - @min(a, b);
}

/// Saturating subtract: `max(a - b, 0)`, element-wise. Matches `psubusb`.
pub inline fn subSat(comptime N: usize, a: @Vector(N, u8), b: @Vector(N, u8)) @Vector(N, u8) {
    return @max(a, b) - b;
}

/// Duplicate each lane of a u8 vector: `[x0, x1, ..., xN-1]` ->
/// `[x0, x0, x1, x1, ..., xN-1, xN-1]`. Used to broadcast chroma stats
/// to their two paired luma lanes.
pub inline fn expandPairs(comptime N: usize, v: @Vector(N, u8)) @Vector(N * 2, u8) {
    comptime var mask: [N * 2]i32 = undefined;
    comptime {
        for (0..N) |i| {
            mask[i * 2] = @intCast(i);
            mask[i * 2 + 1] = @intCast(i);
        }
    }
    return @shuffle(u8, v, undefined, mask);
}

/// Load `N` contiguous bytes from `ptr + offset` as a u8 vector.
pub inline fn load(comptime N: usize, ptr: [*]const u8, offset: usize) @Vector(N, u8) {
    return ptr[offset..][0..N].*;
}

/// Store a u8 vector to `ptr + offset`.
pub inline fn store(comptime N: usize, ptr: [*]u8, offset: usize, v: @Vector(N, u8)) void {
    ptr[offset..][0..N].* = v;
}

// ---------------------------------------------------------------------------
test "pavgb matches scalar (b + c + 1) / 2" {
    const a: @Vector(16, u8) = .{ 0, 1, 2, 3, 255, 254, 100, 50, 80, 70, 60, 200, 150, 10, 20, 30 };
    const b: @Vector(16, u8) = .{ 0, 0, 0, 5, 255, 1, 100, 60, 80, 80, 70, 100, 130, 30, 10, 10 };
    const got = pavgb(16, a, b);
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        const expected: u8 = @intCast((@as(u16, a[i]) + @as(u16, b[i]) + 1) >> 1);
        try std.testing.expectEqual(expected, got[i]);
    }
}

test "absDiff matches |a - b|" {
    const a: @Vector(8, u8) = .{ 10, 200, 0, 255, 80, 80, 100, 20 };
    const b: @Vector(8, u8) = .{ 90, 100, 0, 0, 80, 100, 20, 100 };
    const got = absDiff(8, a, b);
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        const e: u8 = if (a[i] > b[i]) a[i] - b[i] else b[i] - a[i];
        try std.testing.expectEqual(e, got[i]);
    }
}

test "subSat saturates at zero" {
    const a: @Vector(8, u8) = .{ 10, 50, 100, 250, 0, 200, 1, 255 };
    const b: @Vector(8, u8) = .{ 20, 50, 80, 5, 200, 200, 1, 0 };
    const got = subSat(8, a, b);
    const want = @Vector(8, u8){ 0, 0, 20, 245, 0, 0, 0, 255 };
    try std.testing.expectEqual(want, got);
}

test "expandPairs duplicates each lane" {
    const v = @Vector(4, u8){ 7, 11, 13, 17 };
    const got = expandPairs(4, v);
    const want = @Vector(8, u8){ 7, 7, 11, 11, 13, 13, 17, 17 };
    try std.testing.expectEqual(want, got);
}
