//! Plane access helpers and small geometry utilities.
//!
//! The most important function is `syp` (source y-pointer) which maps a
//! logical pixel-row index into a pointer into the right field of a YV12
//! plane. The chroma case is unusual: it uses the upstream's interleaved
//! field-pair indexing `((y >> 2) << 1) + (y % 2)` which the original IT
//! plugin uses to address chroma rows in the field-matched output. We
//! preserve that bit-for-bit.

const std = @import("std");

/// Upstream's hard-coded clip-width ceiling for the per-row scratch buffers
/// in `motion.zig` and `blend.zig`. Anything wider is rejected in
/// `filter.validateInput`. Kept here so a future bump only touches one site.
pub const MAX_WIDTH = 8192;

/// Chroma subsampling layout, parameterized over two **independent axes** so
/// the YV12-designed kernels generalize to 4:2:2 and 4:4:4:
///   * `subW` (horizontal, subSamplingW): chroma is half-width — column
///     `x>>1`, half SIMD lanes (+ `simd.expandPairs`). True for 4:2:0, 4:2:2.
///   * `subH` (vertical, subSamplingH): chroma is half-height and
///     field-interleaved — the `((y>>2)<<1)+(y%2)` row mapping plus per-pair
///     write-gating. True only for 4:2:0.
/// So 4:2:2 is exactly "4:2:0 horizontal × 4:4:4 vertical". Routing every
/// chroma rate/index expression through these axes is what lets one code path
/// serve all three samplings.
///
/// WIRING IN PROGRESS — 4:4:4 first, then 4:2:2. Until `filter.validateInput`
/// accepts a non-4:2:0 sampling and the kernels thread `cs` through, only
/// 4:2:0 is reachable at runtime.
pub const ChromaSampling = enum {
    yuv420, // subSamplingW=1, subSamplingH=1
    yuv422, // subSamplingW=1, subSamplingH=0
    yuv444, // subSamplingW=0, subSamplingH=0
};

/// Horizontal chroma subsampling (`subSamplingW`): two adjacent luma columns
/// share one chroma sample. True for 4:2:0 and 4:2:2.
pub inline fn subW(comptime cs: ChromaSampling) bool {
    return cs != .yuv444;
}

/// Vertical chroma subsampling (`subSamplingH`): chroma is half-height and
/// field-interleaved. True only for 4:2:0.
pub inline fn subH(comptime cs: ChromaSampling) bool {
    return cs == .yuv420;
}

/// Chroma row count for a luma-pixel row count, given the sampling.
pub inline fn chromaHeight(comptime cs: ChromaSampling, height: i32) i32 {
    return if (subH(cs)) height >> 1 else height;
}

/// Chroma sample count per luma row, given the sampling.
pub inline fn chromaWidth(comptime cs: ChromaSampling, width: i32) i32 {
    return if (subW(cs)) width >> 1 else width;
}

/// Map a luma column index to the chroma column index for the same pixel.
/// With horizontal subsampling two adjacent luma pixels share one chroma
/// sample; otherwise each luma pixel has its own.
pub inline fn chromaCol(comptime cs: ChromaSampling, x: usize) usize {
    return if (subW(cs)) x >> 1 else x;
}

/// SIMD chroma lane count per `luma_lanes`, given the sampling. With
/// horizontal subsampling the chroma vector is half the luma vector;
/// otherwise it matches.
pub inline fn chromaLanesOf(comptime cs: ChromaSampling, comptime luma_lanes: usize) usize {
    return if (subW(cs)) luma_lanes / 2 else luma_lanes;
}

/// Read-only view of one frame's Y/U/V plane base pointers + strides.
/// Used by `filter.zig` to pass extracted plane geometry into the algorithm
/// modules in one struct instead of six separate parameters per frame.
///
/// Generic over the pixel storage type `T`. Use `PlaneView(u8)` for 8-bit
/// pipelines and `PlaneView(u16)` for 10/12/16-bit pipelines (VS stores
/// >8-bit integer samples in u16 with the upper bits zero). Strides are in
/// samples (T-elements per row), not bytes; `filter.viewOf` converts the
/// byte stride VS returns to sample stride at construction time.
pub fn PlaneView(comptime T: type) type {
    return struct {
        y: [*]const T,
        y_stride: usize,
        u: [*]const T,
        u_stride: usize,
        v: [*]const T,
        v_stride: usize,
    };
}

/// Writable counterpart to `PlaneView(T)` for destination frames.
pub fn PlaneViewMut(comptime T: type) type {
    return struct {
        y: [*]T,
        y_stride: usize,
        u: [*]T,
        u_stride: usize,
        v: [*]T,
        v_stride: usize,
    };
}

/// Adjusts a parameter relative to a 720x480 (NTSC) reference resolution.
///
/// Used by upstream to scale thresholds for clips of different sizes. The
/// formula is `((v * width) / 720) * height / 480` — note the truncation
/// order, which yields different results from one big expression.
pub fn adjPara(v: i32, width: i32, height: i32) i32 {
    return @divTrunc(@divTrunc(v * width, 720) * height, 480);
}

pub fn clipFrame(n: i32, max_frames: i32) i32 {
    return @max(0, @min(n, max_frames - 1));
}

pub fn clipX(x: i32, width: i32) i32 {
    return @max(0, @min(width - 1, x));
}

pub fn clipY(y: i32, height: i32) i32 {
    return @max(0, @min(height - 1, y));
}

/// Source y-pointer. Given a plane base pointer, stride and logical row,
/// returns a pointer starting at the correct sample offset.
///
/// `plane == 0` (luma): one pointer per actual scan line.
/// `plane != 0` (chroma): YV12 mapping `((y >> 2) << 1) + (y % 2)` —
///   four luma lines share two chroma rows AND chroma top/bottom fields
///   are interleaved. Bit-for-bit upstream behaviour for 4:2:0.
///
/// 4:4:4 callers must use `sypChroma(.yuv444, ...)` for chroma; calling
/// `syp` with `plane != 0` always applies the YV12 mapping.
///
/// `stride` is in SAMPLES per row, not bytes.
pub fn syp(
    base: anytype,
    stride: usize,
    height: i32,
    plane: u32,
    y: i32,
) @TypeOf(base) {
    const yi = clipY(y, height);
    const row: usize = if (plane == 0)
        @intCast(yi)
    else
        @intCast(((yi >> 2) << 1) + @rem(yi, 2));
    return base + row * stride;
}

/// Destination y-pointer (mutable counterpart to `syp`). Same plane-index
/// semantics — only `plane == 0` vs `plane != 0` is examined.
pub fn dyp(
    base: anytype,
    stride: usize,
    height: i32,
    plane: u32,
    y: i32,
) @TypeOf(base) {
    const yi = clipY(y, height);
    const row: usize = if (plane == 0)
        @intCast(yi)
    else
        @intCast(((yi >> 2) << 1) + @rem(yi, 2));
    return base + row * stride;
}

/// Subsampling-aware source y-pointer for chroma planes. With vertical
/// subsampling (4:2:0) it uses the YV12 field-interleaved mapping; without
/// it (4:2:2 / 4:4:4) chroma rows match luma rows 1-to-1. Use this from
/// chroma-aware kernels that need to support all samplings.
pub fn sypChroma(
    comptime cs: ChromaSampling,
    base: anytype,
    stride: usize,
    height: i32,
    y: i32,
) @TypeOf(base) {
    const yi = clipY(y, height);
    const row: usize = if (subH(cs))
        @intCast(((yi >> 2) << 1) + @rem(yi, 2))
    else
        @intCast(yi);
    return base + row * stride;
}

/// Mutable counterpart to `sypChroma`.
pub fn dypChroma(
    comptime cs: ChromaSampling,
    base: anytype,
    stride: usize,
    height: i32,
    y: i32,
) @TypeOf(base) {
    const yi = clipY(y, height);
    const row: usize = if (subH(cs))
        @intCast(((yi >> 2) << 1) + @rem(yi, 2))
    else
        @intCast(yi);
    return base + row * stride;
}

// ---------------------------------------------------------------------------
test "adjPara default 720x480 is identity" {
    try std.testing.expectEqual(@as(i32, 50), adjPara(50, 720, 480));
    try std.testing.expectEqual(@as(i32, 75), adjPara(75, 720, 480));
}

test "adjPara scales linearly per-axis with truncation" {
    // adjPara(50, 1440, 480) = ((50 * 1440) / 720) * 480 / 480 = 100
    try std.testing.expectEqual(@as(i32, 100), adjPara(50, 1440, 480));
    // adjPara(50, 720, 960) = ((50 * 720) / 720) * 960 / 480 = 100
    try std.testing.expectEqual(@as(i32, 100), adjPara(50, 720, 960));
}

test "clipFrame clamps to [0, max-1]" {
    try std.testing.expectEqual(@as(i32, 0), clipFrame(-5, 100));
    try std.testing.expectEqual(@as(i32, 99), clipFrame(150, 100));
    try std.testing.expectEqual(@as(i32, 42), clipFrame(42, 100));
}

test "clipX / clipY clamp" {
    try std.testing.expectEqual(@as(i32, 0), clipX(-1, 720));
    try std.testing.expectEqual(@as(i32, 719), clipX(720, 720));
    try std.testing.expectEqual(@as(i32, 479), clipY(500, 480));
}

test "syp luma is just y * stride" {
    var buf = [_]u8{0} ** (480 * 720);
    buf[5 * 720 + 10] = 0xAA;
    const ptr = syp(@as([*]const u8, &buf), 720, 480, 0, 5);
    try std.testing.expectEqual(@as(u8, 0xAA), ptr[10]);
}

test "syp chroma uses ((y>>2)<<1)+(y%2) mapping for 4:2:0" {
    // For y=4 in chroma: ((4>>2)<<1) + (4%2) = 2 + 0 = row 2
    // For y=5 in chroma: ((5>>2)<<1) + (5%2) = 2 + 1 = row 3
    // For y=7 in chroma: ((7>>2)<<1) + (7%2) = 2 + 1 = row 3
    // For y=8 in chroma: ((8>>2)<<1) + (8%2) = 4 + 0 = row 4
    var buf = [_]u8{0} ** (240 * 360);
    buf[2 * 360 + 0] = 0x11;
    buf[3 * 360 + 0] = 0x22;
    buf[4 * 360 + 0] = 0x33;
    const ptr: [*]const u8 = &buf;
    try std.testing.expectEqual(@as(u8, 0x11), syp(ptr, 360, 480, 1, 4)[0]);
    try std.testing.expectEqual(@as(u8, 0x22), syp(ptr, 360, 480, 1, 5)[0]);
    try std.testing.expectEqual(@as(u8, 0x22), syp(ptr, 360, 480, 1, 7)[0]);
    try std.testing.expectEqual(@as(u8, 0x33), syp(ptr, 360, 480, 1, 8)[0]);
}

test "sypChroma 4:2:0 matches syp(plane!=0)" {
    var buf = [_]u8{0} ** (240 * 360);
    buf[2 * 360 + 0] = 0x11;
    buf[3 * 360 + 0] = 0x22;
    const ptr: [*]const u8 = &buf;
    try std.testing.expectEqual(@as(u8, 0x11), sypChroma(.yuv420, ptr, 360, 480, 4)[0]);
    try std.testing.expectEqual(@as(u8, 0x22), sypChroma(.yuv420, ptr, 360, 480, 5)[0]);
}

test "sypChroma 4:4:4 maps row 1-to-1 with luma" {
    var buf = [_]u8{0} ** (480 * 720);
    buf[5 * 720 + 10] = 0xCC;
    const ptr: [*]const u8 = &buf;
    // 4:4:4: chroma row = luma row, no interleave.
    try std.testing.expectEqual(@as(u8, 0xCC), sypChroma(.yuv444, ptr, 720, 480, 5)[10]);
}

test "sypChroma 4:2:2 maps row 1-to-1 with luma (full height, no interleave)" {
    var buf = [_]u8{0} ** (480 * 720);
    buf[5 * 720 + 10] = 0xCC;
    const ptr: [*]const u8 = &buf;
    // 4:2:2 is vertically full-rate, so chroma row = luma row like 4:4:4.
    try std.testing.expectEqual(@as(u8, 0xCC), sypChroma(.yuv422, ptr, 720, 480, 5)[10]);
}

test "chroma axes: subW/subH and rates per sampling" {
    // Horizontal subsampling for 4:2:0 and 4:2:2, not 4:4:4.
    try std.testing.expect(subW(.yuv420) and subW(.yuv422) and !subW(.yuv444));
    // Vertical subsampling only for 4:2:0.
    try std.testing.expect(subH(.yuv420) and !subH(.yuv422) and !subH(.yuv444));
    // Width halved iff subW; height halved iff subH.
    try std.testing.expectEqual(@as(i32, 360), chromaWidth(.yuv420, 720));
    try std.testing.expectEqual(@as(i32, 360), chromaWidth(.yuv422, 720));
    try std.testing.expectEqual(@as(i32, 720), chromaWidth(.yuv444, 720));
    try std.testing.expectEqual(@as(i32, 240), chromaHeight(.yuv420, 480));
    try std.testing.expectEqual(@as(i32, 480), chromaHeight(.yuv422, 480));
    try std.testing.expectEqual(@as(i32, 480), chromaHeight(.yuv444, 480));
}
