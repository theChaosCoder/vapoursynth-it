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
const motion = @import("motion.zig");

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
    dst_y: [*]u8,
    dst_y_stride: usize,
    dst_u: [*]u8,
    dst_u_stride: usize,
    dst_v: [*]u8,
    dst_v_stride: usize,
    src_y: [*]const u8,
    src_y_stride: usize,
    src_u: [*]const u8,
    src_u_stride: usize,
    src_v: [*]const u8,
    src_v_stride: usize,
    ref_y: [*]const u8,
    ref_y_stride: usize,
    ref_u: [*]const u8,
    ref_u_stride: usize,
    ref_v: [*]const u8,
    ref_v_stride: usize,
) void {
    const row_y: usize = @intCast(width);
    const row_uv: usize = @intCast(chromaWidth(width));

    var yy: i32 = 0;
    while (yy < height) : (yy += 2) {
        const y = yy + 1;
        const yo = yy;
        // Y: top row from srcC, bottom from ref
        bitblt(plane.dyp(dst_y, dst_y_stride, height, 0, yo), plane.syp(src_y, src_y_stride, height, 0, yo), row_y);
        bitblt(plane.dyp(dst_y, dst_y_stride, height, 0, y), plane.syp(ref_y, ref_y_stride, height, 0, y), row_y);

        if (@mod(yy >> 1, 2) != 0) {
            bitblt(plane.dyp(dst_u, dst_u_stride, height, 1, yo), plane.syp(src_u, src_u_stride, height, 1, yo), row_uv);
            bitblt(plane.dyp(dst_u, dst_u_stride, height, 1, y), plane.syp(ref_u, ref_u_stride, height, 1, y), row_uv);
            bitblt(plane.dyp(dst_v, dst_v_stride, height, 2, yo), plane.syp(src_v, src_v_stride, height, 2, yo), row_uv);
            bitblt(plane.dyp(dst_v, dst_v_stride, height, 2, y), plane.syp(ref_v, ref_v_stride, height, 2, y), row_uv);
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
    dst_y: [*]u8,
    dst_y_stride: usize,
    dst_u: [*]u8,
    dst_u_stride: usize,
    dst_v: [*]u8,
    dst_v_stride: usize,
    src_y: [*]const u8,
    src_y_stride: usize,
    src_u: [*]const u8,
    src_u_stride: usize,
    src_v: [*]const u8,
    src_v_stride: usize,
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
        const pC = plane.syp(src_y, src_y_stride, height, 0, y);
        const pB = plane.syp(ref_y, ref_y_stride, height, 0, y + 1);
        const pBB = plane.syp(src_y, src_y_stride, height, 0, y + 2);
        const pC_U = plane.syp(src_u, src_u_stride, height, 1, y);
        const pBB_U = plane.syp(src_u, src_u_stride, height, 1, y + 4);
        const pC_V = plane.syp(src_v, src_v_stride, height, 2, y);
        const pBB_V = plane.syp(src_v, src_v_stride, height, 2, y + 4);

        const pDC = plane.dyp(dst_y, dst_y_stride, height, 0, y);
        const pDB = plane.dyp(dst_y, dst_y_stride, height, 0, y + 1);
        const pDC_U = plane.dyp(dst_u, dst_u_stride, height, 1, y);
        const pDB_U = plane.dyp(dst_u, dst_u_stride, height, 1, y + 1);
        const pDC_V = plane.dyp(dst_v, dst_v_stride, height, 2, y);
        const pDB_V = plane.dyp(dst_v, dst_v_stride, height, 2, y + 1);

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

        var x: usize = 0;
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
    // Silence unused warnings
    _ = motion;
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

inline fn pavgb(a: u8, b: u8) u8 {
    return @intCast((@as(u16, a) + @as(u16, b) + 1) >> 1);
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
    dst_y: [*]u8,
    dst_y_stride: usize,
    dst_u: [*]u8,
    dst_u_stride: usize,
    dst_v: [*]u8,
    dst_v_stride: usize,
    src_p_y: [*]const u8,
    src_p_y_stride: usize,
    src_p_u: [*]const u8,
    src_p_u_stride: usize,
    src_p_v: [*]const u8,
    src_p_v_stride: usize,
    src_c_y: [*]const u8,
    src_c_y_stride: usize,
    src_c_u: [*]const u8,
    src_c_u_stride: usize,
    src_c_v: [*]const u8,
    src_c_v_stride: usize,
    src_n_y: [*]const u8,
    src_n_y_stride: usize,
    src_n_u: [*]const u8,
    src_n_u_stride: usize,
    src_n_v: [*]const u8,
    src_n_v_stride: usize,
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

        const pT = plane.syp(src_c_y, src_c_y_stride, height, 0, y - 1);
        const pC = plane.syp(src_c_y, src_c_y_stride, height, 0, y);
        const pB = plane.syp(src_c_y, src_c_y_stride, height, 0, y + 1);
        const pP = plane.syp(src_p_y, src_p_y_stride, height, 0, y);
        const pN = plane.syp(src_n_y, src_n_y_stride, height, 0, y);
        const pT_U = plane.syp(src_c_u, src_c_u_stride, height, 1, y - 1);
        const pC_U = plane.syp(src_c_u, src_c_u_stride, height, 1, y);
        const pB_U = plane.syp(src_c_u, src_c_u_stride, height, 1, y + 1);
        const pP_U = plane.syp(src_p_u, src_p_u_stride, height, 1, y);
        const pN_U = plane.syp(src_n_u, src_n_u_stride, height, 1, y);
        const pT_V = plane.syp(src_c_v, src_c_v_stride, height, 2, y - 1);
        const pC_V = plane.syp(src_c_v, src_c_v_stride, height, 2, y);
        const pB_V = plane.syp(src_c_v, src_c_v_stride, height, 2, y + 1);
        const pP_V = plane.syp(src_p_v, src_p_v_stride, height, 2, y);
        const pN_V = plane.syp(src_n_v, src_n_v_stride, height, 2, y);

        const mT_row: usize = @intCast(plane.clipY(y - 1, height));
        const mB_row: usize = @intCast(plane.clipY(y + 1, height));
        const pmMT = motion4di[mT_row * w ..][0..w];
        const pmMB = motion4di[mB_row * w ..][0..w];

        // Top field (y_top = yy = y^1) just gets copied straight through —
        // upstream uses `memcpy(DYP(dst, y^1), SYP(srcC, y^1), width)`.
        const pD_top = plane.dyp(dst_y, dst_y_stride, height, 0, y ^ 1);
        const pSC_top = plane.syp(src_c_y, src_c_y_stride, height, 0, y ^ 1);
        @memcpy(pD_top[0..row_y], pSC_top[0..row_y]);
        if (@mod(y >> 1, 2) != 0) {
            const pD_top_U = plane.dyp(dst_u, dst_u_stride, height, 1, y ^ 1);
            const pSC_top_U = plane.syp(src_c_u, src_c_u_stride, height, 1, y ^ 1);
            const pD_top_V = plane.dyp(dst_v, dst_v_stride, height, 2, y ^ 1);
            const pSC_top_V = plane.syp(src_c_v, src_c_v_stride, height, 2, y ^ 1);
            @memcpy(pD_top_U[0..row_uv], pSC_top_U[0..row_uv]);
            @memcpy(pD_top_V[0..row_uv], pSC_top_V[0..row_uv]);
        }

        const pD = plane.dyp(dst_y, dst_y_stride, height, 0, y);
        const pD_U = plane.dyp(dst_u, dst_u_stride, height, 1, y);
        const pD_V = plane.dyp(dst_v, dst_v_stride, height, 2, y);

        var x: usize = 0;
        while (x < w) : (x += 1) {
            const xh = x >> 1;

            // luma IV scores
            const ivc_l = ivKernel(pC[x], pT[x], pB[x]);
            const ivp_l = ivKernel(pP[x], pT[x], pB[x]);
            const ivn_l = ivKernel(pN[x], pT[x], pB[x]);
            const ivcp_l = ivKernel(pavgb(pC[x], pP[x]), pT[x], pB[x]);
            const ivcn_l = ivKernel(pavgb(pC[x], pN[x]), pT[x], pB[x]);

            // chroma IV scores: max of U and V, broadcast to both
            // luma pixels of the chroma sub-sample pair.
            const ivc_u = ivKernel(pC_U[xh], pT_U[xh], pB_U[xh]);
            const ivc_v = ivKernel(pC_V[xh], pT_V[xh], pB_V[xh]);
            const ivc_uv = @max(ivc_u, ivc_v);
            const ivp_u = ivKernel(pP_U[xh], pT_U[xh], pB_U[xh]);
            const ivp_v = ivKernel(pP_V[xh], pT_V[xh], pB_V[xh]);
            const ivp_uv = @max(ivp_u, ivp_v);
            const ivn_u = ivKernel(pN_U[xh], pT_U[xh], pB_U[xh]);
            const ivn_v = ivKernel(pN_V[xh], pT_V[xh], pB_V[xh]);
            const ivn_uv = @max(ivn_u, ivn_v);
            const ivcp_u = ivKernel(pavgb(pC_U[xh], pP_U[xh]), pT_U[xh], pB_U[xh]);
            const ivcp_v = ivKernel(pavgb(pC_V[xh], pP_V[xh]), pT_V[xh], pB_V[xh]);
            const ivcp_uv = @max(ivcp_u, ivcp_v);
            const ivcn_u = ivKernel(pavgb(pC_U[xh], pN_U[xh]), pT_U[xh], pB_U[xh]);
            const ivcn_v = ivKernel(pavgb(pC_V[xh], pN_V[xh]), pT_V[xh], pB_V[xh]);
            const ivcn_uv = @max(ivcn_u, ivcn_v);

            const ivc: u8 = @max(ivc_l, ivc_uv);
            var ivp: u8 = @max(ivp_l, ivp_uv);
            var ivn: u8 = @max(ivn_l, ivn_uv);
            const ivcp: u8 = @max(ivcp_l, ivcp_uv);
            const ivcn: u8 = @max(ivcn_l, ivcn_uv);

            var pix_c: u8 = pC[x];
            var pix_p: u8 = pP[x];
            var pix_n: u8 = pN[x];
            var pix_c_u: u8 = pC_U[xh];
            var pix_n_u: u8 = pN_U[xh];
            var pix_p_u: u8 = pP_U[xh];
            var pix_c_v: u8 = pC_V[xh];
            var pix_n_v: u8 = pN_V[xh];
            var pix_p_v: u8 = pP_V[xh];
            _ = &pix_c;
            _ = &pix_c_u;
            _ = &pix_c_v;

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

            var iv: u8 = 0;
            if (ivn < ivp) {
                if (ivc < ivn) {
                    pD[x] = pix_c;
                    iv = ivc;
                } else {
                    pD[x] = pix_n;
                    iv = ivn;
                }
            } else {
                if (ivc < ivp) {
                    pD[x] = pix_c;
                    iv = ivc;
                } else {
                    pD[x] = pix_p;
                    iv = ivp;
                }
            }

            // Motion-gated vertical-average override.
            const bDraw = iv > 8 and (pmMT[x] > 12 or pmMB[x] > 12);
            if (bDraw) {
                pD[x] = @intCast((@as(u16, pT[x]) + @as(u16, pB[x])) >> 1);
            }

            if (@mod(y >> 1, 2) != 0) {
                // chroma: same pick using the same iv scores, then same
                // motion-gated override (using pB_U/V instead of avg).
                if (ivn < ivp) {
                    if (ivc < ivn) {
                        pD_U[xh] = pix_c_u;
                        pD_V[xh] = pix_c_v;
                    } else {
                        pD_U[xh] = pix_n_u;
                        pD_V[xh] = pix_n_v;
                    }
                } else {
                    if (ivc < ivp) {
                        pD_U[xh] = pix_c_u;
                        pD_V[xh] = pix_c_v;
                    } else {
                        pD_U[xh] = pix_p_u;
                        pD_V[xh] = pix_p_v;
                    }
                }
                if (bDraw) {
                    pD_U[xh] = pB_U[xh];
                    pD_V[xh] = pB_V[xh];
                }
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
    dst_y: [*]u8,
    dst_y_stride: usize,
    dst_u: [*]u8,
    dst_u_stride: usize,
    dst_v: [*]u8,
    dst_v_stride: usize,
    src_y: [*]const u8,
    src_y_stride: usize,
    src_u: [*]const u8,
    src_u_stride: usize,
    src_v: [*]const u8,
    src_v_stride: usize,
    ref_y: [*]const u8,
    ref_y_stride: usize,
    ref_u: [*]const u8,
    ref_u_stride: usize,
    ref_v: [*]const u8,
    ref_v_stride: usize,
) void {
    const w: usize = @intCast(width);
    const h: usize = @intCast(height);
    std.debug.assert(motion4di.len == w * h);

    // Pass 1: count motion-tagged pixels to decide if we should blur every
    // pixel (when motion is widespread enough that selectivity hurts).
    var motion_hits: usize = 0;
    var y: i32 = 0;
    while (y < height) : (y += 1) {
        const row_off: usize = @intCast(plane.clipY(y, height));
        const row = motion4di[row_off * w ..][0..w];
        var x: usize = 0;
        while (x < w) : (x += 1) {
            if (row[x] > 4) motion_hits += 1;
        }
    }
    const all_pixel = motion_hits > (w * h) >> 1;

    // Pass 2: blur or copy per pixel.
    y = 0;
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
            pT = plane.syp(src_y, src_y_stride, height, 0, y - 1);
            pC = plane.syp(ref_y, ref_y_stride, height, 0, y);
            pB = plane.syp(src_y, src_y_stride, height, 0, y + 1);
            pT_U = plane.syp(src_u, src_u_stride, height, 1, y - 1);
            pC_U = plane.syp(ref_u, ref_u_stride, height, 1, y);
            pB_U = plane.syp(src_u, src_u_stride, height, 1, y + 1);
            pT_V = plane.syp(src_v, src_v_stride, height, 2, y - 1);
            pC_V = plane.syp(ref_v, ref_v_stride, height, 2, y);
            pB_V = plane.syp(src_v, src_v_stride, height, 2, y + 1);
        } else {
            pT = plane.syp(ref_y, ref_y_stride, height, 0, y - 1);
            pC = plane.syp(src_y, src_y_stride, height, 0, y);
            pB = plane.syp(ref_y, ref_y_stride, height, 0, y + 1);
            pT_U = plane.syp(ref_u, ref_u_stride, height, 1, y - 1);
            pC_U = plane.syp(src_u, src_u_stride, height, 1, y);
            pB_U = plane.syp(ref_u, ref_u_stride, height, 1, y + 1);
            pT_V = plane.syp(ref_v, ref_v_stride, height, 2, y - 1);
            pC_V = plane.syp(src_v, src_v_stride, height, 2, y);
            pB_V = plane.syp(ref_v, ref_v_stride, height, 2, y + 1);
        }
        const m_row_off: usize = @intCast(plane.clipY(y, height));
        const pmMC = motion4di[m_row_off * w ..][0..w];
        const pD = plane.dyp(dst_y, dst_y_stride, height, 0, y);
        const pD_U = plane.dyp(dst_u, dst_u_stride, height, 1, y);
        const pD_V = plane.dyp(dst_v, dst_v_stride, height, 2, y);

        var x: usize = 0;
        while (x < w) : (x += 1) {
            // Upstream's `pmMC[x-1]` and `pmMC[x+1]` overshoot the row at
            // x=0 / x=w-1; we clamp those reads to 0 here.
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

    copyCPNField(width, height, dy.ptr, w, du.ptr, w / 2, dv.ptr, w / 2, yp.ptr, w, up.ptr, w / 2, vp.ptr, w / 2, yp.ptr, w, up.ptr, w / 2, vp.ptr, w / 2);

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

    copyCPNField(width, height, dy.ptr, w, duv.ptr, w / 2, duv.ptr, w / 2, sy.ptr, w, uvb.ptr, w / 2, uvb.ptr, w / 2, ry.ptr, w, uvr.ptr, w / 2, uvr.ptr, w / 2);

    // Even rows (top fields) come from src (0xAA)
    try std.testing.expectEqual(@as(u8, 0xAA), dy[0 * w + 0]);
    try std.testing.expectEqual(@as(u8, 0xAA), dy[2 * w + 0]);
    // Odd rows (bottom fields) come from ref (0xBB)
    try std.testing.expectEqual(@as(u8, 0xBB), dy[1 * w + 0]);
    try std.testing.expectEqual(@as(u8, 0xBB), dy[3 * w + 0]);
}
