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

/// Result of EvalIV: how many pixels look interlaced (counter) and how
/// many "mildly interlaced" pixels (counterp, lower threshold).
pub const EvalResult = struct {
    counter: i64,
    counterp: i64,
};

/// EvalIV_YV12 — the caller passes:
///   * src_* : the "current" frame's planes
///   * ref_* : the reference frame's planes (P, C or N, depending on call)
///   * edge_map : same `width * height` buffer the caller pre-populated via
///       makeDeMap(..., offset = 1, ref_*) so that even-row edges land at
///       y = 1, 3, 5, ... in the map.
/// The function caps `counter` at `pthreshold` and bails early once it
/// crosses, matching upstream's optimisation.
pub fn evalIv(
    width: i32,
    height: i32,
    pthreshold: i32,
    edge_map: []const u8,
    src_y: [*]const u8, src_y_stride: usize,
    src_u: [*]const u8, src_u_stride: usize,
    src_v: [*]const u8, src_v_stride: usize,
    ref_y: [*]const u8, ref_y_stride: usize,
    ref_u: [*]const u8, ref_u_stride: usize,
    ref_v: [*]const u8, ref_v_stride: usize,
) EvalResult {
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
    // populate edge map for ref @ offset 1 — all zero with flat input.
    edge_mod.makeDeMap(width, height, 1, edge,
        yp.ptr, w, up.ptr, w / 2, vp.ptr, w / 2);

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
    edge_mod.makeDeMap(width, height, 1, edge,
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
    edge_mod.makeDeMap(width, height, 1, edge,
        yp.ptr, w, up.ptr, w / 2, vp.ptr, w / 2);

    const result = evalIv(width, height, 5, edge,
        yp.ptr, w, up.ptr, w / 2, vp.ptr, w / 2,
        yp.ptr, w, up.ptr, w / 2, vp.ptr, w / 2);
    try std.testing.expectEqual(@as(i64, 5), result.counter);
}
