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
//!
//! Generic over pixel storage `T` (u8/u16) and bit-depth `bits`. Map buffers
//! (motion2max, simple_blur, field_map_scratch, motion4di) stay u8; consumer
//! thresholds (12, 4, etc.) on those reads are 8-bit-calibrated regardless
//! of pixel depth. The IV-threshold (8) on pixel-diff IV scores scales as
//! `8 << (bits - 8)` so motion-override semantics track the bit-depth.

const std = @import("std");
const plane = @import("plane.zig");
const simd = @import("simd.zig");
const scalar = @import("scalar.zig");

/// Copies one row from src to dst (T-elements, not bytes). Wraps @memcpy
/// so call sites stay tidy.
inline fn bitblt(comptime T: type, dst: [*]T, src: [*]const T, row_size: usize) void {
    @memcpy(dst[0..row_size], src[0..row_size]);
}

/// Chroma row-size for `width`, **4:2:0-hardcoded** (`width / 2`).
///
/// Local to the output stage, which assumes 4:2:0 throughout (chroma indices
/// `>> 1`, the YV12 field-interleave in `plane.syp`, the `@mod(y>>1, 2)`
/// field gating, …). This is deliberately NOT `plane.chromaWidth(cs, …)`:
/// when 4:4:4 lands (Phase 2) the whole stage's chroma geometry should route
/// through `plane.ChromaSampling` together, not just this one call. Kept
/// distinct so the half-migrated state is obvious rather than a silent
/// divergence from the `cs`-aware helper of the same name.
inline fn chromaWidth(width: i32) i32 {
    return width >> 1;
}

/// `CopyCPNField`. `src` is the current frame; `ref` is the chosen reference
/// (= `src` when iUseFrame=='C', otherwise prev/next frame).
pub inline fn copyCPNField(
    comptime T: type,
    comptime bits: u8,
    width: i32,
    height: i32,
    dst: *const plane.PlaneViewMut(T),
    src: *const plane.PlaneView(T),
    ref: *const plane.PlaneView(T),
) void {
    _ = bits; // unused: pure copy / vertical average needs no bit-depth-scaled threshold; param kept for kernel-signature uniformity
    const row_y: usize = @intCast(width);
    const row_uv: usize = @intCast(chromaWidth(width));

    var yy: i32 = 0;
    while (yy < height) : (yy += 2) {
        const y = yy + 1;
        const yo = yy;
        // Y: top row from srcC, bottom from ref
        bitblt(T, plane.dyp(dst.y, dst.y_stride, height, 0, yo), plane.syp(src.y, src.y_stride, height, 0, yo), row_y);
        bitblt(T, plane.dyp(dst.y, dst.y_stride, height, 0, y), plane.syp(ref.y, ref.y_stride, height, 0, y), row_y);

        if (@mod(yy >> 1, 2) != 0) {
            bitblt(T, plane.dyp(dst.u, dst.u_stride, height, 1, yo), plane.syp(src.u, src.u_stride, height, 1, yo), row_uv);
            bitblt(T, plane.dyp(dst.u, dst.u_stride, height, 1, y), plane.syp(ref.u, ref.u_stride, height, 1, y), row_uv);
            bitblt(T, plane.dyp(dst.v, dst.v_stride, height, 2, yo), plane.syp(src.v, src.v_stride, height, 2, yo), row_uv);
            bitblt(T, plane.dyp(dst.v, dst.v_stride, height, 2, y), plane.syp(ref.v, ref.v_stride, height, 2, y), row_uv);
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
pub inline fn deintOneField(
    comptime T: type,
    comptime bits: u8,
    width: i32,
    height: i32,
    simple_blur: []const u8,
    motion2max: []const u8,
    field_map_scratch: []u8,
    dst: *const plane.PlaneViewMut(T),
    src: *const plane.PlaneView(T),
    ref: *const plane.PlaneView(T),
) void {
    _ = bits; // unused: pure copy / vertical average needs no bit-depth-scaled threshold; param kept for kernel-signature uniformity
    const w: usize = @intCast(width);
    const h: usize = @intCast(height);
    std.debug.assert(simple_blur.len == w * h);
    std.debug.assert(motion2max.len == w * h);
    std.debug.assert(field_map_scratch.len == w * h);

    @memset(field_map_scratch, 0);

    // Build the field map: pixels where both blur and motion2max are
    // "noticeably bright" along three columns get tagged. Map values are
    // u8 (downscaled at write time), so thresholds stay 8-bit literals.
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
        const pB = plane.syp(ref.y, ref.y_stride, height, 0, y + 1);
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

        // Read field_map with absolute offsets — see the long doc-comment
        // about upstream's spilling-pointer-arithmetic; we replicate it
        // bit-for-bit and clamp only the very-first and very-last bytes.
        const fm_at = struct {
            inline fn get(buf: []const u8, idx: isize, total: isize) u8 {
                if (idx < 0 or idx >= total) return 0;
                return buf[@intCast(idx)];
            }
        }.get;

        // SIMD lane count for luma — keep 256-bit width: 16 for u8, 8 for u16.
        const D_LANES: usize = 16 / @sizeOf(T);
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
            const blended: T = scalar.pavgb(pC[0], pBB[0]);
            pDB[0] = if (need_blend) blended else pB[0];
            if (@mod(y >> 1, 2) != 0) {
                pDB_U[x_half] = scalar.pavgb(pC_U[x_half], pBB_U[x_half]);
                pDB_V[x_half] = scalar.pavgb(pC_V[x_half], pBB_V[x_half]);
            }
            x = 1;
        }

        // SIMD body — bounds: m_l reads from x-1, m_r reads up to x+D_LANES.
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
            const result = @select(T, blend_mask, blended, b_v);
            simd.store(D_LANES, pDB, x, result);

            // Chroma is unconditional (no need_blend dependency) — always
            // the vertical pavgb. Process D_LANES/2 chroma samples per luma
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
            const blended: T = scalar.pavgb(pC[x], pBB[x]);
            pDB[x] = if (need_blend) blended else pB[x];

            if (@mod(y >> 1, 2) != 0) {
                pDB_U[x_half] = scalar.pavgb(pC_U[x_half], pBB_U[x_half]);
                pDB_V[x_half] = scalar.pavgb(pC_V[x_half], pBB_V[x_half]);
            }
        }
    }
}

/// Compact reimplementation of upstream's `eval_iv_asm` for one pixel.
/// Returns min(|a - b|, |a - c|, |a - (b+c+1)/2|). Used by `deinterlace`
/// and matches the DEINTERLACE_ASM_1 / DEINTERLACE_ASM_2 macros from the
/// Avisynth original.
inline fn ivKernel(comptime T: type, a: T, b: T, c: T) T {
    return @min(@min(scalar.absDiff(a, b), scalar.absDiff(a, c)), scalar.absDiff(a, scalar.pavgb(b, c)));
}

/// SIMD version of `ivKernel`. Returns the per-lane minimum of |a-b|,
/// |a-c| and |a - pavgb(b, c)| — the deinterlacer's interlace-evidence
/// metric, computed in parallel over `N` pixels.
inline fn ivKernelVec(comptime N: usize, a: anytype, b: @TypeOf(a), c: @TypeOf(a)) @TypeOf(a) {
    const ab = simd.absDiff(N, a, b);
    const ac = simd.absDiff(N, a, c);
    const bc = simd.pavgb(N, b, c);
    const a_bc = simd.absDiff(N, a, bc);
    return @min(@min(ab, ac), a_bc);
}

/// Five plane-row pointers sharing a T/C/B/P/N geometry — the source rows
/// the deinterlacer's per-pixel scalar kernel reads from. Built once per
/// outer (y) iteration so the inner loop can pass them in one struct each
/// for luma, U and V.
fn Iv5Rows(comptime T: type) type {
    return struct {
        t: [*]const T, // y - 1 (top, from current frame)
        c: [*]const T, // y     (center, from current frame)
        b: [*]const T, // y + 1 (bottom, from current frame)
        p: [*]const T, // y     (prev frame)
        n: [*]const T, // y     (next frame)
    };
}

/// Per-pixel scalar deinterlacer kernel. Computes the 5 IV scores
/// (C / P / N / avg(C,P) / avg(C,N)) for luma and chroma, picks the
/// best-scoring candidate, then applies the motion-gated vertical-average
/// override. Used by both the SIMD body's inner chroma loop and the
/// scalar tail of `deinterlace`.
///
/// `write_luma` / `write_chroma` are comptime: the SIMD body's chroma
/// loop calls with `write_luma=false` because luma is already written by
/// the SIMD store; the scalar tail's chroma rows call with both `true`.
///
/// IMPORTANT: chroma IV scores are computed UNCONDITIONALLY regardless of
/// `write_chroma`, because the combined luma+chroma `iv` is what drives
/// BOTH the luma pick and the motion-override gate. Do not "optimise"
/// away the chroma IV math when `write_chroma=false` — it will change the
/// luma output. `write_chroma` only gates the chroma WRITE, not the SCORE.
inline fn deinterlacePixelScalar(
    comptime T: type,
    comptime bits: u8,
    comptime write_luma: bool,
    comptime write_chroma: bool,
    x: usize,
    y_rows: Iv5Rows(T),
    u_rows: Iv5Rows(T),
    v_rows: Iv5Rows(T),
    pmMT: []const u8,
    pmMB: []const u8,
    pD: [*]T,
    pD_U: [*]T,
    pD_V: [*]T,
) void {
    const xh = x >> 1;
    const Wide = std.meta.Int(.unsigned, @bitSizeOf(T) * 2);
    const iv_th: T = comptime @intCast(@as(u32, 8) << @intCast(bits - 8));

    // Luma IV scores: C / P / N / avg(C,P) / avg(C,N) all against (T, B).
    const ivc_l = ivKernel(T, y_rows.c[x], y_rows.t[x], y_rows.b[x]);
    const ivp_l = ivKernel(T, y_rows.p[x], y_rows.t[x], y_rows.b[x]);
    const ivn_l = ivKernel(T, y_rows.n[x], y_rows.t[x], y_rows.b[x]);
    const ivcp_l = ivKernel(T, scalar.pavgb(y_rows.c[x], y_rows.p[x]), y_rows.t[x], y_rows.b[x]);
    const ivcn_l = ivKernel(T, scalar.pavgb(y_rows.c[x], y_rows.n[x]), y_rows.t[x], y_rows.b[x]);

    // Chroma U IV scores.
    const ivc_u = ivKernel(T, u_rows.c[xh], u_rows.t[xh], u_rows.b[xh]);
    const ivp_u = ivKernel(T, u_rows.p[xh], u_rows.t[xh], u_rows.b[xh]);
    const ivn_u = ivKernel(T, u_rows.n[xh], u_rows.t[xh], u_rows.b[xh]);
    const ivcp_u = ivKernel(T, scalar.pavgb(u_rows.c[xh], u_rows.p[xh]), u_rows.t[xh], u_rows.b[xh]);
    const ivcn_u = ivKernel(T, scalar.pavgb(u_rows.c[xh], u_rows.n[xh]), u_rows.t[xh], u_rows.b[xh]);

    // Chroma V IV scores.
    const ivc_v = ivKernel(T, v_rows.c[xh], v_rows.t[xh], v_rows.b[xh]);
    const ivp_v = ivKernel(T, v_rows.p[xh], v_rows.t[xh], v_rows.b[xh]);
    const ivn_v = ivKernel(T, v_rows.n[xh], v_rows.t[xh], v_rows.b[xh]);
    const ivcp_v = ivKernel(T, scalar.pavgb(v_rows.c[xh], v_rows.p[xh]), v_rows.t[xh], v_rows.b[xh]);
    const ivcn_v = ivKernel(T, scalar.pavgb(v_rows.c[xh], v_rows.n[xh]), v_rows.t[xh], v_rows.b[xh]);

    // Combine: max(U, V) chroma, then max with luma → unified score per
    // candidate that drives both the luma and chroma pick.
    const ivc: T = @max(ivc_l, @max(ivc_u, ivc_v));
    var ivp: T = @max(ivp_l, @max(ivp_u, ivp_v));
    var ivn: T = @max(ivn_l, @max(ivn_u, ivn_v));
    const ivcp: T = @max(ivcp_l, @max(ivcp_u, ivcp_v));
    const ivcn: T = @max(ivcn_l, @max(ivcn_u, ivcn_v));

    const pix_c: T = y_rows.c[x];
    var pix_p: T = y_rows.p[x];
    var pix_n: T = y_rows.n[x];
    const pix_c_u: T = u_rows.c[xh];
    var pix_p_u: T = u_rows.p[xh];
    var pix_n_u: T = u_rows.n[xh];
    const pix_c_v: T = v_rows.c[xh];
    var pix_p_v: T = v_rows.p[xh];
    var pix_n_v: T = v_rows.n[xh];

    // CP/CN substitution: when averaged with C gives a lower score, use it.
    if (ivcp < ivp) {
        pix_p = scalar.pavgb(pix_c, pix_p);
        pix_p_u = scalar.pavgb(pix_c_u, pix_p_u);
        pix_p_v = scalar.pavgb(pix_c_v, pix_p_v);
        ivp = ivcp;
    }
    if (ivcn < ivn) {
        pix_n = scalar.pavgb(pix_c, pix_n);
        pix_n_u = scalar.pavgb(pix_c_u, pix_n_u);
        pix_n_v = scalar.pavgb(pix_c_v, pix_n_v);
        ivn = ivcn;
    }

    // Pick the lowest-iv candidate. Tie-breaks match upstream exactly.
    var iv: T = 0;
    var pick_y: T = undefined;
    var pick_u: T = undefined;
    var pick_v: T = undefined;
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
    const draw = iv > iv_th and (pmMT[x] > 12 or pmMB[x] > 12);
    if (write_luma) {
        pD[x] = if (draw)
            @intCast((@as(Wide, y_rows.t[x]) + @as(Wide, y_rows.b[x])) >> 1)
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
pub inline fn deinterlace(
    comptime T: type,
    comptime bits: u8,
    width: i32,
    height: i32,
    motion4di: []const u8,
    dst: *const plane.PlaneViewMut(T),
    src_p: *const plane.PlaneView(T),
    src_c: *const plane.PlaneView(T),
    src_n: *const plane.PlaneView(T),
) void {
    const w: usize = @intCast(width);
    const h: usize = @intCast(height);
    std.debug.assert(motion4di.len == w * h);

    const row_y: usize = w;
    const row_uv: usize = w / 2;
    const Wide = std.meta.Int(.unsigned, @bitSizeOf(T) * 2);
    const ShiftT = std.math.Log2Int(Wide);
    const iv_th_val: T = comptime @intCast(@as(u32, 8) << @intCast(bits - 8));

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

        // Top field (y_top = yy = y^1) just gets copied straight through.
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

        const y_rows: Iv5Rows(T) = .{ .t = pT, .c = pC, .b = pB, .p = pP, .n = pN };
        const u_rows: Iv5Rows(T) = .{ .t = pT_U, .c = pC_U, .b = pB_U, .p = pP_U, .n = pN_U };
        const v_rows: Iv5Rows(T) = .{ .t = pT_V, .c = pC_V, .b = pB_V, .p = pP_V, .n = pN_V };
        const chroma_row = @mod(y >> 1, 2) != 0;

        // SIMD body for luma: 256-bit width = 32 u8 lanes / 16 u16 lanes per
        // luma block, chroma half.
        const LL: usize = 32 / @sizeOf(T);
        const LC = LL / 2;
        const ivk_th: @Vector(LL, T) = @splat(iv_th_val);
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

            // Chroma scores: process LC chroma samples for each plane
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
            pix_p_v = @select(T, use_cp, cp_v, pix_p_v);
            ivp_v_ = @select(T, use_cp, ivcp_v_, ivp_v_);
            const use_cn: @Vector(LL, bool) = ivcn_v_ < ivn_v_;
            pix_n_v = @select(T, use_cn, cn_v, pix_n_v);
            ivn_v_ = @select(T, use_cn, ivcn_v_, ivn_v_);

            // Pick min(ivc, ivp, ivn) with the original tie-break semantics
            const n_lt_p: @Vector(LL, bool) = ivn_v_ < ivp_v_;
            const pix_np = @select(T, n_lt_p, pix_n_v, pix_p_v);
            const iv_np = @select(T, n_lt_p, ivn_v_, ivp_v_);
            const c_wins: @Vector(LL, bool) = ivc_v < iv_np;
            const result_no_motion = @select(T, c_wins, v_c, pix_np);
            const final_iv = @select(T, c_wins, ivc_v, iv_np);

            // Motion-gated vertical-average override. Truncated (t+b)>>1
            // (matches Avisynth C upstream + scalar tail).
            const mt_v = simd.load(LL, pmMT.ptr, xx);
            const mb_v = simd.load(LL, pmMB.ptr, xx);
            const motion_high: @Vector(LL, bool) = (mt_v > motion_th) | (mb_v > motion_th);
            const iv_high: @Vector(LL, bool) = final_iv > ivk_th;
            const draw_mask = iv_high & motion_high;
            const vavg: @Vector(LL, T) = @intCast((@as(@Vector(LL, Wide), v_t) + @as(@Vector(LL, Wide), v_b)) >> @as(@Vector(LL, ShiftT), @splat(1)));
            const result = @select(T, draw_mask, vavg, result_no_motion);
            simd.store(LL, pD, xx, result);

            // Chroma writes: scalar to preserve upstream's "last write of
            // pair wins" semantics — adjacent xc values share the same xch
            // index and the second naturally overwrites the first.
            if (chroma_row) {
                var xc = xx;
                while (xc < xx + LL) : (xc += 1) {
                    deinterlacePixelScalar(T, bits, false, true, xc, y_rows, u_rows, v_rows, pmMT, pmMB, pD, pD_U, pD_V);
                }
            }
        }

        // Scalar tail.
        if (chroma_row) {
            var x: usize = xx;
            while (x < w) : (x += 1) {
                deinterlacePixelScalar(T, bits, true, true, x, y_rows, u_rows, v_rows, pmMT, pmMB, pD, pD_U, pD_V);
            }
        } else {
            var x: usize = xx;
            while (x < w) : (x += 1) {
                deinterlacePixelScalar(T, bits, true, false, x, y_rows, u_rows, v_rows, pmMT, pmMB, pD, pD_U, pD_V);
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
pub inline fn simpleBlur(
    comptime T: type,
    comptime bits: u8,
    width: i32,
    height: i32,
    motion4di: []const u8,
    dst: *const plane.PlaneViewMut(T),
    src: *const plane.PlaneView(T),
    ref: *const plane.PlaneView(T),
) void {
    _ = bits; // unused: pure copy / vertical average needs no bit-depth-scaled threshold; param kept for kernel-signature uniformity
    const w: usize = @intCast(width);
    const h: usize = @intCast(height);
    std.debug.assert(motion4di.len == w * h);
    const Wide = std.meta.Int(.unsigned, @bitSizeOf(T) * 2);
    const ShiftT = std.math.Log2Int(Wide);

    // Pass 1: count motion-tagged pixels in the u8 map. Threshold 4 stays.
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
        const tb = if (@rem(y, 2) != 0) src else ref;
        const ce = if (@rem(y, 2) != 0) ref else src;
        const pT = plane.syp(tb.y, tb.y_stride, height, 0, y - 1);
        const pC = plane.syp(ce.y, ce.y_stride, height, 0, y);
        const pB = plane.syp(tb.y, tb.y_stride, height, 0, y + 1);
        const pT_U = plane.syp(tb.u, tb.u_stride, height, 1, y - 1);
        const pC_U = plane.syp(ce.u, ce.u_stride, height, 1, y);
        const pB_U = plane.syp(tb.u, tb.u_stride, height, 1, y + 1);
        const pT_V = plane.syp(tb.v, tb.v_stride, height, 2, y - 1);
        const pC_V = plane.syp(ce.v, ce.v_stride, height, 2, y);
        const pB_V = plane.syp(tb.v, tb.v_stride, height, 2, y + 1);
        const m_row_off: usize = @intCast(plane.clipY(y, height));
        const pmMC = motion4di[m_row_off * w ..][0..w];
        const pD = plane.dyp(dst.y, dst.y_stride, height, 0, y);
        const pD_U = plane.dyp(dst.u, dst.u_stride, height, 1, y);
        const pD_V = plane.dyp(dst.v, dst.v_stride, height, 2, y);

        // 256-bit SIMD width = 16 u8 lanes / 8 u16 lanes for the blur body.
        const SB_LANES: usize = 16 / @sizeOf(T);
        var x: usize = 0;
        // Scalar prologue for x=0 only.
        if (w > 0) {
            const m_l: u8 = 0;
            const m_c: u8 = pmMC[0];
            const m_r: u8 = if (w > 1) pmMC[1] else 0;
            const do_blur = all_pixel or m_l > 12 or m_c > 12 or m_r > 12;
            if (do_blur) {
                pD[0] = @intCast((@as(Wide, pT[0]) + @as(Wide, pB[0]) + (@as(Wide, pC[0]) << 1)) >> 2);
                if (@mod(y >> 1, 2) != 0) {
                    pD_U[0] = @intCast((@as(Wide, pT_U[0]) + @as(Wide, pB_U[0]) + (@as(Wide, pC_U[0]) << 1)) >> 2);
                    pD_V[0] = @intCast((@as(Wide, pT_V[0]) + @as(Wide, pB_V[0]) + (@as(Wide, pC_V[0]) << 1)) >> 2);
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
            const c_w: @Vector(SB_LANES, Wide) = c;
            const t_w: @Vector(SB_LANES, Wide) = t;
            const b_w: @Vector(SB_LANES, Wide) = b;
            const blur_w = (t_w + b_w + (c_w << @as(@Vector(SB_LANES, ShiftT), @splat(1)))) >>
                @as(@Vector(SB_LANES, ShiftT), @splat(2));
            const blur: @Vector(SB_LANES, T) = @intCast(blur_w);

            const result = @select(T, blur_mask, blur, c);
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
                        pD_U[xh] = @intCast((@as(Wide, pT_U[xh]) + @as(Wide, pB_U[xh]) + (@as(Wide, pC_U[xh]) << 1)) >> 2);
                        pD_V[xh] = @intCast((@as(Wide, pT_V[xh]) + @as(Wide, pB_V[xh]) + (@as(Wide, pC_V[xh]) << 1)) >> 2);
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
                pD[x] = @intCast((@as(Wide, pT[x]) + @as(Wide, pB[x]) + (@as(Wide, pC[x]) << 1)) >> 2);
                if (@mod(y >> 1, 2) != 0) {
                    const xh = x >> 1;
                    pD_U[xh] = @intCast((@as(Wide, pT_U[xh]) + @as(Wide, pB_U[xh]) + (@as(Wide, pC_U[xh]) << 1)) >> 2);
                    pD_V[xh] = @intCast((@as(Wide, pT_V[xh]) + @as(Wide, pB_V[xh]) + (@as(Wide, pC_V[xh]) << 1)) >> 2);
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

    const dst: plane.PlaneViewMut(u8) = .{ .y = dy.ptr, .y_stride = w, .u = du.ptr, .u_stride = w / 2, .v = dv.ptr, .v_stride = w / 2 };
    const view: plane.PlaneView(u8) = .{ .y = yp.ptr, .y_stride = w, .u = up.ptr, .u_stride = w / 2, .v = vp.ptr, .v_stride = w / 2 };
    copyCPNField(u8, 8, width, height, &dst, &view, &view);

    try std.testing.expectEqualSlices(u8, yp, dy);
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
    const sub = try std.testing.allocator.alloc(u8, (w / 2) * (h / 2));
    defer std.testing.allocator.free(sub);
    const svb = try std.testing.allocator.alloc(u8, (w / 2) * (h / 2));
    defer std.testing.allocator.free(svb);
    const rub = try std.testing.allocator.alloc(u8, (w / 2) * (h / 2));
    defer std.testing.allocator.free(rub);
    const rvb = try std.testing.allocator.alloc(u8, (w / 2) * (h / 2));
    defer std.testing.allocator.free(rvb);
    const du = try std.testing.allocator.alloc(u8, (w / 2) * (h / 2));
    defer std.testing.allocator.free(du);
    const dv = try std.testing.allocator.alloc(u8, (w / 2) * (h / 2));
    defer std.testing.allocator.free(dv);
    @memset(sy, 0xAA);
    @memset(ry, 0xBB);
    @memset(sub, 0);
    @memset(svb, 0);
    @memset(rub, 0);
    @memset(rvb, 0);
    @memset(dy, 0);
    @memset(du, 0);
    @memset(dv, 0);

    const dst: plane.PlaneViewMut(u8) = .{ .y = dy.ptr, .y_stride = w, .u = du.ptr, .u_stride = w / 2, .v = dv.ptr, .v_stride = w / 2 };
    const src: plane.PlaneView(u8) = .{ .y = sy.ptr, .y_stride = w, .u = sub.ptr, .u_stride = w / 2, .v = svb.ptr, .v_stride = w / 2 };
    const ref: plane.PlaneView(u8) = .{ .y = ry.ptr, .y_stride = w, .u = rub.ptr, .u_stride = w / 2, .v = rvb.ptr, .v_stride = w / 2 };
    copyCPNField(u8, 8, width, height, &dst, &src, &ref);

    try std.testing.expectEqual(@as(u8, 0xAA), dy[0 * w + 0]);
    try std.testing.expectEqual(@as(u8, 0xAA), dy[2 * w + 0]);
    try std.testing.expectEqual(@as(u8, 0xBB), dy[1 * w + 0]);
    try std.testing.expectEqual(@as(u8, 0xBB), dy[3 * w + 0]);
}
