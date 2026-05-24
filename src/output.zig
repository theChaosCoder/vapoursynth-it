//! Output stage — write the final pixels into the destination frame.
//!
//! Ported from `reference/vapoursynth-cpp/src/vs_it_process.cpp`:
//!   - `copyCPNField` (CopyCPNField) — used when the frame is judged
//!     progressive. Copies top field from the current source frame and the
//!     matching bottom field from the chosen reference (C/P/N).
//!   - `deintOneField` (DeintOneField_YV12) — motion-adaptive deinterlace
//!     for frames that are genuinely interlaced. Builds a field-map from the
//!     simple-blur and motion2max maps and chooses per-pixel between
//!     copying from the reference and vertically averaging within the source.
//!
//! Both functions are stateless on their pointer arguments; they receive
//! pre-fetched plane pointers / strides from the caller. The caller is also
//! responsible for picking the reference frame (`refY/U/V`) per `iUseFrame`.

const std = @import("std");
const plane = @import("plane.zig");
const simd = @import("simd.zig");

/// Copies one byte-row from src to dst using independent strides.
inline fn bitblt(dst: [*]u8, src: [*]const u8, row_size: usize) void {
    @memcpy(dst[0..row_size], src[0..row_size]);
}

/// Y-plane row-size for `width`. Chroma is `width >> subSamplingW`; for
/// YUV420P8 that's `width / 2`.
inline fn chromaWidth(width: i32) i32 {
    return width >> 1;
}

/// `CopyCPNField`. `srcC*` are the current frame's planes; `srcR*` are the
/// chosen reference (= srcC when iUseFrame=='C', otherwise prev/next frame).
/// Strides for the destination are taken separately because VS may align them
/// differently from source.
pub fn copyCPNField(
    width: i32,
    height: i32,
    dst: plane.PlaneViewMut,
    src: plane.PlaneView,
    ref: plane.PlaneView,
) void {
    const row_y: usize = @intCast(width);
    const row_uv: usize = @intCast(chromaWidth(width));

    var yy: i32 = 0;
    while (yy < height) : (yy += 2) {
        const y = yy + 1;
        const yo = yy;
        // Y: top row from srcC, bottom from ref
        bitblt(plane.dyp(dst.y, dst.y_stride, height, 0, yo), plane.syp(src.y, src.y_stride, height, 0, yo), row_y);
        bitblt(plane.dyp(dst.y, dst.y_stride, height, 0, y), plane.syp(ref.y, ref.y_stride, height, 0, y), row_y);

        if (@mod(yy >> 1, 2) != 0) {
            bitblt(plane.dyp(dst.u, dst.u_stride, height, 1, yo), plane.syp(src.u, src.u_stride, height, 1, yo), row_uv);
            bitblt(plane.dyp(dst.u, dst.u_stride, height, 1, y), plane.syp(ref.u, ref.u_stride, height, 1, y), row_uv);
            bitblt(plane.dyp(dst.v, dst.v_stride, height, 2, yo), plane.syp(src.v, src.v_stride, height, 2, yo), row_uv);
            bitblt(plane.dyp(dst.v, dst.v_stride, height, 2, y), plane.syp(ref.v, ref.v_stride, height, 2, y), row_uv);
        }
    }
}

/// `DeintOneField_YV12`. Performs motion-adaptive deinterlace using two
/// scratch buffers populated by the caller:
///   * `simple_blur`: from makeSimpleBlurMap(curr, ref)
///   * `motion2max` : from makeMotionMap2Max(prev, curr, next)
/// Both are `width * height` byte buffers.
///
/// `field_map_scratch` is a writable `width * height` buffer used internally
/// and clobbered on return; pass in the IT instance's existing scratch
/// allocation rather than alloc-per-call.
pub fn deintOneField(
    width: i32,
    height: i32,
    simple_blur: []const u8,
    motion2max: []const u8,
    field_map_scratch: []u8,
    dst: plane.PlaneViewMut,
    src: plane.PlaneView,
    ref_y: [*]const u8,
    ref_y_stride: usize,
) void {
    const w: usize = @intCast(width);
    const h: usize = @intCast(height);
    std.debug.assert(simple_blur.len == w * h);
    std.debug.assert(motion2max.len == w * h);
    std.debug.assert(field_map_scratch.len == w * h);

    @memset(field_map_scratch, 0);

    // Build the field map: pixels where both blur and motion2max are
    // "noticeably bright" along three columns get tagged.
    const nTh: u8 = 12;
    const nThLine: u8 = 1;
    var y: i32 = 0;
    while (y < height) : (y += 1) {
        const fm_row: usize = @intCast(plane.clipY(y, height));
        const fm = field_map_scratch[fm_row * w ..][0..w];
        const sc_row: usize = @intCast(plane.clipY(y, height));
        const sb_row: usize = @intCast(plane.clipY(y + 1, height));
        const mc_row: usize = @intCast(plane.clipY(y, height));
        const mb_row: usize = @intCast(plane.clipY(y + 1, height));
        const pmSC = simple_blur[sc_row * w ..][0..w];
        const pmSB = simple_blur[sb_row * w ..][0..w];
        const pmMC = motion2max[mc_row * w ..][0..w];
        const pmMB = motion2max[mb_row * w ..][0..w];

        var x: usize = 1;
        while (x + 1 < w) : (x += 1) {
            const blur_ok = ((pmSC[x - 1] > nThLine and pmSC[x] > nThLine and pmSC[x + 1] > nThLine) or
                (pmSB[x - 1] > nThLine and pmSB[x] > nThLine and pmSB[x + 1] > nThLine));
            const motion_ok = ((pmMC[x - 1] > nTh and pmMC[x] > nTh and pmMC[x + 1] > nTh) or
                (pmMB[x - 1] > nTh and pmMB[x] > nTh and pmMB[x + 1] > nTh));
            if (blur_ok and motion_ok) {
                fm[x - 1] = 1;
                fm[x] = 1;
                fm[x + 1] = 1;
            }
        }
    }

    const row_y: usize = w;
    const row_uv: usize = w / 2;
    y = 0;
    while (y < height) : (y += 2) {
        const pC = plane.syp(src.y, src.y_stride, height, 0, y);
        const pB = plane.syp(ref_y, ref_y_stride, height, 0, y + 1);
        const pBB = plane.syp(src.y, src.y_stride, height, 0, y + 2);
        const pC_U = plane.syp(src.u, src.u_stride, height, 1, y);
        const pBB_U = plane.syp(src.u, src.u_stride, height, 1, y + 4);
        const pC_V = plane.syp(src.v, src.v_stride, height, 2, y);
        const pBB_V = plane.syp(src.v, src.v_stride, height, 2, y + 4);

        const pDC = plane.dyp(dst.y, dst.y_stride, height, 0, y);
        const pDB = plane.dyp(dst.y, dst.y_stride, height, 0, y + 1);
        const pDC_U = plane.dyp(dst.u, dst.u_stride, height, 1, y);
        const pDB_U = plane.dyp(dst.u, dst.u_stride, height, 1, y + 1);
        const pDC_V = plane.dyp(dst.v, dst.v_stride, height, 2, y);
        const pDB_V = plane.dyp(dst.v, dst.v_stride, height, 2, y + 1);

        // Top luma row: straight copy from current
        @memcpy(pDC[0..row_y], pC[0..row_y]);

        if (@mod(y >> 1, 2) != 0) {
            @memcpy(pDC_U[0..row_uv], pC_U[0..row_uv]);
            @memcpy(pDC_V[0..row_uv], pC_V[0..row_uv]);
        }

        const fm_row: usize = @intCast(plane.clipY(y, height));
        const fmB_row: usize = @intCast(plane.clipY(y + 1, height));
        const fm_base: isize = @as(isize, @intCast(fm_row)) * @as(isize, @intCast(w));
        const fmB_base: isize = @as(isize, @intCast(fmB_row)) * @as(isize, @intCast(w));
        const buf_len: isize = @intCast(field_map_scratch.len);

        // Read field_map with absolute offsets, matching upstream's pointer
        // arithmetic: `pFM[x-1]` at x=0 spills into the previous row's last
        // byte, and `pFM[x+1]` at x=width-1 spills into the next row's first
        // byte. The C++ original relies on the field map being one
        // contiguous `new unsigned char[width*height]` allocation; we
        // replicate that lookup pattern bit-for-bit. Only the *very* first
        // and last bytes of the whole buffer (which are UB-reads in upstream
        // and happen to land on heap padding) are clamped to 0.
        const fm_at = struct {
            inline fn get(buf: []const u8, idx: isize, total: isize) u8 {
                if (idx < 0 or idx >= total) return 0;
                return buf[@intCast(idx)];
            }
        }.get;

        const D_LANES = 16;
        // The field-map reads at offset (fm_base ± xi-1 .. fm_base ± xi+1)
        // are safe for the bulk of the buffer; only the very first byte
        // (when fm_base=0 and x=0 → idx = -1) and the very last byte
        // (when fmB_base=last_row and x=w-1 → idx = h*w) ever spill.
        // We scalar-handle x=0 + the trailing tail and SIMD the middle.
        var x: usize = 0;
        // Scalar prologue: x=0
        if (w > 0) {
            const x_half = @as(usize, 0);
            const fm_l = fm_at(field_map_scratch, fm_base - 1, buf_len);
            const fm_c = fm_at(field_map_scratch, fm_base, buf_len);
            const fm_r = fm_at(field_map_scratch, fm_base + 1, buf_len);
            const fmB_l = fm_at(field_map_scratch, fmB_base - 1, buf_len);
            const fmB_c = fm_at(field_map_scratch, fmB_base, buf_len);
            const fmB_r = fm_at(field_map_scratch, fmB_base + 1, buf_len);
            const need_blend = (fm_l == 1 or fm_c == 1 or fm_r == 1) or (fmB_l == 1 or fmB_c == 1 or fmB_r == 1);
            const blended: u8 = @intCast((@as(u16, pC[0]) + @as(u16, pBB[0]) + 1) >> 1);
            pDB[0] = if (need_blend) blended else pB[0];
            if (@mod(y >> 1, 2) != 0) {
                pDB_U[x_half] = @intCast((@as(u16, pC_U[x_half]) + @as(u16, pBB_U[x_half]) + 1) >> 1);
                pDB_V[x_half] = @intCast((@as(u16, pC_V[x_half]) + @as(u16, pBB_V[x_half]) + 1) >> 1);
            }
            x = 1;
        }

        // SIMD body — m_l reads from fm_base+x-1, m_r reads up to fm_base+x+LANES.
        // Both must stay within the buffer; the loop bound `x+LANES+1 <= w`
        // ensures both rows' reads stay within their respective rows.
        const fm_zero: @Vector(D_LANES, u8) = @splat(0);
        while (x + D_LANES + 1 <= w) : (x += D_LANES) {
            const fm_off: usize = @intCast(fm_base + @as(isize, @intCast(x)));
            const fmB_off: usize = @intCast(fmB_base + @as(isize, @intCast(x)));
            const m_l = simd.load(D_LANES, field_map_scratch.ptr, fm_off - 1);
            const m_c = simd.load(D_LANES, field_map_scratch.ptr, fm_off);
            const m_r = simd.load(D_LANES, field_map_scratch.ptr, fm_off + 1);
            const mB_l = simd.load(D_LANES, field_map_scratch.ptr, fmB_off - 1);
            const mB_c = simd.load(D_LANES, field_map_scratch.ptr, fmB_off);
            const mB_r = simd.load(D_LANES, field_map_scratch.ptr, fmB_off + 1);
            const or_mask = m_l | m_c | m_r | mB_l | mB_c | mB_r;
            const blend_mask: @Vector(D_LANES, bool) = or_mask != fm_zero;

            const c_v = simd.load(D_LANES, pC, x);
            const bb_v = simd.load(D_LANES, pBB, x);
            const b_v = simd.load(D_LANES, pB, x);
            const blended = simd.pavgb(D_LANES, c_v, bb_v);
            const result = @select(u8, blend_mask, blended, b_v);
            simd.store(D_LANES, pDB, x, result);

            // Chroma is unconditional (no need_blend dependency) — always
            // the vertical pavgb. Process D_LANES/2 chroma bytes per luma
            // chunk so the indices stay aligned.
            if (@mod(y >> 1, 2) != 0) {
                const xh: usize = x >> 1;
                const HC = D_LANES / 2;
                const pcu = simd.load(HC, pC_U, xh);
                const pbu = simd.load(HC, pBB_U, xh);
                simd.store(HC, pDB_U, xh, simd.pavgb(HC, pcu, pbu));
                const pcv = simd.load(HC, pC_V, xh);
                const pbv = simd.load(HC, pBB_V, xh);
                simd.store(HC, pDB_V, xh, simd.pavgb(HC, pcv, pbv));
            }
        }

        // Scalar tail
        while (x < w) : (x += 1) {
            const xi: isize = @intCast(x);
            const x_half = x >> 1;
            const fm_l = fm_at(field_map_scratch, fm_base + xi - 1, buf_len);
            const fm_c = fm_at(field_map_scratch, fm_base + xi, buf_len);
            const fm_r = fm_at(field_map_scratch, fm_base + xi + 1, buf_len);
            const fmB_l = fm_at(field_map_scratch, fmB_base + xi - 1, buf_len);
            const fmB_c = fm_at(field_map_scratch, fmB_base + xi, buf_len);
            const fmB_r = fm_at(field_map_scratch, fmB_base + xi + 1, buf_len);
            const need_blend = (fm_l == 1 or fm_c == 1 or fm_r == 1) or (fmB_l == 1 or fmB_c == 1 or fmB_r == 1);
            const blended: u8 = @intCast((@as(u16, pC[x]) + @as(u16, pBB[x]) + 1) >> 1);
            pDB[x] = if (need_blend) blended else pB[x];

            if (@mod(y >> 1, 2) != 0) {
                const u_avg: u8 = @intCast((@as(u16, pC_U[x_half]) + @as(u16, pBB_U[x_half]) + 1) >> 1);
                const v_avg: u8 = @intCast((@as(u16, pC_V[x_half]) + @as(u16, pBB_V[x_half]) + 1) >> 1);
                pDB_U[x_half] = u_avg;
                pDB_V[x_half] = v_avg;
            }
        }
    }
}

/// Compact reimplementation of upstream's `eval_iv_asm` for one pixel.
/// Returns min(|a - b|, |a - c|, |a - (b+c+1)/2|). Used by `deinterlace`
/// and matches the DEINTERLACE_ASM_1 / DEINTERLACE_ASM_2 macros from the
/// Avisynth original.
inline fn ivKernel(a: u8, b: u8, c: u8) u8 {
    const ab = if (a > b) a - b else b - a;
    const ac = if (a > c) a - c else c - a;
    const bc: u8 = @intCast((@as(u16, b) + @as(u16, c) + 1) >> 1);
    const a_bc = if (a > bc) a - bc else bc - a;
    return @min(@min(ab, ac), a_bc);
}

/// SIMD version of `ivKernel`. Returns the per-lane minimum of |a-b|,
/// |a-c| and |a - pavgb(b, c)| — the deinterlacer's interlace-evidence
/// metric, computed in parallel over `N` pixels.
inline fn ivKernelVec(comptime N: usize, a: @Vector(N, u8), b: @Vector(N, u8), c: @Vector(N, u8)) @Vector(N, u8) {
    const ab = simd.absDiff(N, a, b);
    const ac = simd.absDiff(N, a, c);
    const bc = simd.pavgb(N, b, c);
    const a_bc = simd.absDiff(N, a, bc);
    return @min(@min(ab, ac), a_bc);
}

inline fn pavgb(a: u8, b: u8) u8 {
    return @intCast((@as(u16, a) + @as(u16, b) + 1) >> 1);
}

/// Five plane-row pointers sharing a T/C/B/P/N geometry — the source rows
/// the deinterlacer's per-pixel scalar kernel reads from. Built once per
/// outer (y) iteration so the inner loop can pass them in one struct each
/// for luma, U and V.
const Iv5Rows = struct {
    t: [*]const u8, // y - 1 (top, from current frame)
    c: [*]const u8, // y     (center, from current frame)
    b: [*]const u8, // y + 1 (bottom, from current frame)
    p: [*]const u8, // y     (prev frame)
    n: [*]const u8, // y     (next frame)
};

/// Per-pixel scalar deinterlacer kernel. Computes the 5 IV scores
/// (C / P / N / avg(C,P) / avg(C,N)) for luma and chroma, picks the
/// best-scoring candidate, then applies the motion-gated vertical-average
/// override. Used by both the SIMD body's inner chroma loop and the
/// scalar tail of `deinterlace`.
///
/// `write_luma` / `write_chroma` are comptime: the SIMD body's chroma
/// loop calls with `write_luma=false` because luma is already written by
/// the SIMD store; the scalar tail's chroma rows call with both `true`.
/// Both branches share the IV scoring because the combined luma+chroma
/// score drives both decisions — separating would re-cost the chroma IV.
inline fn deinterlacePixelScalar(
    comptime write_luma: bool,
    comptime write_chroma: bool,
    x: usize,
    y_rows: Iv5Rows,
    u_rows: Iv5Rows,
    v_rows: Iv5Rows,
    pmMT: []const u8,
    pmMB: []const u8,
    pD: [*]u8,
    pD_U: [*]u8,
    pD_V: [*]u8,
) void {
    const xh = x >> 1;

    // Luma IV scores: C / P / N / avg(C,P) / avg(C,N) all against (T, B).
    const ivc_l = ivKernel(y_rows.c[x], y_rows.t[x], y_rows.b[x]);
    const ivp_l = ivKernel(y_rows.p[x], y_rows.t[x], y_rows.b[x]);
    const ivn_l = ivKernel(y_rows.n[x], y_rows.t[x], y_rows.b[x]);
    const ivcp_l = ivKernel(pavgb(y_rows.c[x], y_rows.p[x]), y_rows.t[x], y_rows.b[x]);
    const ivcn_l = ivKernel(pavgb(y_rows.c[x], y_rows.n[x]), y_rows.t[x], y_rows.b[x]);

    // Chroma U IV scores.
    const ivc_u = ivKernel(u_rows.c[xh], u_rows.t[xh], u_rows.b[xh]);
    const ivp_u = ivKernel(u_rows.p[xh], u_rows.t[xh], u_rows.b[xh]);
    const ivn_u = ivKernel(u_rows.n[xh], u_rows.t[xh], u_rows.b[xh]);
    const ivcp_u = ivKernel(pavgb(u_rows.c[xh], u_rows.p[xh]), u_rows.t[xh], u_rows.b[xh]);
    const ivcn_u = ivKernel(pavgb(u_rows.c[xh], u_rows.n[xh]), u_rows.t[xh], u_rows.b[xh]);

    // Chroma V IV scores.
    const ivc_v = ivKernel(v_rows.c[xh], v_rows.t[xh], v_rows.b[xh]);
    const ivp_v = ivKernel(v_rows.p[xh], v_rows.t[xh], v_rows.b[xh]);
    const ivn_v = ivKernel(v_rows.n[xh], v_rows.t[xh], v_rows.b[xh]);
    const ivcp_v = ivKernel(pavgb(v_rows.c[xh], v_rows.p[xh]), v_rows.t[xh], v_rows.b[xh]);
    const ivcn_v = ivKernel(pavgb(v_rows.c[xh], v_rows.n[xh]), v_rows.t[xh], v_rows.b[xh]);

    // Combine: max(U, V) chroma, then max with luma → unified score per
    // candidate that drives both the luma and chroma pick.
    const ivc: u8 = @max(ivc_l, @max(ivc_u, ivc_v));
    var ivp: u8 = @max(ivp_l, @max(ivp_u, ivp_v));
    var ivn: u8 = @max(ivn_l, @max(ivn_u, ivn_v));
    const ivcp: u8 = @max(ivcp_l, @max(ivcp_u, ivcp_v));
    const ivcn: u8 = @max(ivcn_l, @max(ivcn_u, ivcn_v));

    const pix_c: u8 = y_rows.c[x];
    var pix_p: u8 = y_rows.p[x];
    var pix_n: u8 = y_rows.n[x];
    const pix_c_u: u8 = u_rows.c[xh];
    var pix_p_u: u8 = u_rows.p[xh];
    var pix_n_u: u8 = u_rows.n[xh];
    const pix_c_v: u8 = v_rows.c[xh];
    var pix_p_v: u8 = v_rows.p[xh];
    var pix_n_v: u8 = v_rows.n[xh];

    // CP/CN substitution: when averaged with C gives a lower score, use it.
    if (ivcp < ivp) {
        pix_p = pavgb(pix_c, pix_p);
        pix_p_u = pavgb(pix_c_u, pix_p_u);
        pix_p_v = pavgb(pix_c_v, pix_p_v);
        ivp = ivcp;
    }
    if (ivcn < ivn) {
        pix_n = pavgb(pix_c, pix_n);
        pix_n_u = pavgb(pix_c_u, pix_n_u);
        pix_n_v = pavgb(pix_c_v, pix_n_v);
        ivn = ivcn;
    }

    // Pick the lowest-iv candidate. Tie-breaks match upstream exactly.
    var iv: u8 = 0;
    var pick_y: u8 = undefined;
    var pick_u: u8 = undefined;
    var pick_v: u8 = undefined;
    if (ivn < ivp) {
        if (ivc < ivn) {
            pick_y = pix_c;
            pick_u = pix_c_u;
            pick_v = pix_c_v;
            iv = ivc;
        } else {
            pick_y = pix_n;
            pick_u = pix_n_u;
            pick_v = pix_n_v;
            iv = ivn;
        }
    } else {
        if (ivc < ivp) {
            pick_y = pix_c;
            pick_u = pix_c_u;
            pick_v = pix_c_v;
            iv = ivc;
        } else {
            pick_y = pix_p;
            pick_u = pix_p_u;
            pick_v = pix_p_v;
            iv = ivp;
        }
    }

    // Motion-gated override: at sufficiently high IV with high motion,
    // fall back to the vertical luma average and `pB` for chroma.
    const draw = iv > 8 and (pmMT[x] > 12 or pmMB[x] > 12);
    if (write_luma) {
        pD[x] = if (draw)
            @intCast((@as(u16, y_rows.t[x]) + @as(u16, y_rows.b[x])) >> 1)
        else
            pick_y;
    }
    if (write_chroma) {
        pD_U[xh] = if (draw) u_rows.b[xh] else pick_u;
        pD_V[xh] = if (draw) v_rows.b[xh] else pick_v;
    }
}

/// `Deinterlace_YV12` — diMode=1. The full Avisynth deinterlacer
/// (`reference/avisynth/src/di.cpp:2194`). For each pixel of the bottom-field
/// row, picks between C, P, N, avg(C,P) and avg(C,N) by minimum-IV score
/// across luma+chroma. Falls back to vertical average (T+B)/2 when the
/// motion map indicates strong motion AND the chosen score is high.
///
/// The caller must have pre-populated `motion4di` via
/// `makeMotionMap2Min(prev, curr, next)`.
///
/// Algorithm produces per-pixel:
///   bufC[x]  = max(luma_iv(pC, pT, pB),   chroma_iv broadcast for U,V)
///   bufP[x]  = max(luma_iv(pP, pT, pB),   chroma_iv for P U,V)
///   bufN[x]  = max(luma_iv(pN, pT, pB),   chroma_iv for N U,V)
///   bufCP[x] = max(luma_iv(avg(pC,pP), pT, pB), chroma_iv for avg)
///   bufCN[x] = max(luma_iv(avg(pC,pN), pT, pB), chroma_iv for avg)
/// then picks the smallest score's pixel.
pub fn deinterlace(
    width: i32,
    height: i32,
    motion4di: []const u8,
    dst: plane.PlaneViewMut,
    src_p: plane.PlaneView,
    src_c: plane.PlaneView,
    src_n: plane.PlaneView,
) void {
    const w: usize = @intCast(width);
    const h: usize = @intCast(height);
    std.debug.assert(motion4di.len == w * h);

    const row_y: usize = w;
    const row_uv: usize = w / 2;

    var yy: i32 = 0;
    while (yy < height) : (yy += 2) {
        // m_iField == 0 in the Avisynth original (it's never set elsewhere),
        // so `y = yy + 1` always.
        const y = yy + 1;

        const pT = plane.syp(src_c.y, src_c.y_stride, height, 0, y - 1);
        const pC = plane.syp(src_c.y, src_c.y_stride, height, 0, y);
        const pB = plane.syp(src_c.y, src_c.y_stride, height, 0, y + 1);
        const pP = plane.syp(src_p.y, src_p.y_stride, height, 0, y);
        const pN = plane.syp(src_n.y, src_n.y_stride, height, 0, y);
        const pT_U = plane.syp(src_c.u, src_c.u_stride, height, 1, y - 1);
        const pC_U = plane.syp(src_c.u, src_c.u_stride, height, 1, y);
        const pB_U = plane.syp(src_c.u, src_c.u_stride, height, 1, y + 1);
        const pP_U = plane.syp(src_p.u, src_p.u_stride, height, 1, y);
        const pN_U = plane.syp(src_n.u, src_n.u_stride, height, 1, y);
        const pT_V = plane.syp(src_c.v, src_c.v_stride, height, 2, y - 1);
        const pC_V = plane.syp(src_c.v, src_c.v_stride, height, 2, y);
        const pB_V = plane.syp(src_c.v, src_c.v_stride, height, 2, y + 1);
        const pP_V = plane.syp(src_p.v, src_p.v_stride, height, 2, y);
        const pN_V = plane.syp(src_n.v, src_n.v_stride, height, 2, y);

        const mT_row: usize = @intCast(plane.clipY(y - 1, height));
        const mB_row: usize = @intCast(plane.clipY(y + 1, height));
        const pmMT = motion4di[mT_row * w ..][0..w];
        const pmMB = motion4di[mB_row * w ..][0..w];

        // Top field (y_top = yy = y^1) just gets copied straight through —
        // upstream uses `memcpy(DYP(dst, y^1), SYP(srcC, y^1), width)`.
        const pD_top = plane.dyp(dst.y, dst.y_stride, height, 0, y ^ 1);
        const pSC_top = plane.syp(src_c.y, src_c.y_stride, height, 0, y ^ 1);
        @memcpy(pD_top[0..row_y], pSC_top[0..row_y]);
        if (@mod(y >> 1, 2) != 0) {
            const pD_top_U = plane.dyp(dst.u, dst.u_stride, height, 1, y ^ 1);
            const pSC_top_U = plane.syp(src_c.u, src_c.u_stride, height, 1, y ^ 1);
            const pD_top_V = plane.dyp(dst.v, dst.v_stride, height, 2, y ^ 1);
            const pSC_top_V = plane.syp(src_c.v, src_c.v_stride, height, 2, y ^ 1);
            @memcpy(pD_top_U[0..row_uv], pSC_top_U[0..row_uv]);
            @memcpy(pD_top_V[0..row_uv], pSC_top_V[0..row_uv]);
        }

        const pD = plane.dyp(dst.y, dst.y_stride, height, 0, y);
        const pD_U = plane.dyp(dst.u, dst.u_stride, height, 1, y);
        const pD_V = plane.dyp(dst.v, dst.v_stride, height, 2, y);

        const y_rows: Iv5Rows = .{ .t = pT, .c = pC, .b = pB, .p = pP, .n = pN };
        const u_rows: Iv5Rows = .{ .t = pT_U, .c = pC_U, .b = pB_U, .p = pP_U, .n = pN_U };
        const v_rows: Iv5Rows = .{ .t = pT_V, .c = pC_V, .b = pB_V, .p = pP_V, .n = pN_V };
        const chroma_row = @mod(y >> 1, 2) != 0;

        // SIMD body for luma: process LL pixels per iter. Chroma is kept
        // scalar (run in the same x-loop) because the upstream "last write
        // wins" pattern across pair-of-luma needs awkward mask sub-sampling
        // to replicate in SIMD; the chroma is half the data anyway.
        const LL = 32;
        const LC = LL / 2;
        const ivk_th: @Vector(LL, u8) = @splat(8);
        const motion_th: @Vector(LL, u8) = @splat(12);
        var xx: usize = 0;
        while (xx + LL <= w) : (xx += LL) {
            // Load luma planes
            const v_t = simd.load(LL, pT, xx);
            const v_c = simd.load(LL, pC, xx);
            const v_b = simd.load(LL, pB, xx);
            const v_p = simd.load(LL, pP, xx);
            const v_n = simd.load(LL, pN, xx);

            // Luma 5-score
            const ivc_l_v = ivKernelVec(LL, v_c, v_t, v_b);
            const ivp_l_v = ivKernelVec(LL, v_p, v_t, v_b);
            const ivn_l_v = ivKernelVec(LL, v_n, v_t, v_b);
            const cp_v = simd.pavgb(LL, v_c, v_p);
            const cn_v = simd.pavgb(LL, v_c, v_n);
            const ivcp_l_v = ivKernelVec(LL, cp_v, v_t, v_b);
            const ivcn_l_v = ivKernelVec(LL, cn_v, v_t, v_b);

            // Chroma scores: process LC chroma bytes for each plane
            const xhh = xx >> 1;
            const u_t = simd.load(LC, pT_U, xhh);
            const u_c = simd.load(LC, pC_U, xhh);
            const u_b = simd.load(LC, pB_U, xhh);
            const u_p = simd.load(LC, pP_U, xhh);
            const u_n = simd.load(LC, pN_U, xhh);
            const v_t_v = simd.load(LC, pT_V, xhh);
            const v_c_v = simd.load(LC, pC_V, xhh);
            const v_b_v = simd.load(LC, pB_V, xhh);
            const v_p_v = simd.load(LC, pP_V, xhh);
            const v_n_v = simd.load(LC, pN_V, xhh);

            const ivc_u_s = ivKernelVec(LC, u_c, u_t, u_b);
            const ivc_v_s = ivKernelVec(LC, v_c_v, v_t_v, v_b_v);
            const ivp_u_s = ivKernelVec(LC, u_p, u_t, u_b);
            const ivp_v_s = ivKernelVec(LC, v_p_v, v_t_v, v_b_v);
            const ivn_u_s = ivKernelVec(LC, u_n, u_t, u_b);
            const ivn_v_s = ivKernelVec(LC, v_n_v, v_t_v, v_b_v);
            const cp_u = simd.pavgb(LC, u_c, u_p);
            const cp_v_c = simd.pavgb(LC, v_c_v, v_p_v);
            const cn_u = simd.pavgb(LC, u_c, u_n);
            const cn_v_c = simd.pavgb(LC, v_c_v, v_n_v);
            const ivcp_u_s = ivKernelVec(LC, cp_u, u_t, u_b);
            const ivcp_v_s = ivKernelVec(LC, cp_v_c, v_t_v, v_b_v);
            const ivcn_u_s = ivKernelVec(LC, cn_u, u_t, u_b);
            const ivcn_v_s = ivKernelVec(LC, cn_v_c, v_t_v, v_b_v);

            // max(U, V) per chroma byte
            const ivc_uv_c = @max(ivc_u_s, ivc_v_s);
            const ivp_uv_c = @max(ivp_u_s, ivp_v_s);
            const ivn_uv_c = @max(ivn_u_s, ivn_v_s);
            const ivcp_uv_c = @max(ivcp_u_s, ivcp_v_s);
            const ivcn_uv_c = @max(ivcn_u_s, ivcn_v_s);

            // Broadcast chroma scores to luma pairs
            const ivc_uv_v = simd.expandPairs(LC, ivc_uv_c);
            const ivp_uv_v = simd.expandPairs(LC, ivp_uv_c);
            const ivn_uv_v = simd.expandPairs(LC, ivn_uv_c);
            const ivcp_uv_v = simd.expandPairs(LC, ivcp_uv_c);
            const ivcn_uv_v = simd.expandPairs(LC, ivcn_uv_c);

            // Combined luma+chroma per-pixel scores
            const ivc_v = @max(ivc_l_v, ivc_uv_v);
            var ivp_v_ = @max(ivp_l_v, ivp_uv_v);
            var ivn_v_ = @max(ivn_l_v, ivn_uv_v);
            const ivcp_v_ = @max(ivcp_l_v, ivcp_uv_v);
            const ivcn_v_ = @max(ivcn_l_v, ivcn_uv_v);

            // Candidate pixels (luma side)
            var pix_p_v = v_p;
            var pix_n_v = v_n;

            // CP / CN substitution: if averaged variant has lower iv, use it
            const use_cp: @Vector(LL, bool) = ivcp_v_ < ivp_v_;
            pix_p_v = @select(u8, use_cp, cp_v, pix_p_v);
            ivp_v_ = @select(u8, use_cp, ivcp_v_, ivp_v_);
            const use_cn: @Vector(LL, bool) = ivcn_v_ < ivn_v_;
            pix_n_v = @select(u8, use_cn, cn_v, pix_n_v);
            ivn_v_ = @select(u8, use_cn, ivcn_v_, ivn_v_);

            // Pick min(ivc, ivp, ivn) with the original tie-break semantics
            const n_lt_p: @Vector(LL, bool) = ivn_v_ < ivp_v_;
            const pix_np = @select(u8, n_lt_p, pix_n_v, pix_p_v);
            const iv_np = @select(u8, n_lt_p, ivn_v_, ivp_v_);
            const c_wins: @Vector(LL, bool) = ivc_v < iv_np;
            const result_no_motion = @select(u8, c_wins, v_c, pix_np);
            const final_iv = @select(u8, c_wins, ivc_v, iv_np);

            // Motion-gated vertical-average override
            const mt_v = simd.load(LL, pmMT.ptr, xx);
            const mb_v = simd.load(LL, pmMB.ptr, xx);
            const motion_high: @Vector(LL, bool) = (mt_v > motion_th) | (mb_v > motion_th);
            const iv_high: @Vector(LL, bool) = final_iv > ivk_th;
            const draw_mask = iv_high & motion_high;
            const vavg = simd.pavgb(LL, v_t, v_b);
            const result = @select(u8, draw_mask, vavg, result_no_motion);
            simd.store(LL, pD, xx, result);

            // Chroma writes: scalar to preserve upstream's "last write of
            // pair wins" semantics — adjacent xc values share the same xch
            // index and the second naturally overwrites the first.
            if (chroma_row) {
                var xc = xx;
                while (xc < xx + LL) : (xc += 1) {
                    deinterlacePixelScalar(false, true, xc, y_rows, u_rows, v_rows, pmMT, pmMB, pD, pD_U, pD_V);
                }
            }
        }

        // Scalar tail. Pick the per-row chroma mode via comptime branching
        // so the helper specialises into two tight no-chroma / with-chroma
        // bodies — comparable to the original separate-paths layout.
        if (chroma_row) {
            var x: usize = xx;
            while (x < w) : (x += 1) {
                deinterlacePixelScalar(true, true, x, y_rows, u_rows, v_rows, pmMT, pmMB, pD, pD_U, pD_V);
            }
        } else {
            var x: usize = xx;
            while (x < w) : (x += 1) {
                deinterlacePixelScalar(true, false, x, y_rows, u_rows, v_rows, pmMT, pmMB, pD, pD_U, pD_V);
            }
        }
    }
}

/// `SimpleBlur_YV12` — diMode=2. Vertical (top+2*center+bottom)/4 blur
/// applied only on pixels above a motion threshold, with a global "blur
/// everything" override when motion is widespread.
///
/// Ported from `reference/avisynth/src/di.cpp::SimpleBlur_YV12`. The caller
/// is responsible for having pre-populated `motion4di` via
/// `makeSimpleBlurMap`.
pub fn simpleBlur(
    width: i32,
    height: i32,
    motion4di: []const u8,
    dst: plane.PlaneViewMut,
    src: plane.PlaneView,
    ref: plane.PlaneView,
) void {
    const w: usize = @intCast(width);
    const h: usize = @intCast(height);
    std.debug.assert(motion4di.len == w * h);

    // Pass 1: count motion-tagged pixels to decide if we should blur every
    // pixel (when motion is widespread enough that selectivity hurts).
    var motion_hits: usize = 0;
    {
        const LANES = 32;
        const th_v: @Vector(LANES, u8) = @splat(4);
        const ones: @Vector(LANES, u8) = @splat(1);
        const zeros: @Vector(LANES, u8) = @splat(0);
        var y: i32 = 0;
        while (y < height) : (y += 1) {
            const row_off: usize = @intCast(plane.clipY(y, height));
            const row = motion4di[row_off * w ..][0..w];
            var x: usize = 0;
            while (x + LANES <= w) : (x += LANES) {
                const v = simd.load(LANES, row.ptr, x);
                const mask: @Vector(LANES, bool) = v > th_v;
                motion_hits += @reduce(.Add, @as(@Vector(LANES, u16), @select(u8, mask, ones, zeros)));
            }
            while (x < w) : (x += 1) {
                if (row[x] > 4) motion_hits += 1;
            }
        }
    }
    const all_pixel = motion_hits > (w * h) >> 1;

    // Pass 2: blur or copy per pixel.
    var y: i32 = 0;
    while (y < height) : (y += 1) {
        var pT: [*]const u8 = undefined;
        var pC: [*]const u8 = undefined;
        var pB: [*]const u8 = undefined;
        var pT_U: [*]const u8 = undefined;
        var pC_U: [*]const u8 = undefined;
        var pB_U: [*]const u8 = undefined;
        var pT_V: [*]const u8 = undefined;
        var pC_V: [*]const u8 = undefined;
        var pB_V: [*]const u8 = undefined;
        if (@rem(y, 2) != 0) {
            pT = plane.syp(src.y, src.y_stride, height, 0, y - 1);
            pC = plane.syp(ref.y, ref.y_stride, height, 0, y);
            pB = plane.syp(src.y, src.y_stride, height, 0, y + 1);
            pT_U = plane.syp(src.u, src.u_stride, height, 1, y - 1);
            pC_U = plane.syp(ref.u, ref.u_stride, height, 1, y);
            pB_U = plane.syp(src.u, src.u_stride, height, 1, y + 1);
            pT_V = plane.syp(src.v, src.v_stride, height, 2, y - 1);
            pC_V = plane.syp(ref.v, ref.v_stride, height, 2, y);
            pB_V = plane.syp(src.v, src.v_stride, height, 2, y + 1);
        } else {
            pT = plane.syp(ref.y, ref.y_stride, height, 0, y - 1);
            pC = plane.syp(src.y, src.y_stride, height, 0, y);
            pB = plane.syp(ref.y, ref.y_stride, height, 0, y + 1);
            pT_U = plane.syp(ref.u, ref.u_stride, height, 1, y - 1);
            pC_U = plane.syp(src.u, src.u_stride, height, 1, y);
            pB_U = plane.syp(ref.u, ref.u_stride, height, 1, y + 1);
            pT_V = plane.syp(ref.v, ref.v_stride, height, 2, y - 1);
            pC_V = plane.syp(src.v, src.v_stride, height, 2, y);
            pB_V = plane.syp(ref.v, ref.v_stride, height, 2, y + 1);
        }
        const m_row_off: usize = @intCast(plane.clipY(y, height));
        const pmMC = motion4di[m_row_off * w ..][0..w];
        const pD = plane.dyp(dst.y, dst.y_stride, height, 0, y);
        const pD_U = plane.dyp(dst.u, dst.u_stride, height, 1, y);
        const pD_V = plane.dyp(dst.v, dst.v_stride, height, 2, y);

        const SB_LANES = 16;
        // SIMD main path: process SB_LANES consecutive luma pixels at a time.
        // We avoid the SIMD body for x=0 and the trailing tail because the
        // overlap-loads of pmMC[x-1] / pmMC[x+SB_LANES] need both neighbours
        // to be in-row. Chroma writes are deferred to the scalar loop because
        // every second luma pixel overwrites the same chroma byte (upstream
        // quirk), and emulating that pattern in SIMD adds more complexity
        // than the chroma savings justify.
        var x: usize = 0;
        // Scalar prologue for x=0 only.
        if (w > 0) {
            const m_l: u8 = 0;
            const m_c: u8 = pmMC[0];
            const m_r: u8 = if (w > 1) pmMC[1] else 0;
            const do_blur = all_pixel or m_l > 12 or m_c > 12 or m_r > 12;
            if (do_blur) {
                pD[0] = @intCast((@as(u16, pT[0]) + @as(u16, pB[0]) + (@as(u16, pC[0]) << 1)) >> 2);
                if (@mod(y >> 1, 2) != 0) {
                    pD_U[0] = @intCast((@as(u16, pT_U[0]) + @as(u16, pB_U[0]) + (@as(u16, pC_U[0]) << 1)) >> 2);
                    pD_V[0] = @intCast((@as(u16, pT_V[0]) + @as(u16, pB_V[0]) + (@as(u16, pC_V[0]) << 1)) >> 2);
                }
            } else {
                pD[0] = pC[0];
                if (@mod(y >> 1, 2) != 0) {
                    pD_U[0] = pC_U[0];
                    pD_V[0] = pC_V[0];
                }
            }
            x = 1;
        }
        // SIMD body — bounds: m_l reads from x-1, m_r reads up to x+SB_LANES.
        // Both must stay within [0, w-1], so we need 1 <= x and x+SB_LANES <= w-1.
        const sb_th: @Vector(SB_LANES, u8) = @splat(12);
        while (x + SB_LANES + 1 <= w) : (x += SB_LANES) {
            const m_l = simd.load(SB_LANES, pmMC.ptr, x - 1);
            const m_c = simd.load(SB_LANES, pmMC.ptr, x);
            const m_r = simd.load(SB_LANES, pmMC.ptr, x + 1);
            const motion_mask: @Vector(SB_LANES, bool) =
                (m_l > sb_th) | (m_c > sb_th) | (m_r > sb_th);
            const blur_mask: @Vector(SB_LANES, bool) =
                motion_mask | @as(@Vector(SB_LANES, bool), @splat(all_pixel));

            const c = simd.load(SB_LANES, pC, x);
            const t = simd.load(SB_LANES, pT, x);
            const b = simd.load(SB_LANES, pB, x);
            const c16: @Vector(SB_LANES, u16) = c;
            const t16: @Vector(SB_LANES, u16) = t;
            const b16: @Vector(SB_LANES, u16) = b;
            const blur_u16 = (t16 + b16 + (c16 << @as(@Vector(SB_LANES, u4), @splat(1)))) >>
                @as(@Vector(SB_LANES, u4), @splat(2));
            const blur: @Vector(SB_LANES, u8) = @intCast(blur_u16);

            const result = @select(u8, blur_mask, blur, c);
            simd.store(SB_LANES, pD, x, result);

            // Chroma: re-run scalar for the corresponding pair-of-luma indices
            // so we preserve upstream's "second luma pixel of the pair wins"
            // behaviour for the chroma write.
            if (@mod(y >> 1, 2) != 0) {
                var xc = x;
                while (xc < x + SB_LANES) : (xc += 1) {
                    const ml: u8 = pmMC[xc - 1];
                    const mc: u8 = pmMC[xc];
                    const mr: u8 = pmMC[xc + 1];
                    const do_blur_c = all_pixel or ml > 12 or mc > 12 or mr > 12;
                    const xh = xc >> 1;
                    if (do_blur_c) {
                        pD_U[xh] = @intCast((@as(u16, pT_U[xh]) + @as(u16, pB_U[xh]) + (@as(u16, pC_U[xh]) << 1)) >> 2);
                        pD_V[xh] = @intCast((@as(u16, pT_V[xh]) + @as(u16, pB_V[xh]) + (@as(u16, pC_V[xh]) << 1)) >> 2);
                    } else {
                        pD_U[xh] = pC_U[xh];
                        pD_V[xh] = pC_V[xh];
                    }
                }
            }
        }
        // Scalar epilogue
        while (x < w) : (x += 1) {
            const m_l: u8 = if (x > 0) pmMC[x - 1] else 0;
            const m_c: u8 = pmMC[x];
            const m_r: u8 = if (x + 1 < w) pmMC[x + 1] else 0;
            const do_blur = all_pixel or m_l > 12 or m_c > 12 or m_r > 12;
            if (do_blur) {
                pD[x] = @intCast((@as(u16, pT[x]) + @as(u16, pB[x]) + (@as(u16, pC[x]) << 1)) >> 2);
                if (@mod(y >> 1, 2) != 0) {
                    const xh = x >> 1;
                    pD_U[xh] = @intCast((@as(u16, pT_U[xh]) + @as(u16, pB_U[xh]) + (@as(u16, pC_U[xh]) << 1)) >> 2);
                    pD_V[xh] = @intCast((@as(u16, pT_V[xh]) + @as(u16, pB_V[xh]) + (@as(u16, pC_V[xh]) << 1)) >> 2);
                }
            } else {
                pD[x] = pC[x];
                if (@mod(y >> 1, 2) != 0) {
                    const xh = x >> 1;
                    pD_U[xh] = pC_U[xh];
                    pD_V[xh] = pC_V[xh];
                }
            }
        }
    }
}

// ---------------------------------------------------------------------------
test "copyCPNField: identical src and ref produce identical output" {
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
    const dy = try std.testing.allocator.alloc(u8, w * h);
    defer std.testing.allocator.free(dy);
    const du = try std.testing.allocator.alloc(u8, (w / 2) * (h / 2));
    defer std.testing.allocator.free(du);
    const dv = try std.testing.allocator.alloc(u8, (w / 2) * (h / 2));
    defer std.testing.allocator.free(dv);

    var i: usize = 0;
    while (i < yp.len) : (i += 1) yp[i] = @intCast(i & 0xFF);
    @memset(up, 100);
    @memset(vp, 200);
    @memset(dy, 0);
    @memset(du, 0);
    @memset(dv, 0);

    const dst: plane.PlaneViewMut = .{ .y = dy.ptr, .y_stride = w, .u = du.ptr, .u_stride = w / 2, .v = dv.ptr, .v_stride = w / 2 };
    const view: plane.PlaneView = .{ .y = yp.ptr, .y_stride = w, .u = up.ptr, .u_stride = w / 2, .v = vp.ptr, .v_stride = w / 2 };
    copyCPNField(width, height, dst, view, view);

    // Y plane must equal src
    try std.testing.expectEqualSlices(u8, yp, dy);
    // U/V might only have chroma-rows where (yy/2)%2 == 1, others = 0
    // Verify rows 2-3 of chroma got copied (yy=4 -> chroma row 2-3)
    try std.testing.expectEqual(@as(u8, 100), du[2 * (w / 2) + 0]);
    try std.testing.expectEqual(@as(u8, 200), dv[2 * (w / 2) + 0]);
}

test "copyCPNField: bottom row uses ref, top row uses src" {
    const width: i32 = 16;
    const height: i32 = 8;
    const w: usize = @intCast(width);
    const h: usize = @intCast(height);
    const sy = try std.testing.allocator.alloc(u8, w * h);
    defer std.testing.allocator.free(sy);
    const ry = try std.testing.allocator.alloc(u8, w * h);
    defer std.testing.allocator.free(ry);
    const dy = try std.testing.allocator.alloc(u8, w * h);
    defer std.testing.allocator.free(dy);
    const uvb = try std.testing.allocator.alloc(u8, (w / 2) * (h / 2));
    defer std.testing.allocator.free(uvb);
    const uvr = try std.testing.allocator.alloc(u8, (w / 2) * (h / 2));
    defer std.testing.allocator.free(uvr);
    const duv = try std.testing.allocator.alloc(u8, (w / 2) * (h / 2));
    defer std.testing.allocator.free(duv);
    @memset(sy, 0xAA);
    @memset(ry, 0xBB);
    @memset(uvb, 0);
    @memset(uvr, 0);
    @memset(dy, 0);
    @memset(duv, 0);

    const dst: plane.PlaneViewMut = .{ .y = dy.ptr, .y_stride = w, .u = duv.ptr, .u_stride = w / 2, .v = duv.ptr, .v_stride = w / 2 };
    const src: plane.PlaneView = .{ .y = sy.ptr, .y_stride = w, .u = uvb.ptr, .u_stride = w / 2, .v = uvb.ptr, .v_stride = w / 2 };
    const ref: plane.PlaneView = .{ .y = ry.ptr, .y_stride = w, .u = uvr.ptr, .u_stride = w / 2, .v = uvr.ptr, .v_stride = w / 2 };
    copyCPNField(width, height, dst, src, ref);

    // Even rows (top fields) come from src (0xAA)
    try std.testing.expectEqual(@as(u8, 0xAA), dy[0 * w + 0]);
    try std.testing.expectEqual(@as(u8, 0xAA), dy[2 * w + 0]);
    // Odd rows (bottom fields) come from ref (0xBB)
    try std.testing.expectEqual(@as(u8, 0xBB), dy[1 * w + 0]);
    try std.testing.expectEqual(@as(u8, 0xBB), dy[3 * w + 0]);
}
