//! `EvalIV_YV12` — count pixels that look like they belong to two different
//! fields (interlace evidence) within the central region of a frame.
//!
//! Ported from `reference/vapoursynth-cpp/src/vs_it_c.cpp::EvalIV_YV12`.
//!
//! The caller must have already filled the edge map for `ref` via
//! `makeDeMap(width, height, offset=1, ...)`.
//!
//! Generic over the pixel storage type `T` (u8/u16) and bit-depth `bits`.
//! Pixel-diff math runs at T precision; before subtracting the (u8) edge
//! map the diff is downscaled to u8 via `scalar.toMapByte` /
//! `simd.toMapByteVec`. The IV thresholds (40, 6) stay 8-bit-calibrated.

const std = @import("std");
const plane = @import("plane.zig");
const edge_mod = @import("edge.zig");
const simd = @import("simd.zig");
const scalar = @import("scalar.zig");

/// min(|a-b|, |a-c|, |a - (b+c+1)/2|) — the inner "evaluate-interlace"
/// kernel from upstream's `eval_iv_asm`.
inline fn evalIvAsm(comptime T: type, eax: [*]const T, ebx: [*]const T, ecx: [*]const T, i: usize) T {
    const a = eax[i];
    const b = ebx[i];
    const c = ecx[i];
    return @min(@min(scalar.absDiff(a, b), scalar.absDiff(a, c)), scalar.absDiff(a, scalar.pavgb(b, c)));
}

/// SIMD eval-iv kernel for N lanes: min(|a-b|, |a-c|, |a - pavgb(b,c)|).
inline fn evalIvVec(comptime N: usize, a: anytype, b: @TypeOf(a), c: @TypeOf(a)) @TypeOf(a) {
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
pub inline fn evalIv(
    comptime T: type,
    comptime bits: u8,
    comptime cs: plane.ChromaSampling,
    width: i32,
    height: i32,
    pthreshold: i32,
    edge_map: []u8,
    src_y: [*]const T,
    src_y_stride: usize,
    src_u: [*]const T,
    src_u_stride: usize,
    src_v: [*]const T,
    src_v_stride: usize,
    ref_y: [*]const T,
    ref_y_stride: usize,
    ref_u: [*]const T,
    ref_u_stride: usize,
    ref_v: [*]const T,
    ref_v_stride: usize,
) EvalResult {
    // Refresh the odd rows of the edge map from `ref`.
    edge_mod.makeDeMap(T, bits, cs, width, height, 1, edge_map, ref_y, ref_y_stride, ref_u, ref_u_stride, ref_v, ref_v_stride);
    std.debug.assert(@as(usize, @intCast(width)) * @as(usize, @intCast(height)) == edge_map.len);
    const w: usize = @intCast(width);
    const th: u8 = 40;
    const th2: u8 = 6;

    var sum: i64 = 0;
    var sum2: i64 = 0;
    const pthresh: i64 = pthreshold;

    var yy: i32 = 16;
    while (yy < height - 16) : (yy += 2) {
        const y = yy + 1;

        const pT = plane.syp(src_y, src_y_stride, height, 0, y - 1);
        const pC = plane.syp(ref_y, ref_y_stride, height, 0, y);
        const pB = plane.syp(src_y, src_y_stride, height, 0, y + 1);
        const pT_U = plane.sypChroma(cs, src_u, src_u_stride, height, y - 1);
        const pC_U = plane.sypChroma(cs, ref_u, ref_u_stride, height, y);
        const pB_U = plane.sypChroma(cs, src_u, src_u_stride, height, y + 1);
        const pT_V = plane.sypChroma(cs, src_v, src_v_stride, height, y - 1);
        const pC_V = plane.sypChroma(cs, ref_v, ref_v_stride, height, y);
        const pB_V = plane.sypChroma(cs, src_v, src_v_stride, height, y + 1);

        const eT_row: usize = @intCast(plane.clipY(y - 1, height));
        const eC_row: usize = @intCast(plane.clipY(y, height));
        const eB_row: usize = @intCast(plane.clipY(y + 1, height));
        const peT = edge_map[eT_row * w ..][0..w];
        const peC = edge_map[eC_row * w ..][0..w];
        const peB = edge_map[eB_row * w ..][0..w];

        var i: usize = 16;
        if (plane.subW(cs)) {
            // Half-rate chroma (4:2:0 / 4:2:2): LANES chroma lanes broadcast to
            // the 2*LANES luma lanes via expandPairs (256-bit chroma block,
            // luma 2x). Chroma loop bound is (width-16)/2 chroma samples.
            const LANES: usize = 16 / @sizeOf(T);
            const widthminus16: usize = @intCast((width - 16) >> 1);
            const th_v: @Vector(LANES * 2, u8) = @splat(th);
            const th2_v: @Vector(LANES * 2, u8) = @splat(th2);
            const zeros: @Vector(LANES * 2, u8) = @splat(0);
            const ones: @Vector(LANES * 2, u8) = @splat(1);
            while (i + LANES <= widthminus16) : (i += LANES) {
                // Luma kernel over 2*LANES contiguous samples.
                const c_y = simd.load(LANES * 2, pC, i * 2);
                const t_y = simd.load(LANES * 2, pT, i * 2);
                const b_y = simd.load(LANES * 2, pB, i * 2);
                const yk = evalIvVec(LANES * 2, c_y, t_y, b_y);

                // Chroma kernel over LANES samples.
                const c_u = simd.load(LANES, pC_U, i);
                const t_u = simd.load(LANES, pT_U, i);
                const b_u = simd.load(LANES, pB_U, i);
                const uk = evalIvVec(LANES, c_u, t_u, b_u);

                const c_v = simd.load(LANES, pC_V, i);
                const t_v = simd.load(LANES, pT_V, i);
                const b_v = simd.load(LANES, pB_V, i);
                const vk = evalIvVec(LANES, c_v, t_v, b_v);

                const uvk = @max(uk, vk);
                const mm0_t = @max(yk, simd.expandPairs(LANES, uvk));
                // Downscale T-precision diff to u8 for the map-subtract sequence.
                var mm0 = simd.toMapByteVec(T, bits, LANES * 2, mm0_t);

                const peC32 = simd.load(LANES * 2, peC.ptr, i * 2);
                const peT32 = simd.load(LANES * 2, peT.ptr, i * 2);
                const peB32 = simd.load(LANES * 2, peB.ptr, i * 2);
                const pe = @max(@max(peC32, peT32), peB32);

                mm0 = mm0 -| pe;
                mm0 = mm0 -| pe;

                const mask1: @Vector(LANES * 2, bool) = mm0 > th_v;
                const mask2: @Vector(LANES * 2, bool) = mm0 > th2_v;
                sum += @reduce(.Add, @as(@Vector(LANES * 2, u16), @select(u8, mask1, ones, zeros)));
                sum2 += @reduce(.Add, @as(@Vector(LANES * 2, u16), @select(u8, mask2, ones, zeros)));
            }
            // Scalar tail
            while (i < widthminus16) : (i += 1) {
                const yl_t = evalIvAsm(T, pC, pT, pB, i * 2);
                const yh_t = evalIvAsm(T, pC, pT, pB, i * 2 + 1);
                const u_t = evalIvAsm(T, pC_U, pT_U, pB_U, i);
                const v_t = evalIvAsm(T, pC_V, pT_V, pB_V, i);

                const uv = @max(u_t, v_t);
                const mm0l_t = @max(yl_t, uv);
                const mm0h_t = @max(yh_t, uv);
                var mm0l = scalar.toMapByte(T, bits, mm0l_t);
                var mm0h = scalar.toMapByte(T, bits, mm0h_t);

                const peCl = peC[i * 2];
                const peCh = peC[i * 2 + 1];
                const peTl = peT[i * 2];
                const peTh = peT[i * 2 + 1];
                const peBl = peB[i * 2];
                const peBh = peB[i * 2 + 1];
                const pel = @max(@max(peTl, peBl), peCl);
                const peh = @max(@max(peTh, peBh), peCh);

                // upstream subtracts pe twice (saturating each time).
                mm0l = scalar.subSat(mm0l, pel);
                mm0l = scalar.subSat(mm0l, pel);
                mm0h = scalar.subSat(mm0h, peh);
                mm0h = scalar.subSat(mm0h, peh);

                sum += @intFromBool(mm0l > th);
                sum += @intFromBool(mm0h > th);
                sum2 += @intFromBool(mm0l > th2);
                sum2 += @intFromBool(mm0h > th2);
            }
        } else {
            // Full-rate chroma (4:4:4): luma + chroma evaluated 1:1, no
            // expandPairs, over the central region [16, width-16).
            const VW: usize = 32 / @sizeOf(T);
            const wm16: usize = @intCast(width - 16);
            const th_v: @Vector(VW, u8) = @splat(th);
            const th2_v: @Vector(VW, u8) = @splat(th2);
            const zeros: @Vector(VW, u8) = @splat(0);
            const ones: @Vector(VW, u8) = @splat(1);
            while (i + VW <= wm16) : (i += VW) {
                const c_y = simd.load(VW, pC, i);
                const t_y = simd.load(VW, pT, i);
                const b_y = simd.load(VW, pB, i);
                const yk = evalIvVec(VW, c_y, t_y, b_y);
                const c_u = simd.load(VW, pC_U, i);
                const t_u = simd.load(VW, pT_U, i);
                const b_u = simd.load(VW, pB_U, i);
                const uk = evalIvVec(VW, c_u, t_u, b_u);
                const c_v = simd.load(VW, pC_V, i);
                const t_v = simd.load(VW, pT_V, i);
                const b_v = simd.load(VW, pB_V, i);
                const vk = evalIvVec(VW, c_v, t_v, b_v);

                const uvk = @max(uk, vk);
                const mm0_t = @max(yk, uvk);
                var mm0 = simd.toMapByteVec(T, bits, VW, mm0_t);

                const peC32 = simd.load(VW, peC.ptr, i);
                const peT32 = simd.load(VW, peT.ptr, i);
                const peB32 = simd.load(VW, peB.ptr, i);
                const pe = @max(@max(peC32, peT32), peB32);

                mm0 = mm0 -| pe;
                mm0 = mm0 -| pe;

                const mask1: @Vector(VW, bool) = mm0 > th_v;
                const mask2: @Vector(VW, bool) = mm0 > th2_v;
                sum += @reduce(.Add, @as(@Vector(VW, u16), @select(u8, mask1, ones, zeros)));
                sum2 += @reduce(.Add, @as(@Vector(VW, u16), @select(u8, mask2, ones, zeros)));
            }
            // Scalar tail
            while (i < wm16) : (i += 1) {
                const yv = evalIvAsm(T, pC, pT, pB, i);
                const uu = evalIvAsm(T, pC_U, pT_U, pB_U, i);
                const vv = evalIvAsm(T, pC_V, pT_V, pB_V, i);
                const uv = @max(uu, vv);
                var mm0 = scalar.toMapByte(T, bits, @max(yv, uv));
                const pe = @max(@max(peT[i], peB[i]), peC[i]);
                mm0 = scalar.subSat(mm0, pe);
                mm0 = scalar.subSat(mm0, pe);
                sum += @intFromBool(mm0 > th);
                sum2 += @intFromBool(mm0 > th2);
            }
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

    const r = evalIv(u8, 8, .yuv420, width, height, 100, edge, yp.ptr, w, up.ptr, w / 2, vp.ptr, w / 2, yp.ptr, w, up.ptr, w / 2, vp.ptr, w / 2);
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
    edge_mod.makeDeMap(u8, 8, .yuv420, width, height, 0, edge, yp.ptr, w, up.ptr, w / 2, vp.ptr, w / 2);

    const result = evalIv(u8, 8, .yuv420, width, height, 1_000_000, edge, yp.ptr, w, up.ptr, w / 2, vp.ptr, w / 2, yp.ptr, w, up.ptr, w / 2, vp.ptr, w / 2);
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
    edge_mod.makeDeMap(u8, 8, .yuv420, width, height, 0, edge, yp.ptr, w, up.ptr, w / 2, vp.ptr, w / 2);

    const result = evalIv(u8, 8, .yuv420, width, height, 5, edge, yp.ptr, w, up.ptr, w / 2, vp.ptr, w / 2, yp.ptr, w, up.ptr, w / 2, vp.ptr, w / 2);
    try std.testing.expectEqual(@as(i64, 5), result.counter);
}

test "evalIv 4:4:4: interlaced striping flags pixels (full-rate chroma)" {
    // Exercises the !subW branch with full-resolution chroma planes.
    const width: i32 = 64;
    const height: i32 = 48;
    const w: usize = @intCast(width);
    const h: usize = @intCast(height);
    const yp = try std.testing.allocator.alloc(u8, w * h);
    defer std.testing.allocator.free(yp);
    const up = try std.testing.allocator.alloc(u8, w * h); // full-res chroma
    defer std.testing.allocator.free(up);
    const vp = try std.testing.allocator.alloc(u8, w * h);
    defer std.testing.allocator.free(vp);
    const edge = try std.testing.allocator.alloc(u8, w * h);
    defer std.testing.allocator.free(edge);

    var r: usize = 0;
    while (r < h) : (r += 1) {
        const val: u8 = if (r & 1 == 0) 0 else 200;
        @memset(yp[r * w ..][0..w], val);
    }
    @memset(up, 100);
    @memset(vp, 100);
    @memset(edge, 0);
    edge_mod.makeDeMap(u8, 8, .yuv444, width, height, 0, edge, yp.ptr, w, up.ptr, w, vp.ptr, w);

    const result = evalIv(u8, 8, .yuv444, width, height, 1_000_000, edge, yp.ptr, w, up.ptr, w, vp.ptr, w, yp.ptr, w, up.ptr, w, vp.ptr, w);
    try std.testing.expect(result.counter > 0);
    try std.testing.expect(result.counterp >= result.counter);
}

test "evalIv 4:2:2: interlaced striping flags pixels (half-width, full-height chroma)" {
    // Direct end-to-end coverage of evalIv with cs=.yuv422: the subW body plus
    // sypChroma(.yuv422) full-height (1:1 row) chroma addressing together (so
    // far only covered transitively via the 4:2:0 tests + the plane.zig test).
    const width: i32 = 64;
    const height: i32 = 48;
    const w: usize = @intCast(width);
    const h: usize = @intCast(height);
    const cw = w / 2; // 4:2:2 chroma: half width, full height
    const yp = try std.testing.allocator.alloc(u8, w * h);
    defer std.testing.allocator.free(yp);
    const up = try std.testing.allocator.alloc(u8, cw * h);
    defer std.testing.allocator.free(up);
    const vp = try std.testing.allocator.alloc(u8, cw * h);
    defer std.testing.allocator.free(vp);
    const edge = try std.testing.allocator.alloc(u8, w * h);
    defer std.testing.allocator.free(edge);

    var r: usize = 0;
    while (r < h) : (r += 1) {
        const val: u8 = if (r & 1 == 0) 0 else 200;
        @memset(yp[r * w ..][0..w], val);
    }
    @memset(up, 100);
    @memset(vp, 100);
    @memset(edge, 0);
    edge_mod.makeDeMap(u8, 8, .yuv422, width, height, 0, edge, yp.ptr, w, up.ptr, cw, vp.ptr, cw);

    const result = evalIv(u8, 8, .yuv422, width, height, 1_000_000, edge, yp.ptr, w, up.ptr, cw, vp.ptr, cw, yp.ptr, w, up.ptr, cw, vp.ptr, cw);
    try std.testing.expect(result.counter > 0);
    try std.testing.expect(result.counterp >= result.counter);
}
