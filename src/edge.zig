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

const std = @import("std");
const plane = @import("plane.zig");

/// Absolute difference of two u8 values, returning u8.
inline fn absDiffU8(a: u8, b: u8) u8 {
    return if (a > b) a - b else b - a;
}

/// (b + c + 1) >> 1 in u16-precision intermediate, returning u8.
inline fn avgRound(b: u8, c: u8) u8 {
    return @intCast((@as(u16, b) + @as(u16, c) + 1) >> 1);
}

/// |center - (top + bot + 1)/2|, equivalent to `make_de_map_asm` in vs_it_c.cpp.
inline fn makeDeMapAsm(
    center: [*]const u8,
    top: [*]const u8,
    bot: [*]const u8,
    i: usize,
    step: usize,
    offset: usize,
) u8 {
    const idx = i * step + offset;
    const bc = avgRound(top[idx], bot[idx]);
    return absDiffU8(center[idx], bc);
}

/// `MakeDEmap_YV12` — produce an edge map into `edge_out` (size = width*height,
/// pre-zeroed by caller). Only rows `y = yy + offset` (yy = 0, 2, 4, ...) are
/// written; the others keep whatever value the caller left them at.
pub fn makeDeMap(
    width: i32,
    height: i32,
    offset: i32,
    edge_out: []u8,
    y_plane_base: [*]const u8,
    y_stride: usize,
    u_plane_base: [*]const u8,
    u_stride: usize,
    v_plane_base: [*]const u8,
    v_stride: usize,
) void {
    std.debug.assert(@as(usize, @intCast(width)) * @as(usize, @intCast(height)) == edge_out.len);
    const twidth: usize = @intCast(@divTrunc(width, 2));
    const w_usize: usize = @intCast(width);

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
        while (i < twidth) : (i += 1) {
            const ly = makeDeMapAsm(pC, pTT, pBB, i, 2, 0);
            const hy = makeDeMapAsm(pC, pTT, pBB, i, 2, 1);
            const lu = makeDeMapAsm(pC_U, pTT_U, pBB_U, i, 1, 0);
            const lv = makeDeMapAsm(pC_V, pTT_V, pBB_V, i, 1, 0);
            const uv = @max(lu, lv);
            pED[i * 2] = @max(uv, ly);
            pED[i * 2 + 1] = @max(uv, hy);
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

    makeDeMap(width, height, 0, edge,
        y_buf.ptr, w,
        u_buf.ptr, w / 2,
        v_buf.ptr, w / 2);

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
    makeDeMap(width, height, 0, edge,
        y_buf.ptr, w,
        u_buf.ptr, w / 2,
        v_buf.ptr, w / 2);

    // Row 6 sees top=row 4 (0), bot=row 8 (0): |200 - 0| = 200
    for (edge[6 * w .. 7 * w]) |e| try std.testing.expectEqual(@as(u8, 200), e);
    // Row 4 sees top=row 2 (0), bot=row 6 (200): |0 - 100| = 100
    for (edge[4 * w .. 5 * w]) |e| try std.testing.expectEqual(@as(u8, 100), e);
}
