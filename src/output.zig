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
    dst_y: [*]u8, dst_y_stride: usize,
    dst_u: [*]u8, dst_u_stride: usize,
    dst_v: [*]u8, dst_v_stride: usize,
    src_y: [*]const u8, src_y_stride: usize,
    src_u: [*]const u8, src_u_stride: usize,
    src_v: [*]const u8, src_v_stride: usize,
    ref_y: [*]const u8, ref_y_stride: usize,
    ref_u: [*]const u8, ref_u_stride: usize,
    ref_v: [*]const u8, ref_v_stride: usize,
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
            bitblt(plane.dyp(dst_u, dst_u_stride, height, 1, y),  plane.syp(ref_u, ref_u_stride, height, 1, y),  row_uv);
            bitblt(plane.dyp(dst_v, dst_v_stride, height, 2, yo), plane.syp(src_v, src_v_stride, height, 2, yo), row_uv);
            bitblt(plane.dyp(dst_v, dst_v_stride, height, 2, y),  plane.syp(ref_v, ref_v_stride, height, 2, y),  row_uv);
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
    dst_y: [*]u8, dst_y_stride: usize,
    dst_u: [*]u8, dst_u_stride: usize,
    dst_v: [*]u8, dst_v_stride: usize,
    src_y: [*]const u8, src_y_stride: usize,
    src_u: [*]const u8, src_u_stride: usize,
    src_v: [*]const u8, src_v_stride: usize,
    ref_y: [*]const u8, ref_y_stride: usize,
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
        const pFM = field_map_scratch[fm_row * w ..][0..w];
        const pFMB = field_map_scratch[fmB_row * w ..][0..w];

        var x: usize = 0;
        while (x < w) : (x += 1) {
            const x_half = x >> 1;
            // For x==0 the neighbours pFM[x-1] don't exist; upstream relies
            // on the field_map being zero-initialised and the inner loop
            // starts at x=1 so pFM[-1] reads zero from the byte just
            // before. We replicate by checking the bounds.
            const fm_l = if (x > 0) pFM[x - 1] else 0;
            const fm_c = pFM[x];
            const fm_r = if (x + 1 < w) pFM[x + 1] else 0;
            const fmB_l = if (x > 0) pFMB[x - 1] else 0;
            const fmB_c = pFMB[x];
            const fmB_r = if (x + 1 < w) pFMB[x + 1] else 0;
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

    copyCPNField(width, height,
        dy.ptr, w, du.ptr, w / 2, dv.ptr, w / 2,
        yp.ptr, w, up.ptr, w / 2, vp.ptr, w / 2,
        yp.ptr, w, up.ptr, w / 2, vp.ptr, w / 2);

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

    copyCPNField(width, height,
        dy.ptr, w, duv.ptr, w / 2, duv.ptr, w / 2,
        sy.ptr, w, uvb.ptr, w / 2, uvb.ptr, w / 2,
        ry.ptr, w, uvr.ptr, w / 2, uvr.ptr, w / 2);

    // Even rows (top fields) come from src (0xAA)
    try std.testing.expectEqual(@as(u8, 0xAA), dy[0 * w + 0]);
    try std.testing.expectEqual(@as(u8, 0xAA), dy[2 * w + 0]);
    // Odd rows (bottom fields) come from ref (0xBB)
    try std.testing.expectEqual(@as(u8, 0xBB), dy[1 * w + 0]);
    try std.testing.expectEqual(@as(u8, 0xBB), dy[3 * w + 0]);
}
