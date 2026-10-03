//! VapourSynth plugin entry point for `zit` — Zig port of VapourSynth-IT.
//!
//! This file is intentionally tiny: it registers the plugin and the `IT`
//! function under namespace `zit`. The actual filter implementation lives
//! in `filter.zig` and the algorithm primitives in their own sibling files.

const std = @import("std");
const vapoursynth = @import("vapoursynth");
const vs = vapoursynth.vapoursynth4;
const ZAPI = vapoursynth.ZAPI;
const filter = @import("filter.zig");

const PLUGIN_ID = "com.thechaoscoder.zit";
const PLUGIN_NAMESPACE = "zit";
const PLUGIN_NAME = "VapourSynth IVTC Filter (Zig port)";
const PLUGIN_VERSION = std.SemanticVersion{ .major = 1, .minor = 4, .patch = 0 };

comptime {
    // Enforce the R55 minimum for native, test, and cross builds alike.
    if (vs.VAPOURSYNTH_API_VERSION != (4 << 16))
        @compileError("zit must target VapourSynth API 4.0 (R55)");
}

export fn VapourSynthPluginInit2(plugin: *vs.Plugin, vspapi: *const vs.PLUGINAPI) void {
    ZAPI.Plugin.config(PLUGIN_ID, PLUGIN_NAMESPACE, PLUGIN_NAME, PLUGIN_VERSION, plugin, vspapi);
    ZAPI.Plugin.function(
        "IT",
        "clip:vnode;" ++
            "fps:int:opt;" ++
            "threshold:int:opt;" ++ // match-confidence gate (thcomb in compCp/compCn); default 20
            "pthreshold:int:opt;" ++ // progressive-vs-interlaced classification gate; default 75
            "ref:data:opt;" ++ // "TOP" | "BOTTOM" | "ALL" | "NONE"
            "blend:int:opt;" ++ // 0|1 — motion-blended 24p, fps=24 only
            "diMode:int:opt;", // 0=NONE, 1=DEINTERLACE, 2=SIMPLE_BLUR, 3=ONE_FIELD (default)
        "clip:vnode;",
        filter.create,
        plugin,
        vspapi,
    );
}

// Aggregate tests from sibling modules so `zig build test` runs everything.
test {
    _ = @import("state.zig");
    _ = @import("plane.zig");
    _ = @import("edge.zig");
    _ = @import("eval_iv.zig");
    _ = @import("motion.zig");
    _ = @import("scene.zig");
    _ = @import("decide.zig");
    _ = @import("output.zig");
    _ = @import("blend.zig");
    _ = @import("simd.zig");
    _ = @import("scalar.zig");
}

test "validateInput rejects RGB input" {
    var fmt = std.mem.zeroes(vs.VideoFormat);
    fmt.colorFamily = .RGB;
    fmt.sampleType = .Integer;
    fmt.bitsPerSample = 8;
    fmt.numPlanes = 3;
    var vi = std.mem.zeroes(vs.VideoInfo);
    vi.format = fmt;
    vi.width = 720;
    vi.height = 480;
    vi.numFrames = 100;
    try std.testing.expect(filter.validateInput(&vi) != null);
}

test "validateInput rejects unknown/zero frames" {
    var fmt = std.mem.zeroes(vs.VideoFormat);
    fmt.colorFamily = .YUV;
    fmt.sampleType = .Integer;
    fmt.bitsPerSample = 8;
    fmt.subSamplingW = 1;
    fmt.subSamplingH = 1;
    fmt.numPlanes = 3;
    var vi = std.mem.zeroes(vs.VideoInfo);
    vi.format = fmt;
    vi.width = 720;
    vi.height = 480;
    vi.numFrames = 0;
    try std.testing.expect(filter.validateInput(&vi) != null);
}

test "validateInput rejects 4:2:0 height % 4 != 0, accepts same height for 4:2:2" {
    var fmt = std.mem.zeroes(vs.VideoFormat);
    fmt.colorFamily = .YUV;
    fmt.sampleType = .Integer;
    fmt.bitsPerSample = 8;
    fmt.subSamplingW = 1;
    fmt.subSamplingH = 1;
    fmt.numPlanes = 3;
    var vi = std.mem.zeroes(vs.VideoInfo);
    vi.format = fmt;
    vi.width = 720;
    vi.height = 486; // NTSC full raster: even, but chroma height 243 is odd
    vi.numFrames = 100;
    vi.fpsNum = 30000;
    vi.fpsDen = 1001;
    try std.testing.expect(filter.validateInput(&vi) != null);

    // 4:2:2 has full-height chroma; the same height is fine there.
    vi.format.subSamplingH = 0;
    try std.testing.expectEqual(@as(?[:0]const u8, null), filter.validateInput(&vi));
}

test "validateInput rejects VFR and oversized dimensions" {
    var fmt = std.mem.zeroes(vs.VideoFormat);
    fmt.colorFamily = .YUV;
    fmt.sampleType = .Integer;
    fmt.bitsPerSample = 8;
    fmt.subSamplingW = 1;
    fmt.subSamplingH = 1;
    fmt.numPlanes = 3;
    var vi = std.mem.zeroes(vs.VideoInfo);
    vi.format = fmt;
    vi.width = 720;
    vi.height = 480;
    vi.numFrames = 100;
    // fpsNum == 0 (VFR) must be rejected.
    try std.testing.expect(filter.validateInput(&vi) != null);

    vi.fpsNum = 30000;
    vi.fpsDen = 1001;
    try std.testing.expectEqual(@as(?[:0]const u8, null), filter.validateInput(&vi));

    vi.height = 16384; // even, mod 4 == 0, but above the 8192 cap
    try std.testing.expect(filter.validateInput(&vi) != null);
}

test "validateInput accepts YUV420P8 720x480" {
    var fmt = std.mem.zeroes(vs.VideoFormat);
    fmt.colorFamily = .YUV;
    fmt.sampleType = .Integer;
    fmt.bitsPerSample = 8;
    fmt.subSamplingW = 1;
    fmt.subSamplingH = 1;
    fmt.numPlanes = 3;
    var vi = std.mem.zeroes(vs.VideoInfo);
    vi.format = fmt;
    vi.width = 720;
    vi.height = 480;
    vi.numFrames = 100;
    vi.fpsNum = 30000;
    vi.fpsDen = 1001;
    try std.testing.expectEqual(@as(?[:0]const u8, null), filter.validateInput(&vi));
}
