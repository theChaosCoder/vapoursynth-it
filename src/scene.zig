//! Scene-change detection — single function, ported from
//! `reference/vapoursynth-cpp/src/vs_it_process.cpp::CheckSceneChange`.
//!
//! Walks every odd row of two consecutive frames; if more than 1/8 of the
//! sampled pixels differ by more than 50 (8-bit baseline, scaled per
//! bit-depth), declares a scene change.

const std = @import("std");
const plane = @import("plane.zig");
const simd = @import("simd.zig");
const scalar = @import("scalar.zig");

/// Bounds the per-row scan by the **visible width**, not the frame stride.
///
/// Upstream walks `x < rowSize = vsapi->getStride(srcC, 0)` — the byte
/// stride, which in its 8-bit-only code equals `width + row padding`. That
/// is an 8-bit artifact: counting the (undefined) padding ties the result to
/// the allocator's stride, and for >8-bit storage the *sample* stride differs
/// from 8-bit at non-stride-aligned widths (e.g. 720 → 768 vs 736 samples),
/// so identical content would yield *different* scene-change decisions per
/// bit-depth. We deliberately diverge: scan `[0, width)` and threshold on
/// `width`, so the decision is identical across 8/10/12/16-bit (the project's
/// cross-bit-depth invariant) and never reads padding.
///
/// This only changes non-stride-aligned widths with genuinely interlaced
/// content that reaches the scene-change shortcut; no test fixture is
/// affected (flat clips never invoke it, and the interlaced fixtures are
/// 128px so width == stride already).
///
/// Generic over the pixel storage type `T` (u8 or u16) and the actual
/// bit-depth `bits` (8/10/12/16). The diff threshold scales as
/// `50 << (bits - 8)` so the algorithm behaves consistently across depths.
pub inline fn checkSceneChange(
    comptime T: type,
    comptime bits: u8,
    width: i32,
    height: i32,
    prev_y: [*]const T,
    prev_stride: usize,
    curr_y: [*]const T,
    curr_stride: usize,
) bool {
    const w: usize = @intCast(width);
    var sum: i64 = 0;
    const LANES = 32 / @sizeOf(T);
    const threshold: T = comptime @intCast(@as(u32, 50) << @intCast(bits - 8));
    const threshold_vec: @Vector(LANES, T) = @splat(threshold);
    var y: i32 = 1;
    while (y < height) : (y += 2) {
        const pC = plane.syp(curr_y, curr_stride, height, 0, y);
        const pP = plane.syp(prev_y, prev_stride, height, 0, y);
        var x: usize = 0;
        while (x + LANES <= w) : (x += LANES) {
            const c = simd.load(LANES, pC, x);
            const p = simd.load(LANES, pP, x);
            const d = simd.absDiff(LANES, c, p);
            const mask: @Vector(LANES, bool) = d > threshold_vec;
            // Sum the count of true lanes.
            const ones: @Vector(LANES, u8) = @select(u8, mask, @as(@Vector(LANES, u8), @splat(1)), @as(@Vector(LANES, u8), @splat(0)));
            sum += @reduce(.Add, @as(@Vector(LANES, u16), ones));
        }
        while (x < w) : (x += 1) {
            if (scalar.absDiff(pC[x], pP[x]) > threshold) sum += 1;
        }
    }
    const threshold_count: i64 = @divTrunc(@as(i64, height) * @as(i64, width), 8);
    return sum > threshold_count;
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
    try std.testing.expectEqual(false, checkSceneChange(u8, 8, width, height, a.ptr, w, a.ptr, w));
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
    try std.testing.expectEqual(true, checkSceneChange(u8, 8, width, height, a.ptr, w, b.ptr, w));
}

test "checkSceneChange: u16 path, scaled threshold" {
    const width: i32 = 32;
    const height: i32 = 16;
    const w: usize = @intCast(width);
    const h: usize = @intCast(height);
    const a = try std.testing.allocator.alloc(u16, w * h);
    defer std.testing.allocator.free(a);
    const b = try std.testing.allocator.alloc(u16, w * h);
    defer std.testing.allocator.free(b);
    @memset(a, 0);
    @memset(b, 65535);
    try std.testing.expectEqual(true, checkSceneChange(u16, 16, width, height, a.ptr, w, b.ptr, w));

    @memset(a, 512);
    @memset(b, 512);
    try std.testing.expectEqual(false, checkSceneChange(u16, 10, width, height, a.ptr, w, b.ptr, w));
}
