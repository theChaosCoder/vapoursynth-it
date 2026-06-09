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
//! Generic over pixel storage `T` (u8/u16). Accumulators are u32 — each
//! output pixel is `Σ_z pS[z] · weight[z]`, and the weights sum to ~256
//! (total across the kernel, not 256 each), so the max is bounded by
//! ~65535·256 ≈ 16.8M — far within u32. The downscaling shift stays at 8
//! (weight fixed-point fractional bits) regardless of T.

const std = @import("std");
const plane = @import("plane.zig");
const MAX_WIDTH = plane.MAX_WIDTH;

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
        // blendFrames `@intCast`s each weight to u16 — guard the invariant
        // at the source so a future kernel change (sinc/Lanczos with
        // negative lobes, wider scale) surfaces here rather than as a
        // ReleaseFast trap on the cast site.
        std.debug.assert(v >= 0 and v <= std.math.maxInt(u16));
        k.weights[@intCast(i)] = v;
    }
    return k;
}

/// View of one source frame's three planes plus their strides. Generic so
/// callers can use `SourceView(u8)` or `SourceView(u16)`.
pub fn SourceView(comptime T: type) type {
    return plane.PlaneView(T);
}

/// Blend `size` source frames with the per-frame weights from `Kernel`.
/// Writes into `dst_*` planes. Caller is responsible for fetching the
/// MakeOutput()-ed reference frames and passing them via `srcs[0..size]`.
// Intentionally NOT `inline`: keeps the ~64 KB of accumulators below in
// blendFrames' own transient frame rather than the deeply-inlined getFrame
// frame (where they would coexist with makeMotionMap's scratch). The blend
// path is fps=24 + blend=true only, and the O(size·w·h) body dwarfs the call.
pub fn blendFrames(
    comptime T: type,
    comptime bits: u8,
    comptime cs: plane.ChromaSampling,
    width: i32,
    height: i32,
    kernel: Kernel,
    srcs: []const SourceView(T),
    dst_y: [*]T,
    dst_y_stride: usize,
    dst_u: [*]T,
    dst_u_stride: usize,
    dst_v: [*]T,
    dst_v_stride: usize,
) void {
    _ = bits;
    std.debug.assert(@as(usize, @intCast(kernel.size)) == srcs.len);
    std.debug.assert(width <= MAX_WIDTH);
    const w: usize = @intCast(width);
    const w_uv: usize = @intCast(plane.chromaWidth(cs, width));

    // Fixed at MAX_WIDTH (never reallocates); only the first `w`/`w_uv` are
    // used. Chroma buffers are full MAX_WIDTH so 4:4:4 (w_uv == w) fits.
    var buf_y: [MAX_WIDTH]u32 = undefined;
    var buf_u: [MAX_WIDTH]u32 = undefined;
    var buf_v: [MAX_WIDTH]u32 = undefined;

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
            const wt: u32 = @intCast(kernel.weights[z]);
            const pS = plane.syp(srcs[z].y, srcs[z].y_stride, height, 0, y);
            const pS_U = plane.sypChroma(cs, srcs[z].u, srcs[z].u_stride, height, y);
            const pS_V = plane.sypChroma(cs, srcs[z].v, srcs[z].v_stride, height, y);
            var x: usize = 0;
            while (x < w) : (x += 1) {
                buf_y[x] += @as(u32, pS[x]) * wt;
            }
            var xu: usize = 0;
            while (xu < w_uv) : (xu += 1) {
                buf_u[xu] += @as(u32, pS_U[xu]) * wt;
                buf_v[xu] += @as(u32, pS_V[xu]) * wt;
            }
        }

        const pD = plane.dyp(dst_y, dst_y_stride, height, 0, y);
        const pD_U = plane.dypChroma(cs, dst_u, dst_u_stride, height, y);
        const pD_V = plane.dypChroma(cs, dst_v, dst_v_stride, height, y);
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

test "blendFrames: identical sources -> output equals source (u8)" {
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
    const sv: SourceView(u8) = .{
        .y = yp.ptr,
        .y_stride = w,
        .u = up.ptr,
        .u_stride = w / 2,
        .v = vp.ptr,
        .v_stride = w / 2,
    };
    var sources = [_]SourceView(u8){ sv, sv, sv };
    blendFrames(u8, 8, .yuv420, width, height, k, sources[0..@intCast(k.size)], dy.ptr, w, du.ptr, w / 2, dv.ptr, w / 2);

    // With identical sources whose weights sum to ~256, the output should be
    // ~equal to the source (rounding may differ by 1 LSB).
    for (dy) |v| try std.testing.expect(@abs(@as(i32, v) - 100) <= 1);
    for (du) |v| try std.testing.expect(@abs(@as(i32, v) - 80) <= 1);
    for (dv) |v| try std.testing.expect(@abs(@as(i32, v) - 200) <= 1);
}

test "blendFrames 4:4:4: full-res chroma blends every sample (u8)" {
    // 4:4:4 chroma is full width*height. Every chroma sample must be blended
    // (no unwritten rows from a too-small buffer or 4:2:0 dyp interleave).
    const width: i32 = 16;
    const height: i32 = 8;
    const w: usize = @intCast(width);
    const h: usize = @intCast(height);
    const wh = w * h;

    const yp = try std.testing.allocator.alloc(u8, wh);
    defer std.testing.allocator.free(yp);
    const up = try std.testing.allocator.alloc(u8, wh); // full-res chroma
    defer std.testing.allocator.free(up);
    const vp = try std.testing.allocator.alloc(u8, wh);
    defer std.testing.allocator.free(vp);
    const dy = try std.testing.allocator.alloc(u8, wh);
    defer std.testing.allocator.free(dy);
    const du = try std.testing.allocator.alloc(u8, wh);
    defer std.testing.allocator.free(du);
    const dv = try std.testing.allocator.alloc(u8, wh);
    defer std.testing.allocator.free(dv);

    @memset(yp, 100);
    @memset(up, 80);
    @memset(vp, 200);
    @memset(dy, 0);
    @memset(du, 0);
    @memset(dv, 0);

    const k = buildKernel(0);
    const sv: SourceView(u8) = .{ .y = yp.ptr, .y_stride = w, .u = up.ptr, .u_stride = w, .v = vp.ptr, .v_stride = w };
    var sources = [_]SourceView(u8){ sv, sv, sv };
    blendFrames(u8, 8, .yuv444, width, height, k, sources[0..@intCast(k.size)], dy.ptr, w, du.ptr, w, dv.ptr, w);

    for (dy) |v| try std.testing.expect(@abs(@as(i32, v) - 100) <= 1);
    for (du) |v| try std.testing.expect(@abs(@as(i32, v) - 80) <= 1); // every sample
    for (dv) |v| try std.testing.expect(@abs(@as(i32, v) - 200) <= 1);
}

test "blendFrames 4:2:0: per-chroma-row gradient is row-preserved (identical sources)" {
    // Identical sources + integer kernel -> output == source. A per-row chroma
    // gradient means a read/write row-mapping bug (which uniform values hide)
    // would scramble the gradient. Guards the syp/dypChroma(cs) row addressing.
    const width: i32 = 16;
    const height: i32 = 16;
    const w: usize = @intCast(width);
    const h: usize = @intCast(height);
    const wh = w * h;
    const w_uv = w / 2;
    const h_uv = h / 2;
    const wh_uv = w_uv * h_uv;

    const yp = try std.testing.allocator.alloc(u8, wh);
    defer std.testing.allocator.free(yp);
    const up = try std.testing.allocator.alloc(u8, wh_uv);
    defer std.testing.allocator.free(up);
    const vp = try std.testing.allocator.alloc(u8, wh_uv);
    defer std.testing.allocator.free(vp);
    const du = try std.testing.allocator.alloc(u8, wh_uv);
    defer std.testing.allocator.free(du);
    const dv = try std.testing.allocator.alloc(u8, wh_uv);
    defer std.testing.allocator.free(dv);
    const dy = try std.testing.allocator.alloc(u8, wh);
    defer std.testing.allocator.free(dy);

    @memset(yp, 100);
    @memset(vp, 50);
    @memset(dy, 0);
    @memset(du, 0);
    @memset(dv, 0);
    // Vertical gradient in U: chroma row r holds 10 + r*20.
    var r: usize = 0;
    while (r < h_uv) : (r += 1) @memset(up[r * w_uv ..][0..w_uv], @intCast(10 + r * 20));

    const k = buildKernel(0);
    const sv: SourceView(u8) = .{ .y = yp.ptr, .y_stride = w, .u = up.ptr, .u_stride = w_uv, .v = vp.ptr, .v_stride = w_uv };
    var sources = [_]SourceView(u8){ sv, sv, sv };
    blendFrames(u8, 8, .yuv420, width, height, k, sources[0..@intCast(k.size)], dy.ptr, w, du.ptr, w_uv, dv.ptr, w_uv);

    // Each chroma row must come back as its own gradient value (row-preserving).
    r = 0;
    while (r < h_uv) : (r += 1) {
        const expected: i32 = @intCast(10 + r * 20);
        for (du[r * w_uv ..][0..w_uv]) |v| try std.testing.expect(@abs(@as(i32, v) - expected) <= 1);
    }
}

test "blendFrames: u16 path identical sources" {
    const width: i32 = 16;
    const height: i32 = 8;
    const w: usize = @intCast(width);
    const h: usize = @intCast(height);
    const wh = w * h;
    const wh_uv = (w / 2) * (h / 2);

    const yp = try std.testing.allocator.alloc(u16, wh);
    defer std.testing.allocator.free(yp);
    const up = try std.testing.allocator.alloc(u16, wh_uv);
    defer std.testing.allocator.free(up);
    const vp = try std.testing.allocator.alloc(u16, wh_uv);
    defer std.testing.allocator.free(vp);
    const dy = try std.testing.allocator.alloc(u16, wh);
    defer std.testing.allocator.free(dy);
    const du = try std.testing.allocator.alloc(u16, wh_uv);
    defer std.testing.allocator.free(du);
    const dv = try std.testing.allocator.alloc(u16, wh_uv);
    defer std.testing.allocator.free(dv);

    @memset(yp, 4000);
    @memset(up, 1000);
    @memset(vp, 60000);
    @memset(dy, 0);
    @memset(du, 0);
    @memset(dv, 0);

    const k = buildKernel(0);
    const sv: SourceView(u16) = .{
        .y = yp.ptr,
        .y_stride = w,
        .u = up.ptr,
        .u_stride = w / 2,
        .v = vp.ptr,
        .v_stride = w / 2,
    };
    var sources = [_]SourceView(u16){ sv, sv, sv };
    blendFrames(u16, 12, .yuv420, width, height, k, sources[0..@intCast(k.size)], dy.ptr, w, du.ptr, w / 2, dv.ptr, w / 2);

    for (dy) |v| try std.testing.expect(@abs(@as(i32, v) - 4000) <= 2);
    for (du) |v| try std.testing.expect(@abs(@as(i32, v) - 1000) <= 2);
    for (dv) |v| try std.testing.expect(@abs(@as(i32, v) - 60000) <= 2);
}
