//! `EvalIV_YV12` — count pixels that look like they belong to two different
//! fields (interlace evidence) within the central region of a frame.
//!
//! Ported from `reference/vapoursynth-cpp/src/vs_it_c.cpp::EvalIV_YV12`.
//!
//! The caller must have already filled the edge map for `ref` via
//! `makeDeMap(width, height, offset=1, ...)`.

const std = @import("std");
const plane = @import("plane.zig");
const edge_mod = @import("edge.zig");
const simd = @import("simd.zig");

inline fn absDiffU8(a: u8, b: u8) u8 {
    return if (a > b) a - b else b - a;
}

inline fn avgRound(b: u8, c: u8) u8 {
    return @intCast((@as(u16, b) + @as(u16, c) + 1) >> 1);
}

/// min(|a-b|, |a-c|, |a - (b+c+1)/2|) — the inner "evaluate-interlace"
/// kernel from upstream's `eval_iv_asm`.
inline fn evalIvAsm(eax: [*]const u8, ebx: [*]const u8, ecx: [*]const u8, i: usize) u8 {
    const a = eax[i];
    const b = ebx[i];
    const c = ecx[i];
    const ab = absDiffU8(a, b);
    const ac = absDiffU8(a, c);
    const a_bc = absDiffU8(a, avgRound(b, c));
    return @min(@min(ab, ac), a_bc);
}

/// Saturated u8 subtract: `a > b ? a - b : 0`.
inline fn subSat(a: u8, b: u8) u8 {
    return if (a > b) a - b else 0;
}

/// SIMD eval-iv kernel for N lanes: min(|a-b|, |a-c|, |a - pavgb(b,c)|).
inline fn evalIvVec(comptime N: usize, a: @Vector(N, u8), b: @Vector(N, u8), c: @Vector(N, u8)) @Vector(N, u8) {
    const ab = simd.absDiff(N, a, b);
    const ac = simd.absDiff(N, a, c);
    const a_bc = simd.absDiff(N, a, simd.pavgb(N, b, c));
    return @min(@min(ab, ac), a_bc);
}

/// Result of EvalIV: how many pixels look interlaced (counter) and how
/// many "mildly interlaced" pixels (counterp, lower threshold).
pub const EvalResult = struct {
    counter: i64,
    counterp: i64,
};

/// EvalIV_YV12 — the caller passes:
///   * src_* : the "current" frame's planes (provides surrounding rows pT/pB)
///   * ref_* : the reference frame's planes (provides the center row pC)
///   * edge_map : `width * height` byte buffer; the caller is expected to
///       have populated the EVEN rows via `makeDeMap(..., offset=0, srcC)`
///       *before* the chain of EvalIV calls. This function then overwrites
///       the ODD rows with `makeDeMap(..., offset=1, ref)` internally —
///       matching upstream's EvalIV_YV12 which itself calls
///       `MakeDEmap_YV12(env, ref, 1)` at the top of every invocation.
///
/// The function caps `counter` at `pthreshold` and bails early once it
/// crosses, matching upstream's optimisation.
pub fn evalIv(
    width: i32,
    height: i32,
    pthreshold: i32,
    edge_map: []u8,
    src_y: [*]const u8, src_y_stride: usize,
    src_u: [*]const u8, src_u_stride: usize,
    src_v: [*]const u8, src_v_stride: usize,
    ref_y: [*]const u8, ref_y_stride: usize,
    ref_u: [*]const u8, ref_u_stride: usize,
    ref_v: [*]const u8, ref_v_stride: usize,
) EvalResult {
    // Refresh the odd rows of the edge map from `ref`.
    edge_mod.makeDeMap(width, height, 1, edge_map,
        ref_y, ref_y_stride,
        ref_u, ref_u_stride,
        ref_v, ref_v_stride);
    std.debug.assert(@as(usize, @intCast(width)) * @as(usize, @intCast(height)) == edge_map.len);
    const w: usize = @intCast(width);
    const th: u8 = 40;
    const th2: u8 = 6;
    const widthminus16: usize = @intCast((width - 16) >> 1);

    var sum: i64 = 0;
    var sum2: i64 = 0;
    const pthresh: i64 = pthreshold;

    var yy: i32 = 16;
    while (yy < height - 16) : (yy += 2) {
        const y = yy + 1;

        const pT = plane.syp(src_y, src_y_stride, height, 0, y - 1);
        const pC = plane.syp(ref_y, ref_y_stride, height, 0, y);
        const pB = plane.syp(src_y, src_y_stride, height, 0, y + 1);
        const pT_U = plane.syp(src_u, src_u_stride, height, 1, y - 1);
        const pC_U = plane.syp(ref_u, ref_u_stride, height, 1, y);
        const pB_U = plane.syp(src_u, src_u_stride, height, 1, y + 1);
        const pT_V = plane.syp(src_v, src_v_stride, height, 2, y - 1);
        const pC_V = plane.syp(ref_v, ref_v_stride, height, 2, y);
        const pB_V = plane.syp(src_v, src_v_stride, height, 2, y + 1);

        const eT_row: usize = @intCast(plane.clipY(y - 1, height));
        const eC_row: usize = @intCast(plane.clipY(y, height));
        const eB_row: usize = @intCast(plane.clipY(y + 1, height));
        const peT = edge_map[eT_row * w ..][0..w];
        const peC = edge_map[eC_row * w ..][0..w];
        const peB = edge_map[eB_row * w ..][0..w];

        var i: usize = 16;
        const LANES = 16; // chroma; luma uses 32

        // SIMD body
        const th_v: @Vector(32, u8) = @splat(th);
        const th2_v: @Vector(32, u8) = @splat(th2);
        const zeros: @Vector(32, u8) = @splat(0);
        const ones: @Vector(32, u8) = @splat(1);
        while (i + LANES <= widthminus16) : (i += LANES) {
            // Luma kernel over 32 contiguous bytes (covers lanes i*2..i*2+31).
            const c_y = simd.load(32, pC, i * 2);
            const t_y = simd.load(32, pT, i * 2);
            const b_y = simd.load(32, pB, i * 2);
            const yk = evalIvVec(32, c_y, t_y, b_y);

            // Chroma kernel over 16 bytes (covers lanes i..i+15).
            const c_u = simd.load(LANES, pC_U, i);
            const t_u = simd.load(LANES, pT_U, i);
            const b_u = simd.load(LANES, pB_U, i);
            const uk = evalIvVec(LANES, c_u, t_u, b_u);

            const c_v = simd.load(LANES, pC_V, i);
            const t_v = simd.load(LANES, pT_V, i);
            const b_v = simd.load(LANES, pB_V, i);
            const vk = evalIvVec(LANES, c_v, t_v, b_v);

            const uvk = @max(uk, vk);
            var mm0 = @max(yk, simd.expandPairs(LANES, uvk));

            const peC32 = simd.load(32, peC.ptr, i * 2);
            const peT32 = simd.load(32, peT.ptr, i * 2);
            const peB32 = simd.load(32, peB.ptr, i * 2);
            const pe = @max(@max(peC32, peT32), peB32);

            mm0 = mm0 -| pe;
            mm0 = mm0 -| pe;

            const mask1: @Vector(32, bool) = mm0 > th_v;
            const mask2: @Vector(32, bool) = mm0 > th2_v;
            sum += @reduce(.Add, @as(@Vector(32, u16), @select(u8, mask1, ones, zeros)));
            sum2 += @reduce(.Add, @as(@Vector(32, u16), @select(u8, mask2, ones, zeros)));
        }
        // Scalar tail
        while (i < widthminus16) : (i += 1) {
            const yl = evalIvAsm(pC, pT, pB, i * 2);
            const yh = evalIvAsm(pC, pT, pB, i * 2 + 1);
            const u = evalIvAsm(pC_U, pT_U, pB_U, i);
            const v = evalIvAsm(pC_V, pT_V, pB_V, i);

            const uv = @max(u, v);
            var mm0l = @max(yl, uv);
            var mm0h = @max(yh, uv);

            const peCl = peC[i * 2];
            const peCh = peC[i * 2 + 1];
            const peTl = peT[i * 2];
            const peTh = peT[i * 2 + 1];
            const peBl = peB[i * 2];
            const peBh = peB[i * 2 + 1];
            const pel = @max(@max(peTl, peBl), peCl);
            const peh = @max(@max(peTh, peBh), peCh);

            // upstream subtracts pe twice (saturating each time).
            mm0l = subSat(mm0l, pel);
            mm0l = subSat(mm0l, pel);
            mm0h = subSat(mm0h, peh);
            mm0h = subSat(mm0h, peh);

            sum += @intFromBool(mm0l > th);
            sum += @intFromBool(mm0h > th);
            sum2 += @intFromBool(mm0l > th2);
            sum2 += @intFromBool(mm0h > th2);
        }

        if (sum > pthresh) {
            sum = pthresh;
            break;
        }
    }

    return .{ .counter = sum, .counterp = sum2 };
}

// ---------------------------------------------------------------------------
test "evalIv: flat frames produce zero interlace evidence" {
    const width: i32 = 64;
    const height: i32 = 48;
    const w: usize = @intCast(width);
    const h: usize = @intCast(height);

    const yp = try std.testing.allocator.alloc(u8, w * h);
    defer std.testing.allocator.free(yp);
    const up = try std.testing.allocator.alloc(u8, (w / 2) * (h / 2));
    defer std.testing.allocator.free(up);
    const vp = try std.testing.allocator.alloc(u8, (w / 2) * (h / 2));
    defer std.testing.allocator.free(vp);
    const edge = try std.testing.allocator.alloc(u8, w * h);
    defer std.testing.allocator.free(edge);

    @memset(yp, 128);
    @memset(up, 100);
    @memset(vp, 100);
    @memset(edge, 0);
    // EvalIV now refreshes the offset=1 rows internally. The caller would
    // normally have run makeDeMap(offset=0, srcC) once before; for these
    // flat-input tests we can skip even that since the result is all zero.

    const r = evalIv(width, height, 100, edge,
        yp.ptr, w, up.ptr, w / 2, vp.ptr, w / 2,
        yp.ptr, w, up.ptr, w / 2, vp.ptr, w / 2);
    try std.testing.expectEqual(@as(i64, 0), r.counter);
    try std.testing.expectEqual(@as(i64, 0), r.counterp);
}

test "evalIv: interlaced striping flags pixels" {
    const width: i32 = 64;
    const height: i32 = 48;
    const w: usize = @intCast(width);
    const h: usize = @intCast(height);

    const yp = try std.testing.allocator.alloc(u8, w * h);
    defer std.testing.allocator.free(yp);
    const up = try std.testing.allocator.alloc(u8, (w / 2) * (h / 2));
    defer std.testing.allocator.free(up);
    const vp = try std.testing.allocator.alloc(u8, (w / 2) * (h / 2));
    defer std.testing.allocator.free(vp);
    const edge = try std.testing.allocator.alloc(u8, w * h);
    defer std.testing.allocator.free(edge);

    // Striping: even rows = 0, odd rows = 200 — classic interlace-mismatch
    // pattern. evalIv reads pT/pC/pB at y-1, y, y+1 so the central row sees
    // a huge gap between its value and the averaged neighbours.
    var r: usize = 0;
    while (r < h) : (r += 1) {
        const v: u8 = if (r & 1 == 0) 0 else 200;
        @memset(yp[r * w ..][0..w], v);
    }
    @memset(up, 100);
    @memset(vp, 100);
    @memset(edge, 0);
    edge_mod.makeDeMap(width, height, 0, edge,
        yp.ptr, w, up.ptr, w / 2, vp.ptr, w / 2);

    const result = evalIv(width, height, 1_000_000, edge,
        yp.ptr, w, up.ptr, w / 2, vp.ptr, w / 2,
        yp.ptr, w, up.ptr, w / 2, vp.ptr, w / 2);
    try std.testing.expect(result.counter > 0);
    try std.testing.expect(result.counterp >= result.counter);
}

test "evalIv: result is capped at pthreshold" {
    const width: i32 = 64;
    const height: i32 = 48;
    const w: usize = @intCast(width);
    const h: usize = @intCast(height);

    const yp = try std.testing.allocator.alloc(u8, w * h);
    defer std.testing.allocator.free(yp);
    const up = try std.testing.allocator.alloc(u8, (w / 2) * (h / 2));
    defer std.testing.allocator.free(up);
    const vp = try std.testing.allocator.alloc(u8, (w / 2) * (h / 2));
    defer std.testing.allocator.free(vp);
    const edge = try std.testing.allocator.alloc(u8, w * h);
    defer std.testing.allocator.free(edge);

    var r: usize = 0;
    while (r < h) : (r += 1) {
        const v: u8 = if (r & 1 == 0) 0 else 200;
        @memset(yp[r * w ..][0..w], v);
    }
    @memset(up, 100);
    @memset(vp, 100);
    @memset(edge, 0);
    edge_mod.makeDeMap(width, height, 0, edge,
        yp.ptr, w, up.ptr, w / 2, vp.ptr, w / 2);

    const result = evalIv(width, height, 5, edge,
        yp.ptr, w, up.ptr, w / 2, vp.ptr, w / 2,
        yp.ptr, w, up.ptr, w / 2, vp.ptr, w / 2);
    try std.testing.expectEqual(@as(i64, 5), result.counter);
}
