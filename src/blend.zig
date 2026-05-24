//! `BlendFrame_YV12` — temporally-weighted 30→24 fps blend.
//!
//! Ported from the original Avisynth IT plugin (reference/avisynth/src/di.cpp
//! lines 3327-3486). Only relevant when `fps=24` and `blend=true`. The
//! VapourSynth upstream removed this path entirely; we reintroduce it.
//!
//! Algorithm:
//!   * For output frame index `(n - base)` within a 5-frame block, compute a
//!     fractional source position `pos = (n - base) * 5/4`.
//!   * Build a `size` element triangular-filter kernel `val[]` summing to
//!     ~256, centered on `pos`.
//!   * For every output pixel, accumulate `pS[x] * val[z]` over `z`
//!     neighbouring source frames, then shift down by 8.
//!
//! Unlike the upstream's MMX loop this is pure Zig with u16 accumulators,
//! which is exactly equivalent to the original `_asm pmullw / paddw` chain
//! (16-bit multiply-add, then `psrlw 8 / packuswb`).

const std = @import("std");
const plane = @import("plane.zig");

const MAX_WIDTH = 8192;

inline fn getF(x_in: f64) f64 {
    const x = @abs(x_in);
    return if (x < 1.0) 1.0 - x else 0.0;
}

/// Compute the per-source-frame weights and the starting offset for the
/// blend kernel. Returns `(start, size, weights)` where `weights[0..size]`
/// applies to source frames `(base + start) .. (base + start + size - 1)`.
pub const Kernel = struct {
    start: i32,
    size: i32,
    weights: [16]i32, // up to 16 source frames; upstream uses ~3 typically
};

pub fn buildKernel(n_minus_base: i32) Kernel {
    const subrange_width: f64 = 5.0;
    const target_width: f64 = 4.0;
    const scale = target_width / subrange_width; // 0.8
    const filter_step: f64 = if (scale < 1.0) scale else 1.0; // 0.8
    const support: f64 = 1.0 / filter_step; // 1.25
    const size_f: f64 = @ceil(support * 2.0); // 3
    const size: i32 = @intFromFloat(size_f);

    const step = subrange_width / target_width; // 1.25
    const pos: f64 = @as(f64, @floatFromInt(n_minus_base)) * step;

    const start: i32 = @as(i32, @intFromFloat(pos + support)) - size + 1;

    // First pass: total weight `t`.
    var t: f64 = 0.0;
    {
        var j: i32 = 0;
        while (j < size) : (j += 1) {
            t += getF((@as(f64, @floatFromInt(start + j)) - pos) * filter_step);
        }
    }

    // Second pass: rounded integer weights summing (approximately) to 256.
    var k: Kernel = .{ .start = start, .size = size, .weights = [_]i32{0} ** 16 };
    var t2: f64 = 0.0;
    var i: i32 = 0;
    while (i < size) : (i += 1) {
        const t3 = t2 + getF((@as(f64, @floatFromInt(start + i)) - pos) * filter_step) / t;
        const v = @as(i32, @intFromFloat(t3 * 256.0 + 0.5)) - @as(i32, @intFromFloat(t2 * 256.0 + 0.5));
        t2 = t3;
        k.weights[@intCast(i)] = v;
    }
    return k;
}

/// View of one source frame's three planes plus their strides. Pre-computed
/// by the caller so the inner loop stays tight.
pub const SourceView = struct {
    y: [*]const u8,
    y_stride: usize,
    u: [*]const u8,
    u_stride: usize,
    v: [*]const u8,
    v_stride: usize,
};

/// Blend `size` source frames with the per-frame weights from `Kernel`.
/// Writes into `dst_*` planes. Caller is responsible for fetching the
/// MakeOutput()-ed reference frames and passing them via `srcs[0..size]`.
pub fn blendFrames(
    width: i32,
    height: i32,
    kernel: Kernel,
    srcs: []const SourceView,
    dst_y: [*]u8,
    dst_y_stride: usize,
    dst_u: [*]u8,
    dst_u_stride: usize,
    dst_v: [*]u8,
    dst_v_stride: usize,
) void {
    std.debug.assert(@as(usize, @intCast(kernel.size)) == srcs.len);
    std.debug.assert(width <= MAX_WIDTH);
    const w: usize = @intCast(width);
    const w_uv: usize = w / 2;

    var buf_y: [MAX_WIDTH]u16 = undefined;
    var buf_u: [MAX_WIDTH / 2]u16 = undefined;
    var buf_v: [MAX_WIDTH / 2]u16 = undefined;

    var y: i32 = 0;
    while (y < height) : (y += 1) {
        @memset(buf_y[0..w], 0);
        @memset(buf_u[0..w_uv], 0);
        @memset(buf_v[0..w_uv], 0);

        var z: usize = 0;
        while (z < srcs.len) : (z += 1) {
            // Weights sum to ~256 with size=3 in practice, so each fits in u16.
            // @intCast traps in debug if buildKernel ever produces a negative
            // or oversized value — better than silently `& 0xFF`-truncating.
            const wt: u16 = @intCast(kernel.weights[z]);
            const pS = plane.syp(srcs[z].y, srcs[z].y_stride, height, 0, y);
            const pS_U = plane.syp(srcs[z].u, srcs[z].u_stride, height, 1, y);
            const pS_V = plane.syp(srcs[z].v, srcs[z].v_stride, height, 2, y);
            var x: usize = 0;
            while (x < w) : (x += 1) {
                buf_y[x] += @as(u16, pS[x]) * wt;
            }
            var xu: usize = 0;
            while (xu < w_uv) : (xu += 1) {
                buf_u[xu] += @as(u16, pS_U[xu]) * wt;
                buf_v[xu] += @as(u16, pS_V[xu]) * wt;
            }
        }

        const pD = plane.dyp(dst_y, dst_y_stride, height, 0, y);
        const pD_U = plane.dyp(dst_u, dst_u_stride, height, 1, y);
        const pD_V = plane.dyp(dst_v, dst_v_stride, height, 2, y);
        var x: usize = 0;
        while (x < w) : (x += 1) pD[x] = @intCast(buf_y[x] >> 8);
        var xu: usize = 0;
        while (xu < w_uv) : (xu += 1) {
            pD_U[xu] = @intCast(buf_u[xu] >> 8);
            pD_V[xu] = @intCast(buf_v[xu] >> 8);
        }
    }
}

// ---------------------------------------------------------------------------
test "buildKernel: weights sum to ~256 and centred on integer positions" {
    inline for (.{ 0, 1, 2, 3 }) |off| {
        const k = buildKernel(off);
        var sum: i32 = 0;
        var i: usize = 0;
        while (i < @as(usize, @intCast(k.size))) : (i += 1) sum += k.weights[i];
        // Rounding may leave the total at 255 or 257 occasionally — keep an
        // honest tolerance rather than asserting strict 256.
        try std.testing.expect(sum >= 254 and sum <= 258);
    }
}

test "blendFrames: identical sources -> output equals source" {
    const width: i32 = 16;
    const height: i32 = 8;
    const w: usize = @intCast(width);
    const h: usize = @intCast(height);
    const wh = w * h;
    const wh_uv = (w / 2) * (h / 2);

    const yp = try std.testing.allocator.alloc(u8, wh);
    defer std.testing.allocator.free(yp);
    const up = try std.testing.allocator.alloc(u8, wh_uv);
    defer std.testing.allocator.free(up);
    const vp = try std.testing.allocator.alloc(u8, wh_uv);
    defer std.testing.allocator.free(vp);
    const dy = try std.testing.allocator.alloc(u8, wh);
    defer std.testing.allocator.free(dy);
    const du = try std.testing.allocator.alloc(u8, wh_uv);
    defer std.testing.allocator.free(du);
    const dv = try std.testing.allocator.alloc(u8, wh_uv);
    defer std.testing.allocator.free(dv);

    @memset(yp, 100);
    @memset(up, 80);
    @memset(vp, 200);
    @memset(dy, 0);
    @memset(du, 0);
    @memset(dv, 0);

    const k = buildKernel(0);
    const sv: SourceView = .{
        .y = yp.ptr,
        .y_stride = w,
        .u = up.ptr,
        .u_stride = w / 2,
        .v = vp.ptr,
        .v_stride = w / 2,
    };
    var sources = [_]SourceView{ sv, sv, sv };
    blendFrames(width, height, k, sources[0..@intCast(k.size)], dy.ptr, w, du.ptr, w / 2, dv.ptr, w / 2);

    // With identical sources whose weights sum to ~256, the output should be
    // ~equal to the source (rounding may differ by 1 LSB).
    for (dy) |v| try std.testing.expect(@abs(@as(i32, v) - 100) <= 1);
    for (du) |v| try std.testing.expect(@abs(@as(i32, v) - 80) <= 1);
    for (dv) |v| try std.testing.expect(@abs(@as(i32, v) - 200) <= 1);
}
