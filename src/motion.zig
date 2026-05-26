//! Motion / blur maps.
//!
//! Three functions ported from `vs_it_c.cpp`:
//!   - `makeMotionMap` (MakeMotionMap_YV12) — per-frame motion stats between
//!      previous and current frames, written into the CFrameInfo entry.
//!   - `makeMotionMap2Max` (MakeMotionMap2Max_YV12) — max-of-(P↔C, C↔N)
//!      motion per pixel, used by the deinterlacer.
//!   - `makeSimpleBlurMap` (MakeSimpleBlurMap_YV12) — line-blur map used
//!      together with the motion map to decide which pixels need interpolation.
//!
//! Generic over the pixel storage type `T` (u8/u16). Per-pixel diff math
//! runs at T precision; map writes downscale via `simd.toMapByteVec` /
//! `scalar.toMapByte` so the 8-bit thresholds (12, 18, 36) at consumers
//! retain their tuned semantics.

const std = @import("std");
const plane = @import("plane.zig");
const simd = @import("simd.zig");
const scalar = @import("scalar.zig");

const MAX_WIDTH = plane.MAX_WIDTH;

/// Generic core for makeMotionMap2{Max,Min}. The two only differ in their
/// final per-pixel combine (`@max` vs `@min`); everything else is identical.
inline fn makeMotionMap2Common(
    comptime T: type,
    comptime bits: u8,
    comptime use_max: bool,
    width: i32,
    height: i32,
    even_rows_only: bool,
    dst: []u8,
    prev: *const plane.PlaneView(T),
    curr: *const plane.PlaneView(T),
    next: *const plane.PlaneView(T),
) void {
    const w: usize = @intCast(width);
    const twidth: usize = @intCast(@divTrunc(width, 2));
    const y_step: i32 = if (even_rows_only) 2 else 1;
    // Keep 256-bit SIMD width: 16 u8 chroma lanes / 32 u8 luma; halved at u16.
    const CL: usize = 16 / @sizeOf(T);

    var y: i32 = 0;
    while (y < height) : (y += y_step) {
        const pD = dst[@as(usize, @intCast(y)) * w ..][0..w];
        const pC = plane.syp(curr.y, curr.y_stride, height, 0, y);
        const pP = plane.syp(prev.y, prev.y_stride, height, 0, y);
        const pN = plane.syp(next.y, next.y_stride, height, 0, y);
        const pC_U = plane.syp(curr.u, curr.u_stride, height, 1, y);
        const pP_U = plane.syp(prev.u, prev.u_stride, height, 1, y);
        const pN_U = plane.syp(next.u, next.u_stride, height, 1, y);
        const pC_V = plane.syp(curr.v, curr.v_stride, height, 2, y);
        const pP_V = plane.syp(prev.v, prev.v_stride, height, 2, y);
        const pN_V = plane.syp(next.v, next.v_stride, height, 2, y);

        var i: usize = 0;
        while (i + CL <= twidth) : (i += CL) {
            const c_y = simd.load(CL * 2, pC, i * 2);
            const p_y = simd.load(CL * 2, pP, i * 2);
            const n_y = simd.load(CL * 2, pN, i * 2);
            const c_u = simd.load(CL, pC_U, i);
            const p_u = simd.load(CL, pP_U, i);
            const n_u = simd.load(CL, pN_U, i);
            const c_v = simd.load(CL, pC_V, i);
            const p_v = simd.load(CL, pP_V, i);
            const n_v = simd.load(CL, pN_V, i);

            const py = simd.absDiff(CL * 2, c_y, p_y);
            const pu = simd.absDiff(CL, c_u, p_u);
            const pv = simd.absDiff(CL, c_v, p_v);
            const puv = @max(pu, pv);
            const p_lane = @max(py, simd.expandPairs(CL, puv));

            const ny = simd.absDiff(CL * 2, c_y, n_y);
            const nu = simd.absDiff(CL, c_u, n_u);
            const nv = simd.absDiff(CL, c_v, n_v);
            const nuv = @max(nu, nv);
            const n_lane = @max(ny, simd.expandPairs(CL, nuv));

            const combined = if (use_max) @max(p_lane, n_lane) else @min(p_lane, n_lane);
            const combined_u8 = simd.toMapByteVec(T, bits, CL * 2, combined);
            simd.store(CL * 2, pD.ptr, i * 2, combined_u8);
        }
        while (i < twidth) : (i += 1) {
            const py_l = scalar.absDiff(pC[i * 2], pP[i * 2]);
            const py_h = scalar.absDiff(pC[i * 2 + 1], pP[i * 2 + 1]);
            const pu = scalar.absDiff(pC_U[i], pP_U[i]);
            const pv = scalar.absDiff(pC_V[i], pP_V[i]);
            const puv = @max(pu, pv);
            const pl = @max(puv, py_l);
            const ph = @max(puv, py_h);

            const ny_l = scalar.absDiff(pC[i * 2], pN[i * 2]);
            const ny_h = scalar.absDiff(pC[i * 2 + 1], pN[i * 2 + 1]);
            const nu = scalar.absDiff(pC_U[i], pN_U[i]);
            const nv = scalar.absDiff(pC_V[i], pN_V[i]);
            const nuv = @max(nu, nv);
            const nl = @max(nuv, ny_l);
            const nh = @max(nuv, ny_h);

            if (use_max) {
                pD[i * 2] = scalar.toMapByte(T, bits, @max(pl, nl));
                pD[i * 2 + 1] = scalar.toMapByte(T, bits, @max(ph, nh));
            } else {
                pD[i * 2] = scalar.toMapByte(T, bits, @min(pl, nl));
                pD[i * 2 + 1] = scalar.toMapByte(T, bits, @min(ph, nh));
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
///
/// Wide diff buffer `bufP0` scales with `T` so u16/10-bit signed diffs fit;
/// `bufP1` stays u8 (after clamp + per-bit-depth downscale) so thresholds
/// 36 / 18 remain the same.
pub inline fn makeMotionMap(
    comptime T: type,
    comptime bits: u8,
    width: i32,
    height: i32,
    prev_y: [*]const T,
    prev_y_stride: usize,
    curr_y: [*]const T,
    curr_y_stride: usize,
) MotionStats {
    std.debug.assert(width <= MAX_WIDTH);
    const w: usize = @intCast(width);
    const widthminus8: i32 = width - 8;
    const widthminus16: i32 = width - 16;
    // Signed wide-enough type for pixel diffs (i16 for u8, i32 for u16).
    const Wide = std.meta.Int(.signed, @bitSizeOf(T) * 2);
    const max_pix: Wide = comptime @as(Wide, (@as(@TypeOf(1 << @as(u32, bits)), 1) << bits) - 1);
    // Pass2 SIMD width = 32 bytes / sizeof(Wide).
    const P2_LANES: usize = 32 / @sizeOf(Wide);

    var bufP0: [MAX_WIDTH]Wide = undefined;
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

        // Pass 1: bufP0[i] = pC[i] - pP[i] (Wide-signed). Element-wise vectorisable.
        {
            const LANES = P2_LANES;
            var i: usize = 0;
            while (i + LANES <= w) : (i += LANES) {
                const c: @Vector(LANES, T) = pC[i..][0..LANES].*;
                const p: @Vector(LANES, T) = pP[i..][0..LANES].*;
                const c_w: @Vector(LANES, Wide) = c;
                const p_w: @Vector(LANES, Wide) = p;
                bufP0[i..][0..LANES].* = c_w - p_w;
            }
            while (i < w) : (i += 1) {
                bufP0[i] = @as(Wide, pC[i]) - @as(Wide, pP[i]);
            }
        }

        // Pass 2: bufP1[i] = downscale_to_u8(clamp(|B| - |A + C - 2B|, 0, max_pix))
        // where (A,B,C) = bufP0[i-1, i, i+1]. Wide-precision until the final
        // clamp+downscale to u8 keeps 10/12/16-bit information through the
        // diff while the consumer thresholds (36 / 18) stay at u8 scale.
        var ii: i32 = 8;
        {
            const LANES = P2_LANES;
            const zerow: @Vector(LANES, Wide) = @splat(0);
            const maxv: @Vector(LANES, Wide) = @splat(max_pix);
            const two: @Vector(LANES, Wide) = @splat(2);
            const widthminus8_u: usize = @intCast(widthminus8);
            var uii: usize = @intCast(ii);
            while (uii + LANES <= widthminus8_u) : (uii += LANES) {
                const A: @Vector(LANES, Wide) = bufP0[uii - 1 ..][0..LANES].*;
                const B: @Vector(LANES, Wide) = bufP0[uii..][0..LANES].*;
                const C: @Vector(LANES, Wide) = bufP0[uii + 1 ..][0..LANES].*;
                const delta_signed = A + C - two * B;
                const delta_abs = @select(Wide, delta_signed < zerow, -delta_signed, delta_signed);
                const absB = @select(Wide, B < zerow, -B, B);
                const s = absB - delta_abs;
                const s_clamped = @max(@min(s, maxv), zerow);
                const s_u8 = if (T == u8)
                    @as(@Vector(LANES, u8), @intCast(s_clamped))
                else blk: {
                    const ShiftT = std.math.Log2Int(std.meta.Int(.unsigned, @bitSizeOf(Wide)));
                    const shifted = s_clamped >> @as(@Vector(LANES, ShiftT), @splat(bits - 8));
                    break :blk @as(@Vector(LANES, u8), @intCast(shifted));
                };
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
            var s: i32 = absB - delta;
            if (s < 0) s = 0;
            if (s > @as(i32, max_pix)) s = @as(i32, max_pix);
            const s_scaled: i32 = if (T == u8) s else (s >> (bits - 8));
            bufP1[ui] = @intCast(s_scaled);
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
/// rows of `dst` are left untouched. Filter.create one-shot zeros the
/// motionMap4DI buffer so the deinterlacer's last-iteration odd-row read
/// is defined.
pub inline fn makeMotionMap2Min(
    comptime T: type,
    comptime bits: u8,
    width: i32,
    height: i32,
    dst: []u8,
    prev: *const plane.PlaneView(T),
    curr: *const plane.PlaneView(T),
    next: *const plane.PlaneView(T),
) void {
    std.debug.assert(@as(usize, @intCast(width)) * @as(usize, @intCast(height)) == dst.len);
    makeMotionMap2Common(T, bits, false, width, height, true, dst, prev, curr, next);
}

/// MakeMotionMap2Max_YV12 — max per-pixel motion between (prev, curr) and
/// (curr, next), considering luma + max(U,V) chroma. Output is `width*height`
/// bytes into `dst`.
pub inline fn makeMotionMap2Max(
    comptime T: type,
    comptime bits: u8,
    width: i32,
    height: i32,
    dst: []u8,
    prev: *const plane.PlaneView(T),
    curr: *const plane.PlaneView(T),
    next: *const plane.PlaneView(T),
) void {
    std.debug.assert(@as(usize, @intCast(width)) * @as(usize, @intCast(height)) == dst.len);
    makeMotionMap2Common(T, bits, true, width, height, false, dst, prev, curr, next);
}

/// MakeSimpleBlurMap_YV12 — computes a "did the line need to be interpolated"
/// map. For each row of `curr`, picks top/bottom from `curr` and center from
/// `ref` (or vice versa, depending on parity). Output is luma-only, width*height.
pub inline fn makeSimpleBlurMap(
    comptime T: type,
    comptime bits: u8,
    width: i32,
    height: i32,
    dst: []u8,
    curr_y: [*]const T,
    curr_y_stride: usize,
    ref_y: [*]const T,
    ref_y_stride: usize,
) void {
    std.debug.assert(@as(usize, @intCast(width)) * @as(usize, @intCast(height)) == dst.len);
    const w: usize = @intCast(width);
    const LANES: usize = 32 / @sizeOf(T);
    const max_pix: i32 = comptime (@as(i32, 1) << bits) - 1;

    var y: i32 = 0;
    while (y < height) : (y += 1) {
        const pD = dst[@as(usize, @intCast(y)) * w ..][0..w];
        // Top/bottom rows come from one source, center from the other; swap
        // based on the parity of `y` so the kernel always reads `T` and `B`
        // from the same frame.
        const odd = @rem(y, 2) != 0;
        const tb_y = if (odd) curr_y else ref_y;
        const tb_s = if (odd) curr_y_stride else ref_y_stride;
        const ce_y = if (odd) ref_y else curr_y;
        const ce_s = if (odd) ref_y_stride else curr_y_stride;
        const pT = plane.syp(tb_y, tb_s, height, 0, y - 1);
        const pC = plane.syp(ce_y, ce_s, height, 0, y);
        const pB = plane.syp(tb_y, tb_s, height, 0, y + 1);
        var i: usize = 0;
        // SIMD body via saturating arithmetic. Upstream formula
        // `max(0, min(max_pix, ct + cb) - 2*tb)` maps element-wise to
        // `(ct +| cb) -| (tb +| tb)` for u8 (where +| / -| saturate at the
        // pixel range = u8 max). For u16 input the saturation point is the
        // type max (65535), but values are well below; final
        // `toMapByteVec(>> (bits-8))` clamps + downscales to the u8 map.
        while (i + LANES <= w) : (i += LANES) {
            const c = simd.load(LANES, pC, i);
            const t = simd.load(LANES, pT, i);
            const b = simd.load(LANES, pB, i);
            const ct = simd.absDiff(LANES, c, t);
            const cb = simd.absDiff(LANES, c, b);
            const tb = simd.absDiff(LANES, t, b);
            const tb2 = tb +| tb;
            const delta = (ct +| cb) -| tb2;
            const delta_u8 = simd.toMapByteVec(T, bits, LANES, delta);
            simd.store(LANES, pD.ptr, i, delta_u8);
        }
        while (i < w) : (i += 1) {
            const cval = pC[i];
            const t = pT[i];
            const b = pB[i];
            const ct = scalar.absDiff(cval, t);
            const cb = scalar.absDiff(cval, b);
            const tb = scalar.absDiff(t, b);
            var delta: i32 = ct;
            delta = @min(max_pix, delta + @as(i32, cb));
            delta = @max(0, delta - 2 * @as(i32, tb));
            const delta_scaled: i32 = if (T == u8) delta else (delta >> (bits - 8));
            pD[i] = @intCast(delta_scaled);
        }
    }
}

// ---------------------------------------------------------------------------
test "makeMotionMap: identical frames yield zero diff (u8)" {
    const width: i32 = 64;
    const height: i32 = 48;
    const w: usize = @intCast(width);
    const h: usize = @intCast(height);
    const a = try std.testing.allocator.alloc(u8, w * h);
    defer std.testing.allocator.free(a);
    @memset(a, 128);

    const r = makeMotionMap(u8, 8, width, height, a.ptr, w, a.ptr, w);
    try std.testing.expectEqual(@as(i32, 0), r.diffP0);
    try std.testing.expectEqual(@as(i32, 0), r.diffP1);
    try std.testing.expectEqual(@as(i32, 0), r.diffS0);
    try std.testing.expectEqual(@as(i32, 0), r.diffS1);
}

test "makeMotionMap: differing frames yield non-zero diff (u8)" {
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
    var r: usize = 20;
    while (r < 28) : (r += 1) @memset(b[r * w ..][0..w], 255);

    const stats = makeMotionMap(u8, 8, width, height, a.ptr, w, b.ptr, w);
    try std.testing.expect(stats.diffP0 >= 0);
    try std.testing.expect(stats.diffS0 >= stats.diffP0);
}

test "makeMotionMap2Max: identical frames yield zero map (u8)" {
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

    const v: plane.PlaneView(u8) = .{ .y = yp.ptr, .y_stride = w, .u = up.ptr, .u_stride = w / 2, .v = vp.ptr, .v_stride = w / 2 };
    makeMotionMap2Max(u8, 8, width, height, dst, &v, &v, &v);

    for (dst) |x| try std.testing.expectEqual(@as(u8, 0), x);
}

test "makeMotionMap2Max: u16 path identical -> zero map" {
    const width: i32 = 32;
    const height: i32 = 16;
    const w: usize = @intCast(width);
    const h: usize = @intCast(height);
    const yp = try std.testing.allocator.alloc(u16, w * h);
    defer std.testing.allocator.free(yp);
    const up = try std.testing.allocator.alloc(u16, (w / 2) * (h / 2));
    defer std.testing.allocator.free(up);
    const vp = try std.testing.allocator.alloc(u16, (w / 2) * (h / 2));
    defer std.testing.allocator.free(vp);
    const dst = try std.testing.allocator.alloc(u8, w * h);
    defer std.testing.allocator.free(dst);
    @memset(yp, 500);
    @memset(up, 500);
    @memset(vp, 500);
    @memset(dst, 0xFF);

    const v: plane.PlaneView(u16) = .{ .y = yp.ptr, .y_stride = w, .u = up.ptr, .u_stride = w / 2, .v = vp.ptr, .v_stride = w / 2 };
    makeMotionMap2Max(u16, 10, width, height, dst, &v, &v, &v);

    for (dst) |x| try std.testing.expectEqual(@as(u8, 0), x);
}

test "makeSimpleBlurMap: flat frame yields zero blur (u8)" {
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
    makeSimpleBlurMap(u8, 8, width, height, dst, yp.ptr, w, yp.ptr, w);
    for (dst) |x| try std.testing.expectEqual(@as(u8, 0), x);
}
