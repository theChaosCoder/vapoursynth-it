//! Edge / DE (difference-from-environment) map.
//!
//! Ported from `reference/vapoursynth-cpp/src/vs_it_c.cpp::MakeDEmap_YV12`.
//!
//! For each output pixel on every other row (y = yy + offset, yy even),
//! computes max( |Y - (Y_top2 + Y_bot2)/2|,
//!               |U - (U_top2 + U_bot2)/2|,
//!               |V - (V_top2 + V_bot2)/2| )
//! where top2/bot2 are the rows two scan lines above/below (= same field).
//! The result is an edge-strength map keyed by row.
//!
//! Generic over the pixel storage type `T` (u8 / u16). The edge map stays
//! u8 — for u16-storage paths the per-pixel diff is downscaled by
//! `bits - 8` so threshold semantics (40, 6) at the consumer stay
//! 8-bit-calibrated.

const std = @import("std");
const plane = @import("plane.zig");
const simd = @import("simd.zig");
const scalar = @import("scalar.zig");

/// |center - (top + bot + 1)/2|, equivalent to `make_de_map_asm` in vs_it_c.cpp.
/// T-typed result; caller is responsible for downscaling to u8 when writing
/// to the edge map.
inline fn makeDeMapAsm(
    comptime T: type,
    center: [*]const T,
    top: [*]const T,
    bot: [*]const T,
    i: usize,
    step: usize,
    offset: usize,
) T {
    const idx = i * step + offset;
    return scalar.absDiff(center[idx], scalar.pavgb(top[idx], bot[idx]));
}

/// `MakeDEmap_YV12` — produce an edge map into `edge_out` (size = width*height,
/// pre-zeroed by caller). Only rows `y = yy + offset` (yy = 0, 2, 4, ...) are
/// written; the others keep whatever value the caller left them at.
///
/// `T` is the pixel storage type (u8 / u16), `bits` is the actual bit-depth
/// (8/10/12/16). The map remains u8 — values are scaled-down to 8-bit range
/// before storing.
pub inline fn makeDeMap(
    comptime T: type,
    comptime bits: u8,
    width: i32,
    height: i32,
    offset: i32,
    edge_out: []u8,
    y_plane_base: [*]const T,
    y_stride: usize,
    u_plane_base: [*]const T,
    u_stride: usize,
    v_plane_base: [*]const T,
    v_stride: usize,
) void {
    std.debug.assert(@as(usize, @intCast(width)) * @as(usize, @intCast(height)) == edge_out.len);
    const twidth: usize = @intCast(@divTrunc(width, 2));
    const w_usize: usize = @intCast(width);

    // Keep 256-bit SIMD width: 32 u8 lanes per luma vector, 16 u8 chroma lanes;
    // halved at u16 (16 luma, 8 chroma) so each vector is still ~256 bits.
    const CL: usize = 16 / @sizeOf(T);

    var yy: i32 = 0;
    while (yy < height) : (yy += 2) {
        const y = yy + offset;

        const pTT = plane.syp(y_plane_base, y_stride, height, 0, y - 2);
        const pC = plane.syp(y_plane_base, y_stride, height, 0, y);
        const pBB = plane.syp(y_plane_base, y_stride, height, 0, y + 2);

        const pTT_U = plane.syp(u_plane_base, u_stride, height, 1, y - 2);
        const pC_U = plane.syp(u_plane_base, u_stride, height, 1, y);
        const pBB_U = plane.syp(u_plane_base, u_stride, height, 1, y + 2);

        const pTT_V = plane.syp(v_plane_base, v_stride, height, 2, y - 2);
        const pC_V = plane.syp(v_plane_base, v_stride, height, 2, y);
        const pBB_V = plane.syp(v_plane_base, v_stride, height, 2, y + 2);

        const row_offset: usize = @intCast(y);
        const pED = edge_out[row_offset * w_usize ..][0..w_usize];

        var i: usize = 0;
        while (i + CL <= twidth) : (i += CL) {
            const c_y = simd.load(CL * 2, pC, i * 2);
            const t_y = simd.load(CL * 2, pTT, i * 2);
            const b_y = simd.load(CL * 2, pBB, i * 2);
            const c_u = simd.load(CL, pC_U, i);
            const t_u = simd.load(CL, pTT_U, i);
            const b_u = simd.load(CL, pBB_U, i);
            const c_v = simd.load(CL, pC_V, i);
            const t_v = simd.load(CL, pTT_V, i);
            const b_v = simd.load(CL, pBB_V, i);

            const de_y = simd.absDiff(CL * 2, c_y, simd.pavgb(CL * 2, t_y, b_y));
            const de_u = simd.absDiff(CL, c_u, simd.pavgb(CL, t_u, b_u));
            const de_v = simd.absDiff(CL, c_v, simd.pavgb(CL, t_v, b_v));
            const de_uv = @max(de_u, de_v);
            const de_uv_expanded = simd.expandPairs(CL, de_uv);
            const result = @max(de_y, de_uv_expanded);
            const result_u8 = simd.toMapByteVec(T, bits, CL * 2, result);
            simd.store(CL * 2, pED.ptr, i * 2, result_u8);
        }
        // Scalar tail
        while (i < twidth) : (i += 1) {
            const ly = makeDeMapAsm(T, pC, pTT, pBB, i, 2, 0);
            const hy = makeDeMapAsm(T, pC, pTT, pBB, i, 2, 1);
            const lu = makeDeMapAsm(T, pC_U, pTT_U, pBB_U, i, 1, 0);
            const lv = makeDeMapAsm(T, pC_V, pTT_V, pBB_V, i, 1, 0);
            const uv = @max(lu, lv);
            pED[i * 2] = scalar.toMapByte(T, bits, @max(uv, ly));
            pED[i * 2 + 1] = scalar.toMapByte(T, bits, @max(uv, hy));
        }
    }
}

// ---------------------------------------------------------------------------
test "makeDeMap: uniform input produces zero edges" {
    const width = 32;
    const height = 16;
    const w: usize = width;
    const h: usize = height;

    const y_buf = try std.testing.allocator.alloc(u8, w * h);
    defer std.testing.allocator.free(y_buf);
    const u_buf = try std.testing.allocator.alloc(u8, (w / 2) * (h / 2));
    defer std.testing.allocator.free(u_buf);
    const v_buf = try std.testing.allocator.alloc(u8, (w / 2) * (h / 2));
    defer std.testing.allocator.free(v_buf);
    const edge = try std.testing.allocator.alloc(u8, w * h);
    defer std.testing.allocator.free(edge);

    @memset(y_buf, 128);
    @memset(u_buf, 100);
    @memset(v_buf, 100);
    @memset(edge, 0);

    makeDeMap(u8, 8, width, height, 0, edge, y_buf.ptr, w, u_buf.ptr, w / 2, v_buf.ptr, w / 2);

    for (edge) |e| try std.testing.expectEqual(@as(u8, 0), e);
}

test "makeDeMap: luma spike row produces edge in adjacent rows" {
    const width = 32;
    const height = 16;
    const w: usize = width;
    const h: usize = height;

    const y_buf = try std.testing.allocator.alloc(u8, w * h);
    defer std.testing.allocator.free(y_buf);
    const u_buf = try std.testing.allocator.alloc(u8, (w / 2) * (h / 2));
    defer std.testing.allocator.free(u_buf);
    const v_buf = try std.testing.allocator.alloc(u8, (w / 2) * (h / 2));
    defer std.testing.allocator.free(v_buf);
    const edge = try std.testing.allocator.alloc(u8, w * h);
    defer std.testing.allocator.free(edge);

    @memset(y_buf, 0);
    @memset(u_buf, 0);
    @memset(v_buf, 0);
    @memset(edge, 0);

    @memset(y_buf[6 * w .. 7 * w], 200);
    makeDeMap(u8, 8, width, height, 0, edge, y_buf.ptr, w, u_buf.ptr, w / 2, v_buf.ptr, w / 2);

    // Row 6 sees top=row 4 (0), bot=row 8 (0): |200 - 0| = 200
    for (edge[6 * w .. 7 * w]) |e| try std.testing.expectEqual(@as(u8, 200), e);
    // Row 4 sees top=row 2 (0), bot=row 6 (200): |0 - 100| = 100
    for (edge[4 * w .. 5 * w]) |e| try std.testing.expectEqual(@as(u8, 100), e);
}

test "makeDeMap: u16 path downscales to u8 map" {
    const width = 32;
    const height = 16;
    const w: usize = width;
    const h: usize = height;

    const y_buf = try std.testing.allocator.alloc(u16, w * h);
    defer std.testing.allocator.free(y_buf);
    const u_buf = try std.testing.allocator.alloc(u16, (w / 2) * (h / 2));
    defer std.testing.allocator.free(u_buf);
    const v_buf = try std.testing.allocator.alloc(u16, (w / 2) * (h / 2));
    defer std.testing.allocator.free(v_buf);
    const edge = try std.testing.allocator.alloc(u8, w * h);
    defer std.testing.allocator.free(edge);

    @memset(y_buf, 0);
    @memset(u_buf, 0);
    @memset(v_buf, 0);
    @memset(edge, 0);

    // 10-bit spike: 200 << 2 = 800. After downscale (>> 2): 200.
    @memset(y_buf[6 * w .. 7 * w], 800);
    makeDeMap(u16, 10, width, height, 0, edge, y_buf.ptr, w, u_buf.ptr, w / 2, v_buf.ptr, w / 2);

    for (edge[6 * w .. 7 * w]) |e| try std.testing.expectEqual(@as(u8, 200), e);
    for (edge[4 * w .. 5 * w]) |e| try std.testing.expectEqual(@as(u8, 100), e);
}
