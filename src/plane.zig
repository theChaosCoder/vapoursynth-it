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

/// SIMD chroma lane width used by the YV12 kernels in `edge.zig` and
/// `motion.zig`. Luma packs at 2× (32 lanes) since YV12 chroma is half-rate.
pub const CHROMA_LANES = 16;

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

pub fn clipYH(y: i32, height: i32) i32 {
    return @max(0, @min(@divTrunc(height, 2) - 1, y));
}

/// Source y-pointer. Given a plane base pointer, stride and logical row,
/// returns a pointer starting at the correct sample offset.
///
/// `plane == 0` (luma): one pointer per actual scan line.
/// `plane != 0` (chroma): upstream re-maps to `((y >> 2) << 1) + (y % 2)`,
///   i.e. four luma lines share two chroma rows (because of YV12 vertical
///   sub-sampling) AND chroma top/bottom fields are interleaved. The result
///   may look strange but it's exactly what upstream produces — and our
///   golden-frame oracle uses the same formula.
///
/// The `plane` argument is u32 for upstream-index parity (0=Y, 1=U, 2=V),
/// but internally only `plane == 0` vs `plane != 0` matters — U vs V is
/// distinguished entirely by the `base`/`stride` arguments. Callers MUST
/// pass the right base/stride for the plane they intend.
///
/// Generic via `anytype` on `base` — element type is inferred from the
/// pointer, return type matches. `stride` is in SAMPLES (T-elements) per
/// row, not bytes.
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
/// semantics — only `plane == 0` vs `plane != 0` is examined; U vs V is
/// distinguished by `base`/`stride`.
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

test "clipYH halves the height" {
    try std.testing.expectEqual(@as(i32, 239), clipYH(300, 480));
    try std.testing.expectEqual(@as(i32, 0), clipYH(-1, 480));
}

test "syp luma is just y * stride" {
    var buf = [_]u8{0} ** (480 * 720);
    buf[5 * 720 + 10] = 0xAA;
    const ptr = syp(@as([*]const u8, &buf), 720, 480, 0, 5);
    try std.testing.expectEqual(@as(u8, 0xAA), ptr[10]);
}

test "syp chroma uses ((y>>2)<<1)+(y%2) mapping" {
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
