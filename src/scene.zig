//! Scene-change detection — single function, ported from
//! `reference/vapoursynth-cpp/src/vs_it_process.cpp::CheckSceneChange`.
//!
//! Walks every odd row of two consecutive frames; if more than 1/8 of the
//! sampled pixels differ by more than 50, declares a scene change.

const std = @import("std");
const plane = @import("plane.zig");
const simd = @import("simd.zig");

inline fn absDiffI(a: u8, b: u8) i32 {
    return if (a > b) @as(i32, a - b) else @as(i32, b - a);
}

/// Upstream iterates `x < rowSize = vsapi->getStride(srcC, 0)`, i.e. it walks
/// over the stride, not just the visible width. We preserve that behaviour
/// bit-for-bit by using `curr_stride` as the inner-loop bound — `width` is
/// therefore not a parameter (upstream's `iWidth` is ignored too).
pub fn checkSceneChange(
    height: i32,
    prev_y: [*]const u8,
    prev_stride: usize,
    curr_y: [*]const u8,
    curr_stride: usize,
) bool {
    const stride_u: usize = curr_stride;
    const stride_i: i32 = @intCast(curr_stride);
    var sum: i64 = 0;
    const LANES = 32;
    const threshold_vec: @Vector(LANES, u8) = @splat(50);
    var y: i32 = 1;
    while (y < height) : (y += 2) {
        const pC = plane.syp(curr_y, curr_stride, height, 0, y);
        const pP = plane.syp(prev_y, prev_stride, height, 0, y);
        var x: usize = 0;
        while (x + LANES <= stride_u) : (x += LANES) {
            const c = simd.load(LANES, pC, x);
            const p = simd.load(LANES, pP, x);
            const d = simd.absDiff(LANES, c, p);
            const mask: @Vector(LANES, bool) = d > threshold_vec;
            // Sum the count of true lanes.
            const ones: @Vector(LANES, u8) = @select(u8, mask, @as(@Vector(LANES, u8), @splat(1)), @as(@Vector(LANES, u8), @splat(0)));
            sum += @reduce(.Add, @as(@Vector(LANES, u16), ones));
        }
        while (x < stride_u) : (x += 1) {
            if (absDiffI(pC[x], pP[x]) > 50) sum += 1;
        }
    }
    const threshold: i64 = @divTrunc(@as(i64, height) * @as(i64, stride_i), 8);
    return sum > threshold;
}

// ---------------------------------------------------------------------------
test "checkSceneChange: identical frames -> no scene change" {
    const width: i32 = 32;
    const height: i32 = 16;
    const w: usize = @intCast(width);
    const h: usize = @intCast(height);
    const a = try std.testing.allocator.alloc(u8, w * h);
    defer std.testing.allocator.free(a);
    @memset(a, 128);
    try std.testing.expectEqual(false, checkSceneChange(height, a.ptr, w, a.ptr, w));
}

test "checkSceneChange: completely different frames -> scene change" {
    const width: i32 = 32;
    const height: i32 = 16;
    const w: usize = @intCast(width);
    const h: usize = @intCast(height);
    const a = try std.testing.allocator.alloc(u8, w * h);
    defer std.testing.allocator.free(a);
    const b = try std.testing.allocator.alloc(u8, w * h);
    defer std.testing.allocator.free(b);
    @memset(a, 0);
    @memset(b, 255);
    try std.testing.expectEqual(true, checkSceneChange(height, a.ptr, w, b.ptr, w));
}
