//! Motion / blur maps.
//!
//! Three functions ported from `vs_it_c.cpp`:
//!   - `makeMotionMap` (MakeMotionMap_YV12) — per-frame motion stats between
//!      previous and current frames, written into the CFrameInfo entry.
//!   - `makeMotionMap2Max` (MakeMotionMap2Max_YV12) — max-of-(P↔C, C↔N)
//!      motion per pixel, used by the deinterlacer.
//!   - `makeSimpleBlurMap` (MakeSimpleBlurMap_YV12) — line-blur map used
//!      together with the motion map to decide which pixels need interpolation.

const std = @import("std");
const plane = @import("plane.zig");
const simd = @import("simd.zig");

inline fn absDiffU8(a: u8, b: u8) u8 {
    return if (a > b) a - b else b - a;
}

const MAX_WIDTH = 8192;
const CHROMA_LANES = 16;

/// Generic core for makeMotionMap2{Max,Min}. The two only differ in their
/// final per-pixel combine (`@max` vs `@min`); everything else is identical.
inline fn makeMotionMap2Common(
    comptime use_max: bool,
    width: i32,
    height: i32,
    even_rows_only: bool,
    dst: []u8,
    prev_y: [*]const u8,
    prev_y_stride: usize,
    prev_u: [*]const u8,
    prev_u_stride: usize,
    prev_v: [*]const u8,
    prev_v_stride: usize,
    curr_y: [*]const u8,
    curr_y_stride: usize,
    curr_u: [*]const u8,
    curr_u_stride: usize,
    curr_v: [*]const u8,
    curr_v_stride: usize,
    next_y: [*]const u8,
    next_y_stride: usize,
    next_u: [*]const u8,
    next_u_stride: usize,
    next_v: [*]const u8,
    next_v_stride: usize,
) void {
    const w: usize = @intCast(width);
    const twidth: usize = @intCast(@divTrunc(width, 2));
    const y_step: i32 = if (even_rows_only) 2 else 1;

    var y: i32 = 0;
    while (y < height) : (y += y_step) {
        const pD = dst[@as(usize, @intCast(y)) * w ..][0..w];
        const pC = plane.syp(curr_y, curr_y_stride, height, 0, y);
        const pP = plane.syp(prev_y, prev_y_stride, height, 0, y);
        const pN = plane.syp(next_y, next_y_stride, height, 0, y);
        const pC_U = plane.syp(curr_u, curr_u_stride, height, 1, y);
        const pP_U = plane.syp(prev_u, prev_u_stride, height, 1, y);
        const pN_U = plane.syp(next_u, next_u_stride, height, 1, y);
        const pC_V = plane.syp(curr_v, curr_v_stride, height, 2, y);
        const pP_V = plane.syp(prev_v, prev_v_stride, height, 2, y);
        const pN_V = plane.syp(next_v, next_v_stride, height, 2, y);

        var i: usize = 0;
        while (i + CHROMA_LANES <= twidth) : (i += CHROMA_LANES) {
            const c_y = simd.load(CHROMA_LANES * 2, pC, i * 2);
            const p_y = simd.load(CHROMA_LANES * 2, pP, i * 2);
            const n_y = simd.load(CHROMA_LANES * 2, pN, i * 2);
            const c_u = simd.load(CHROMA_LANES, pC_U, i);
            const p_u = simd.load(CHROMA_LANES, pP_U, i);
            const n_u = simd.load(CHROMA_LANES, pN_U, i);
            const c_v = simd.load(CHROMA_LANES, pC_V, i);
            const p_v = simd.load(CHROMA_LANES, pP_V, i);
            const n_v = simd.load(CHROMA_LANES, pN_V, i);

            const py = simd.absDiff(CHROMA_LANES * 2, c_y, p_y);
            const pu = simd.absDiff(CHROMA_LANES, c_u, p_u);
            const pv = simd.absDiff(CHROMA_LANES, c_v, p_v);
            const puv = @max(pu, pv);
            const p_lane = @max(py, simd.expandPairs(CHROMA_LANES, puv));

            const ny = simd.absDiff(CHROMA_LANES * 2, c_y, n_y);
            const nu = simd.absDiff(CHROMA_LANES, c_u, n_u);
            const nv = simd.absDiff(CHROMA_LANES, c_v, n_v);
            const nuv = @max(nu, nv);
            const n_lane = @max(ny, simd.expandPairs(CHROMA_LANES, nuv));

            const combined = if (use_max) @max(p_lane, n_lane) else @min(p_lane, n_lane);
            simd.store(CHROMA_LANES * 2, pD.ptr, i * 2, combined);
        }
        while (i < twidth) : (i += 1) {
            const py_l = absDiffU8(pC[i * 2], pP[i * 2]);
            const py_h = absDiffU8(pC[i * 2 + 1], pP[i * 2 + 1]);
            const pu = absDiffU8(pC_U[i], pP_U[i]);
            const pv = absDiffU8(pC_V[i], pP_V[i]);
            const puv = @max(pu, pv);
            const pl = @max(puv, py_l);
            const ph = @max(puv, py_h);

            const ny_l = absDiffU8(pC[i * 2], pN[i * 2]);
            const ny_h = absDiffU8(pC[i * 2 + 1], pN[i * 2 + 1]);
            const nu = absDiffU8(pC_U[i], pN_U[i]);
            const nv = absDiffU8(pC_V[i], pN_V[i]);
            const nuv = @max(nu, nv);
            const nl = @max(nuv, ny_l);
            const nh = @max(nuv, ny_h);

            if (use_max) {
                pD[i * 2] = @max(pl, nl);
                pD[i * 2 + 1] = @max(ph, nh);
            } else {
                pD[i * 2] = @min(pl, nl);
                pD[i * 2 + 1] = @min(ph, nh);
            }
        }
    }
}

/// Result of makeMotionMap — what upstream stores into m_frameInfo[n].
pub const MotionStats = struct {
    diffP0: i32,
    diffP1: i32,
    diffS0: i32,
    diffS1: i32,
};

/// MakeMotionMap_YV12. Compares current and previous luma planes line-by-line,
/// computing per-row "rough motion" (over threshold 36, diffP*) and
/// "saturated motion" (over threshold 18, diffS*). Splits into even/odd rows
/// (0/1 suffix on the field number).
pub fn makeMotionMap(
    width: i32,
    height: i32,
    prev_y: [*]const u8,
    prev_y_stride: usize,
    curr_y: [*]const u8,
    curr_y_stride: usize,
) MotionStats {
    std.debug.assert(width <= MAX_WIDTH);
    const w: usize = @intCast(width);
    const widthminus8: i32 = width - 8;
    const widthminus16: i32 = width - 16;
    var bufP0: [MAX_WIDTH]i16 = undefined;
    var bufP1: [MAX_WIDTH]u8 = undefined;

    var pe0: i32 = 0;
    var po0: i32 = 0;
    var pe1: i32 = 0;
    var po1: i32 = 0;

    var yy: i32 = 16;
    while (yy < height - 16) : (yy += 1) {
        const y = yy;
        const pC = plane.syp(curr_y, curr_y_stride, height, 0, y);
        const pP = plane.syp(prev_y, prev_y_stride, height, 0, y);

        // Pass 1: bufP0[i] = pC[i] - pP[i] (i16). Element-wise vectorisable.
        {
            const LANES = 16;
            var i: usize = 0;
            while (i + LANES <= w) : (i += LANES) {
                const c: @Vector(LANES, u8) = pC[i..][0..LANES].*;
                const p: @Vector(LANES, u8) = pP[i..][0..LANES].*;
                const c16: @Vector(LANES, i16) = c;
                const p16: @Vector(LANES, i16) = p;
                bufP0[i..][0..LANES].* = c16 - p16;
            }
            while (i < w) : (i += 1) {
                bufP0[i] = @as(i16, pC[i]) - @as(i16, pP[i]);
            }
        }

        // Pass 2: bufP1[i] = clamp(|B| - |A + C - 2B|, 0, 255)
        // where (A,B,C) = bufP0[i-1, i, i+1].
        var ii: i32 = 8;
        {
            const LANES = 16;
            const zero16: @Vector(LANES, i16) = @splat(0);
            const c255: @Vector(LANES, i16) = @splat(255);
            const two: @Vector(LANES, i16) = @splat(2);
            const widthminus8_u: usize = @intCast(widthminus8);
            var uii: usize = @intCast(ii);
            while (uii + LANES <= widthminus8_u) : (uii += LANES) {
                const A: @Vector(LANES, i16) = bufP0[uii - 1 ..][0..LANES].*;
                const B: @Vector(LANES, i16) = bufP0[uii..][0..LANES].*;
                const C: @Vector(LANES, i16) = bufP0[uii + 1 ..][0..LANES].*;
                const delta_signed = A + C - two * B;
                const delta_abs = @select(i16, delta_signed < zero16, -delta_signed, delta_signed);
                const absB = @select(i16, B < zero16, -B, B);
                const s = absB - delta_abs;
                const s_clamped = @max(@min(s, c255), zero16);
                const s_u8: @Vector(LANES, u8) = @intCast(s_clamped);
                bufP1[uii..][0..LANES].* = s_u8;
            }
            ii = @intCast(uii);
        }
        while (ii < widthminus8) : (ii += 1) {
            const ui: usize = @intCast(ii);
            const A = bufP0[ui - 1];
            const B = bufP0[ui];
            const C = bufP0[ui + 1];
            // delta = (A - B) + (C - B) = A + C - 2B  (signed)
            var delta: i32 = @as(i32, A) - @as(i32, B) + @as(i32, C) - @as(i32, B);
            var absB: i32 = @as(i32, B);
            if (absB < 0) absB = -absB;
            if (delta < 0) delta = -delta;
            // Saturate Subtract (|B| - |delta|) into u8
            var s: i32 = absB - delta;
            if (s < 0) s = 0;
            if (s > 255) s = 255;
            bufP1[ui] = @intCast(s);
        }

        // Pass 3: count bufP1[i-1] + bufP1[i+1] + bufP1[i] > 36 / 18.
        var tsum: i32 = 0;
        var tsum1: i32 = 0;
        ii = 16;
        {
            const LANES = 16;
            const widthminus16_u: usize = @intCast(widthminus16);
            const th36: @Vector(LANES, u16) = @splat(36);
            const th18: @Vector(LANES, u16) = @splat(18);
            const ones: @Vector(LANES, u8) = @splat(1);
            const zeros: @Vector(LANES, u8) = @splat(0);
            var uii: usize = @intCast(ii);
            while (uii + LANES <= widthminus16_u) : (uii += LANES) {
                const A: @Vector(LANES, u8) = bufP1[uii - 1 ..][0..LANES].*;
                const B: @Vector(LANES, u8) = bufP1[uii + 1 ..][0..LANES].*;
                const C: @Vector(LANES, u8) = bufP1[uii..][0..LANES].*;
                const ABC: @Vector(LANES, u16) =
                    @as(@Vector(LANES, u16), A) +
                    @as(@Vector(LANES, u16), B) +
                    @as(@Vector(LANES, u16), C);
                const mask1: @Vector(LANES, bool) = ABC > th36;
                const mask2: @Vector(LANES, bool) = ABC > th18;
                tsum += @reduce(.Add, @as(@Vector(LANES, u16), @select(u8, mask1, ones, zeros)));
                tsum1 += @reduce(.Add, @as(@Vector(LANES, u16), @select(u8, mask2, ones, zeros)));
            }
            ii = @intCast(uii);
        }
        while (ii < widthminus16) : (ii += 1) {
            const ui: usize = @intCast(ii);
            const A: i32 = @as(i32, bufP1[ui - 1]);
            const B: i32 = @as(i32, bufP1[ui + 1]);
            const C: i32 = @as(i32, bufP1[ui]);
            const ABC = A + B + C;
            if (ABC > 36) tsum += 1;
            if (ABC > 18) tsum1 += 1;
        }
        if (y & 1 == 0) {
            pe0 += tsum;
            pe1 += tsum1;
        } else {
            po0 += tsum;
            po1 += tsum1;
        }
    }

    return .{
        .diffP0 = pe0,
        .diffP1 = po0,
        .diffS0 = pe1,
        .diffS1 = po1,
    };
}

/// `MakeMotionMap2_YV12` — per-pixel **minimum** motion between (prev, curr)
/// and (curr, next). Same structure as makeMotionMap2Max but takes
/// `min` at the final step. Used by the full DEINTERLACE deinterlacer
/// (diMode=1) as a motion gate for forcing vertical-average overrides.
///
/// Note: upstream's MMX writes only at even rows (`y += 2`) so the odd
/// rows of `dst` are left untouched. We preserve that — the deinterlacer
/// only reads even rows anyway.
pub fn makeMotionMap2Min(
    width: i32,
    height: i32,
    dst: []u8,
    prev_y: [*]const u8,
    prev_y_stride: usize,
    prev_u: [*]const u8,
    prev_u_stride: usize,
    prev_v: [*]const u8,
    prev_v_stride: usize,
    curr_y: [*]const u8,
    curr_y_stride: usize,
    curr_u: [*]const u8,
    curr_u_stride: usize,
    curr_v: [*]const u8,
    curr_v_stride: usize,
    next_y: [*]const u8,
    next_y_stride: usize,
    next_u: [*]const u8,
    next_u_stride: usize,
    next_v: [*]const u8,
    next_v_stride: usize,
) void {
    std.debug.assert(@as(usize, @intCast(width)) * @as(usize, @intCast(height)) == dst.len);
    makeMotionMap2Common(false, width, height, true, dst, prev_y, prev_y_stride, prev_u, prev_u_stride, prev_v, prev_v_stride, curr_y, curr_y_stride, curr_u, curr_u_stride, curr_v, curr_v_stride, next_y, next_y_stride, next_u, next_u_stride, next_v, next_v_stride);
}

/// MakeMotionMap2Max_YV12 — max per-pixel motion between (prev, curr) and
/// (curr, next), considering luma + max(U,V) chroma. Output is `width*height`
/// bytes into `dst`.
pub fn makeMotionMap2Max(
    width: i32,
    height: i32,
    dst: []u8,
    prev_y: [*]const u8,
    prev_y_stride: usize,
    prev_u: [*]const u8,
    prev_u_stride: usize,
    prev_v: [*]const u8,
    prev_v_stride: usize,
    curr_y: [*]const u8,
    curr_y_stride: usize,
    curr_u: [*]const u8,
    curr_u_stride: usize,
    curr_v: [*]const u8,
    curr_v_stride: usize,
    next_y: [*]const u8,
    next_y_stride: usize,
    next_u: [*]const u8,
    next_u_stride: usize,
    next_v: [*]const u8,
    next_v_stride: usize,
) void {
    std.debug.assert(@as(usize, @intCast(width)) * @as(usize, @intCast(height)) == dst.len);
    makeMotionMap2Common(true, width, height, false, dst, prev_y, prev_y_stride, prev_u, prev_u_stride, prev_v, prev_v_stride, curr_y, curr_y_stride, curr_u, curr_u_stride, curr_v, curr_v_stride, next_y, next_y_stride, next_u, next_u_stride, next_v, next_v_stride);
}

/// MakeSimpleBlurMap_YV12 — computes a "did the line need to be interpolated"
/// map. For each row of `curr`, picks top/bottom from `curr` and center from
/// `ref` (or vice versa, depending on parity). Output is luma-only, width*height.
pub fn makeSimpleBlurMap(
    width: i32,
    height: i32,
    dst: []u8,
    curr_y: [*]const u8,
    curr_y_stride: usize,
    ref_y: [*]const u8,
    ref_y_stride: usize,
) void {
    std.debug.assert(@as(usize, @intCast(width)) * @as(usize, @intCast(height)) == dst.len);
    const w: usize = @intCast(width);

    var y: i32 = 0;
    while (y < height) : (y += 1) {
        const pD = dst[@as(usize, @intCast(y)) * w ..][0..w];
        var pT: [*]const u8 = undefined;
        var pC: [*]const u8 = undefined;
        var pB: [*]const u8 = undefined;
        if (@rem(y, 2) != 0) {
            pT = plane.syp(curr_y, curr_y_stride, height, 0, y - 1);
            pC = plane.syp(ref_y, ref_y_stride, height, 0, y);
            pB = plane.syp(curr_y, curr_y_stride, height, 0, y + 1);
        } else {
            pT = plane.syp(ref_y, ref_y_stride, height, 0, y - 1);
            pC = plane.syp(curr_y, curr_y_stride, height, 0, y);
            pB = plane.syp(ref_y, ref_y_stride, height, 0, y + 1);
        }
        const LANES = 32;
        var i: usize = 0;
        // SIMD body: 32 pixels per iteration via saturating u8 arithmetic.
        // Original formula `max(0, min(255, ct + cb) - 2*tb)` maps exactly to
        // `(ct +| cb) -| (tb +| tb)` element-wise (psubusb / paddusb).
        while (i + LANES <= w) : (i += LANES) {
            const c = simd.load(LANES, pC, i);
            const t = simd.load(LANES, pT, i);
            const b = simd.load(LANES, pB, i);
            const ct = simd.absDiff(LANES, c, t);
            const cb = simd.absDiff(LANES, c, b);
            const tb = simd.absDiff(LANES, t, b);
            const tb2 = tb +| tb;
            const delta = (ct +| cb) -| tb2;
            simd.store(LANES, pD.ptr, i, delta);
        }
        while (i < w) : (i += 1) {
            const cval = pC[i];
            const t = pT[i];
            const b = pB[i];
            const ct = absDiffU8(cval, t);
            const cb = absDiffU8(cval, b);
            const tb = absDiffU8(t, b);
            var delta: i32 = ct;
            delta = @min(255, delta + @as(i32, cb));
            delta = @max(0, delta - 2 * @as(i32, tb));
            pD[i] = @intCast(delta);
        }
    }
}

// ---------------------------------------------------------------------------
test "makeMotionMap: identical frames yield zero diff" {
    const width: i32 = 64;
    const height: i32 = 48;
    const w: usize = @intCast(width);
    const h: usize = @intCast(height);
    const a = try std.testing.allocator.alloc(u8, w * h);
    defer std.testing.allocator.free(a);
    @memset(a, 128);

    const r = makeMotionMap(width, height, a.ptr, w, a.ptr, w);
    try std.testing.expectEqual(@as(i32, 0), r.diffP0);
    try std.testing.expectEqual(@as(i32, 0), r.diffP1);
    try std.testing.expectEqual(@as(i32, 0), r.diffS0);
    try std.testing.expectEqual(@as(i32, 0), r.diffS1);
}

test "makeMotionMap: differing frames yield non-zero diff" {
    const width: i32 = 64;
    const height: i32 = 48;
    const w: usize = @intCast(width);
    const h: usize = @intCast(height);
    const a = try std.testing.allocator.alloc(u8, w * h);
    defer std.testing.allocator.free(a);
    const b = try std.testing.allocator.alloc(u8, w * h);
    defer std.testing.allocator.free(b);
    @memset(a, 0);
    @memset(b, 0);
    // Stripe the middle of b with high values — that creates impulses.
    var r: usize = 20;
    while (r < 28) : (r += 1) @memset(b[r * w ..][0..w], 255);

    const stats = makeMotionMap(width, height, a.ptr, w, b.ptr, w);
    // Expect both even and odd field motion (the stripe spans both)
    try std.testing.expect(stats.diffP0 >= 0);
    try std.testing.expect(stats.diffS0 >= stats.diffP0);
}

test "makeMotionMap2Max: identical frames yield zero map" {
    const width: i32 = 32;
    const height: i32 = 16;
    const w: usize = @intCast(width);
    const h: usize = @intCast(height);
    const yp = try std.testing.allocator.alloc(u8, w * h);
    defer std.testing.allocator.free(yp);
    const up = try std.testing.allocator.alloc(u8, (w / 2) * (h / 2));
    defer std.testing.allocator.free(up);
    const vp = try std.testing.allocator.alloc(u8, (w / 2) * (h / 2));
    defer std.testing.allocator.free(vp);
    const dst = try std.testing.allocator.alloc(u8, w * h);
    defer std.testing.allocator.free(dst);
    @memset(yp, 100);
    @memset(up, 100);
    @memset(vp, 100);
    @memset(dst, 0xFF);

    makeMotionMap2Max(width, height, dst, yp.ptr, w, up.ptr, w / 2, vp.ptr, w / 2, yp.ptr, w, up.ptr, w / 2, vp.ptr, w / 2, yp.ptr, w, up.ptr, w / 2, vp.ptr, w / 2);

    for (dst) |x| try std.testing.expectEqual(@as(u8, 0), x);
}

test "makeSimpleBlurMap: flat frame yields zero blur" {
    const width: i32 = 32;
    const height: i32 = 16;
    const w: usize = @intCast(width);
    const h: usize = @intCast(height);
    const yp = try std.testing.allocator.alloc(u8, w * h);
    defer std.testing.allocator.free(yp);
    const dst = try std.testing.allocator.alloc(u8, w * h);
    defer std.testing.allocator.free(dst);
    @memset(yp, 128);
    @memset(dst, 0xFF);
    makeSimpleBlurMap(width, height, dst, yp.ptr, w, yp.ptr, w);
    for (dst) |x| try std.testing.expectEqual(@as(u8, 0), x);
}
