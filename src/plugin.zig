//! VapourSynth plugin entry point for `zit` — Zig port of VapourSynth-IT.
//!
//! Phase 1 implements an *identity* filter (output frame == input frame) so
//! we can verify the plugin loads, parameter validation behaves like upstream,
//! and the build produces a usable shared library on Linux / macOS / Windows.
//! The actual IVTC algorithm lands in later phases.

const std = @import("std");
const c = @import("c.zig");

const PLUGIN_ID = "com.thechaoscoder.zit";
const PLUGIN_NAMESPACE = "zit";
const PLUGIN_NAME = "VapourSynth IVTC Filter (Zig port)";
const PLUGIN_VERSION = c.VS_MAKE_VERSION(0, 1);

const MAX_WIDTH = 8192;

// Public C entry point. VapourSynth dlopens the library and looks for this
// symbol. Must match the C signature exactly:
//   void VS_CC VapourSynthPluginInit2(VSPlugin *plugin, const VSPLUGINAPI *vspapi);
export fn VapourSynthPluginInit2(
    plugin: *c.VSPlugin,
    vspapi: *const c.VSPLUGINAPI,
) callconv(.c) void {
    _ = vspapi.configPlugin.?(
        PLUGIN_ID,
        PLUGIN_NAMESPACE,
        PLUGIN_NAME,
        PLUGIN_VERSION,
        c.VAPOURSYNTH_API_VERSION,
        0,
        plugin,
    );
    _ = vspapi.registerFunction.?(
        "IT",
        "clip:vnode;fps:int:opt;threshold:int:opt;pthreshold:int:opt;",
        "clip:vnode;",
        itCreate,
        null,
        plugin,
    );
}

// ---------------------------------------------------------------------------
// Filter instance
// ---------------------------------------------------------------------------

const Filter = struct {
    node: *c.VSNode,
    vi: *const c.VSVideoInfo,
    fps: i32,
    threshold: i32,
    pthreshold: i32,
};

fn itCreate(
    in: ?*const c.VSMap,
    out: ?*c.VSMap,
    userData: ?*anyopaque,
    core: ?*c.VSCore,
    vsapi: [*c]const c.VSAPI,
) callconv(.c) void {
    _ = userData;
    const api = vsapi.*;
    const out_map = out.?;

    var err: c_int = 0;
    const maybe_node = api.mapGetNode.?(in.?, "clip", 0, &err);
    if (maybe_node == null) {
        api.mapSetError.?(out_map, "IT: clip required");
        return;
    }
    const node = maybe_node.?;
    const vi_ptr = api.getVideoInfo.?(node);
    if (vi_ptr == null) {
        api.mapSetError.?(out_map, "IT: could not get video info");
        api.freeNode.?(node);
        return;
    }
    const vi = vi_ptr.?;

    if (validateInput(vi)) |reason| {
        api.mapSetError.?(out_map, reason);
        api.freeNode.?(node);
        return;
    }

    const fps = mapGetIntDefault(api, in.?, "fps", 24);
    const threshold = mapGetIntDefault(api, in.?, "threshold", 20);
    const pthreshold = mapGetIntDefault(api, in.?, "pthreshold", 75);

    if (fps != 24 and fps != 30) {
        api.mapSetError.?(out_map, "IT: fps must be 24 or 30");
        api.freeNode.?(node);
        return;
    }

    const inst = std.heap.c_allocator.create(Filter) catch {
        api.mapSetError.?(out_map, "IT: out of memory");
        api.freeNode.?(node);
        return;
    };
    inst.* = .{
        .node = node,
        .vi = vi,
        .fps = fps,
        .threshold = threshold,
        .pthreshold = pthreshold,
    };

    var deps = [_]c.VSFilterDependency{
        .{ .source = node, .requestPattern = c.rpStrictSpatial },
    };

    // Phase 1: identity filter, no shared state across calls -> fmParallel is
    // safe. When the real algorithm lands it switches to fmParallelRequests.
    api.createVideoFilter.?(
        out_map,
        "IT",
        vi,
        itGetFrame,
        itFree,
        c.fmParallel,
        &deps,
        deps.len,
        inst,
        core,
    );
}

fn itGetFrame(
    n: c_int,
    activationReason: c_int,
    instanceData: ?*anyopaque,
    frameData: [*c]?*anyopaque,
    frameCtx: ?*c.VSFrameContext,
    core: ?*c.VSCore,
    vsapi: [*c]const c.VSAPI,
) callconv(.c) ?*const c.VSFrame {
    _ = frameData;
    _ = core;
    const api = vsapi.*;
    const inst: *Filter = @ptrCast(@alignCast(instanceData.?));

    switch (activationReason) {
        c.arInitial => {
            api.requestFrameFilter.?(n, inst.node, frameCtx);
            return null;
        },
        c.arAllFramesReady => {
            return api.getFrameFilter.?(n, inst.node, frameCtx);
        },
        else => return null,
    }
}

fn itFree(
    instanceData: ?*anyopaque,
    core: ?*c.VSCore,
    vsapi: [*c]const c.VSAPI,
) callconv(.c) void {
    _ = core;
    const api = vsapi.*;
    const inst: *Filter = @ptrCast(@alignCast(instanceData.?));
    api.freeNode.?(inst.node);
    std.heap.c_allocator.destroy(inst);
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Returns `null` if input is acceptable, otherwise an error message.
fn validateInput(vi: *const c.VSVideoInfo) ?[*:0]const u8 {
    if (vi.format.colorFamily != c.cfYUV or
        vi.format.sampleType != c.stInteger or
        vi.format.bitsPerSample != 8 or
        vi.format.subSamplingW != 1 or
        vi.format.subSamplingH != 1)
    {
        return "IT: only YUV420P8 input supported";
    }
    if (vi.width <= 0 or vi.height <= 0) {
        return "IT: clip must have constant format and dimensions";
    }
    if (vi.width & 15 != 0) {
        return "IT: width must be a multiple of 16";
    }
    if (vi.height & 1 != 0) {
        return "IT: height must be even";
    }
    if (vi.width > MAX_WIDTH) {
        return "IT: width too large (max 8192)";
    }
    return null;
}

fn mapGetIntDefault(
    api: c.VSAPI,
    map: *const c.VSMap,
    key: [*:0]const u8,
    default: i32,
) i32 {
    var err: c_int = 0;
    const v = api.mapGetIntSaturated.?(map, key, 0, &err);
    if (err != 0) return default;
    return v;
}

// Negate-return helper for `if (validateInput(vi)) |reason|` ergonomics.
// (Zig doesn't allow `|x|` capture on a plain optional-returning expr in `if`
// when used inside a more complex condition — this just wraps it cleanly.)
test "validateInput rejects non-YUV420P8" {
    var fmt = std.mem.zeroes(c.VSVideoFormat);
    fmt.colorFamily = c.cfRGB;
    fmt.sampleType = c.stInteger;
    fmt.bitsPerSample = 8;
    fmt.numPlanes = 3;
    var vi = std.mem.zeroes(c.VSVideoInfo);
    vi.format = fmt;
    vi.width = 720;
    vi.height = 480;
    vi.numFrames = 100;
    try std.testing.expect(validateInput(&vi) != null);
}

test "validateInput accepts YUV420P8 720x480" {
    var fmt = std.mem.zeroes(c.VSVideoFormat);
    fmt.colorFamily = c.cfYUV;
    fmt.sampleType = c.stInteger;
    fmt.bitsPerSample = 8;
    fmt.subSamplingW = 1;
    fmt.subSamplingH = 1;
    fmt.numPlanes = 3;
    var vi = std.mem.zeroes(c.VSVideoInfo);
    vi.format = fmt;
    vi.width = 720;
    vi.height = 480;
    vi.numFrames = 100;
    try std.testing.expectEqual(@as(?[*:0]const u8, null), validateInput(&vi));
}

test "validateInput rejects width not multiple of 16" {
    var fmt = std.mem.zeroes(c.VSVideoFormat);
    fmt.colorFamily = c.cfYUV;
    fmt.sampleType = c.stInteger;
    fmt.bitsPerSample = 8;
    fmt.subSamplingW = 1;
    fmt.subSamplingH = 1;
    fmt.numPlanes = 3;
    var vi = std.mem.zeroes(c.VSVideoInfo);
    vi.format = fmt;
    vi.width = 715; // not mod 16
    vi.height = 480;
    vi.numFrames = 100;
    try std.testing.expect(validateInput(&vi) != null);
}

test "validateInput rejects odd height" {
    var fmt = std.mem.zeroes(c.VSVideoFormat);
    fmt.colorFamily = c.cfYUV;
    fmt.sampleType = c.stInteger;
    fmt.bitsPerSample = 8;
    fmt.subSamplingW = 1;
    fmt.subSamplingH = 1;
    fmt.numPlanes = 3;
    var vi = std.mem.zeroes(c.VSVideoInfo);
    vi.format = fmt;
    vi.width = 720;
    vi.height = 481; // odd
    vi.numFrames = 100;
    try std.testing.expect(validateInput(&vi) != null);
}

test "validateInput rejects width over MAX_WIDTH" {
    var fmt = std.mem.zeroes(c.VSVideoFormat);
    fmt.colorFamily = c.cfYUV;
    fmt.sampleType = c.stInteger;
    fmt.bitsPerSample = 8;
    fmt.subSamplingW = 1;
    fmt.subSamplingH = 1;
    fmt.numPlanes = 3;
    var vi = std.mem.zeroes(c.VSVideoInfo);
    vi.format = fmt;
    vi.width = 8208; // > 8192
    vi.height = 480;
    vi.numFrames = 100;
    try std.testing.expect(validateInput(&vi) != null);
}
