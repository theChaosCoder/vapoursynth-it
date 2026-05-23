//! IT filter instance — allocation, VS lifecycle, and GetFrame orchestration.
//!
//! Most of the heavy lifting is delegated to the per-algorithm modules; this
//! file is the glue that wires VS frame fetches to the algorithm primitives
//! and maintains the cross-frame state (`frame_info`, `block_info`).
//!
//! Threading mode: `fmParallelRequests`. VapourSynth then guarantees serial
//! calls into `getFrame`, so the shared mutable state on `Filter` is safe
//! without locking. The prefetch queue (driven by `requestFrameFilter`
//! during `arInitial`) is still parallel under the hood.

const std = @import("std");
const c = @import("c.zig");

const state = @import("state.zig");
const plane = @import("plane.zig");
const edge_mod = @import("edge.zig");
const motion_mod = @import("motion.zig");
const eval_iv_mod = @import("eval_iv.zig");
const scene_mod = @import("scene.zig");
const decide_mod = @import("decide.zig");
const output_mod = @import("output.zig");

const MAX_WIDTH = 8192;

/// Frame view: three plane pointers + strides extracted from a VSFrame.
const FrameView = struct {
    y: [*]const u8, y_stride: usize,
    u: [*]const u8, u_stride: usize,
    v: [*]const u8, v_stride: usize,
};

const FrameViewMut = struct {
    y: [*]u8, y_stride: usize,
    u: [*]u8, u_stride: usize,
    v: [*]u8, v_stride: usize,
};

fn viewOf(api: c.VSAPI, frame: *const c.VSFrame) FrameView {
    return .{
        .y = api.getReadPtr.?(frame, 0),
        .y_stride = @intCast(api.getStride.?(frame, 0)),
        .u = api.getReadPtr.?(frame, 1),
        .u_stride = @intCast(api.getStride.?(frame, 1)),
        .v = api.getReadPtr.?(frame, 2),
        .v_stride = @intCast(api.getStride.?(frame, 2)),
    };
}

fn viewOfMut(api: c.VSAPI, frame: *c.VSFrame) FrameViewMut {
    return .{
        .y = api.getWritePtr.?(frame, 0),
        .y_stride = @intCast(api.getStride.?(frame, 0)),
        .u = api.getWritePtr.?(frame, 1),
        .u_stride = @intCast(api.getStride.?(frame, 1)),
        .v = api.getWritePtr.?(frame, 2),
        .v_stride = @intCast(api.getStride.?(frame, 2)),
    };
}

inline fn toUpper(ch: u8) u8 {
    return if (ch >= 'a' and ch <= 'z') ch - 32 else ch;
}

// ---------------------------------------------------------------------------
// Filter instance
// ---------------------------------------------------------------------------

pub const Filter = struct {
    node: *c.VSNode,
    /// We own this VSVideoInfo so we can mutate numFrames / fps for 24fps mode.
    vi: c.VSVideoInfo,

    fps: i32,
    threshold: i32,
    pthreshold: i32,
    pthreshold_adj: i32,

    width: i32,
    height: i32,
    max_frames: i32,

    frame_info: []state.CFrameInfo,
    block_info: []state.CTFblockInfo,
    call_state: state.CallState,

    allocator: std.mem.Allocator,

    pub fn create(
        allocator: std.mem.Allocator,
        node: *c.VSNode,
        vi_src: *const c.VSVideoInfo,
        fps: i32,
        threshold: i32,
        pthreshold: i32,
    ) !*Filter {
        const max_frames = vi_src.numFrames;
        const width = vi_src.width;
        const height = vi_src.height;
        const wh: usize = @intCast(width * height);

        const frame_info = try allocator.alloc(state.CFrameInfo, @intCast(max_frames + 6));
        errdefer allocator.free(frame_info);
        for (frame_info) |*fi| fi.* = state.CFrameInfo.init;

        const block_info = try allocator.alloc(state.CTFblockInfo, @intCast(@divTrunc(max_frames, 5) + 6));
        errdefer allocator.free(block_info);
        for (block_info) |*bi| bi.* = state.CTFblockInfo.init;

        const edge_buf = try allocator.alloc(u8, wh);
        errdefer allocator.free(edge_buf);
        const m1 = try allocator.alloc(u8, wh);
        errdefer allocator.free(m1);
        const m2 = try allocator.alloc(u8, wh);
        errdefer allocator.free(m2);

        const self = try allocator.create(Filter);
        self.* = .{
            .node = node,
            .vi = vi_src.*,
            .fps = fps,
            .threshold = threshold,
            .pthreshold = pthreshold,
            .pthreshold_adj = plane.adjPara(pthreshold, width, height),
            .width = width,
            .height = height,
            .max_frames = max_frames,
            .frame_info = frame_info,
            .block_info = block_info,
            .call_state = .{
                .edgeMap = edge_buf,
                .motionMap4DI = m1,
                .motionMap4DIMax = m2,
            },
            .allocator = allocator,
        };

        // 24fps mode: rescale numFrames/fps the same way upstream does.
        if (self.fps == 24) {
            self.vi.numFrames = @divTrunc(self.vi.numFrames * 4, 5);
            self.vi.fpsNum *= 4;
            if (@mod(self.vi.fpsNum, 5) == 0) {
                self.vi.fpsNum = @divTrunc(self.vi.fpsNum, 5);
            } else {
                self.vi.fpsDen *= 5;
            }
        }

        return self;
    }

    pub fn destroy(self: *Filter) void {
        self.allocator.free(self.frame_info);
        self.allocator.free(self.block_info);
        self.allocator.free(self.call_state.edgeMap);
        self.allocator.free(self.call_state.motionMap4DI);
        self.allocator.free(self.call_state.motionMap4DIMax);
        self.allocator.destroy(self);
    }
};

// ---------------------------------------------------------------------------
// VapourSynth callbacks
// ---------------------------------------------------------------------------

pub fn create(
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

    const inst = Filter.create(
        std.heap.c_allocator,
        node,
        vi,
        fps,
        threshold,
        pthreshold,
    ) catch {
        api.mapSetError.?(out_map, "IT: out of memory");
        api.freeNode.?(node);
        return;
    };

    var deps = [_]c.VSFilterDependency{
        .{ .source = node, .requestPattern = c.rpGeneral },
    };

    api.createVideoFilter.?(
        out_map,
        "IT",
        &inst.vi,
        getFrame,
        free,
        c.fmParallelRequests,
        &deps,
        deps.len,
        inst,
        core,
    );
}

fn free(
    instanceData: ?*anyopaque,
    core: ?*c.VSCore,
    vsapi: [*c]const c.VSAPI,
) callconv(.c) void {
    _ = core;
    const api = vsapi.*;
    const inst: *Filter = @ptrCast(@alignCast(instanceData.?));
    api.freeNode.?(inst.node);
    inst.destroy();
}

fn getFrame(
    n: c_int,
    activationReason: c_int,
    instanceData: ?*anyopaque,
    frameData: [*c]?*anyopaque,
    frameCtx: ?*c.VSFrameContext,
    core: ?*c.VSCore,
    vsapi: [*c]const c.VSAPI,
) callconv(.c) ?*const c.VSFrame {
    _ = frameData;
    const inst: *Filter = @ptrCast(@alignCast(instanceData.?));
    const api = vsapi.*;
    const ctx = frameCtx.?;

    if (activationReason == c.arInitial) {
        requestNeededFrames(inst, api, ctx, n);
        return null;
    }
    if (activationReason != c.arAllFramesReady) return null;

    // Reset per-call scratch state
    inst.call_state.resetForFrame(n);

    var input_n: i32 = n;
    if (inst.fps == 24) {
        input_n = resolveInputFrame24(inst, api, ctx, n);
    } else {
        getFrameSub(inst, api, ctx, n);
    }

    const dst_opt = api.newVideoFrame.?(&inst.vi.format, inst.vi.width, inst.vi.height, null, core);
    if (dst_opt == null) return null;
    const dst = dst_opt.?;
    makeOutput(inst, api, ctx, dst, input_n);
    return dst;
}

// ---------------------------------------------------------------------------
// Frame-request planning
// ---------------------------------------------------------------------------

fn requestNeededFrames(inst: *Filter, api: c.VSAPI, ctx: *c.VSFrameContext, out_n: i32) void {
    if (inst.fps == 24) {
        // For one output frame at index out_n we'll be walking a block of 5
        // input frames at base..base+4. Each one's ChooseBest reads n-1, n,
        // n+1. MakeOutput / DrawPrevFrame may reach to n-1 and n+1 again.
        // Safest: request [base-1, base+5] inclusive.
        const tf = out_n + @divTrunc(out_n, 4);
        const base = @divTrunc(tf, 5) * 5;
        var i: i32 = base - 1;
        while (i <= base + 5) : (i += 1) {
            const clipped = plane.clipFrame(i, inst.max_frames);
            api.requestFrameFilter.?(clipped, inst.node, ctx);
        }
    } else {
        // fps=30 / passthrough match-only: ChooseBest needs [n-1, n+1].
        var i: i32 = out_n - 1;
        while (i <= out_n + 1) : (i += 1) {
            const clipped = plane.clipFrame(i, inst.max_frames);
            api.requestFrameFilter.?(clipped, inst.node, ctx);
        }
    }
}

fn resolveInputFrame24(inst: *Filter, api: c.VSAPI, ctx: *c.VSFrameContext, out_n: i32) i32 {
    const tf = out_n + @divTrunc(out_n, 4);
    const base = @divTrunc(tf, 5) * 5;

    var i: i32 = 0;
    while (i < 5) : (i += 1) {
        getFrameSub(inst, api, ctx, base + i);
    }
    decide_mod.decide(base, inst.width, inst.height, inst.max_frames, inst.frame_info, inst.block_info);

    var iflag = true;
    i = 0;
    while (i < 5) : (i += 1) {
        const idx: usize = @intCast(plane.clipFrame(base + i, inst.max_frames));
        if (inst.frame_info[idx].ivC >= inst.pthreshold_adj) iflag = false;
    }
    const bidx: usize = @intCast(@divTrunc(base, 5));
    inst.block_info[bidx].itype = if (iflag) '3' else '2';

    var no: i32 = tf - base;
    i = 0;
    while (i < 5) : (i += 1) {
        const idx: usize = @intCast(plane.clipFrame(base + i, inst.max_frames));
        const f = inst.frame_info[idx].mflag;
        if (f != 'D' and f != 'd' and f != 'X' and f != 'x' and f != 'y' and f != 'z' and f != 'R') {
            if (no == 0) break;
            no -= 1;
        }
    }
    return plane.clipFrame(i + base, inst.max_frames);
}

// ---------------------------------------------------------------------------
// GetFrameSub — compute and cache match decision for one input frame.
// ---------------------------------------------------------------------------

fn getFrameSub(inst: *Filter, api: c.VSAPI, ctx: *c.VSFrameContext, n: i32) void {
    if (n >= inst.max_frames) return;
    if (inst.frame_info[@intCast(n)].ip != 'U') return;

    inst.call_state.currentFrame = n;
    inst.call_state.iUseFrame = 'C';
    const init_sum: i64 = @as(i64, inst.width) * @as(i64, inst.height);
    inst.call_state.iSumC = init_sum;
    inst.call_state.iSumP = init_sum;
    inst.call_state.iSumN = init_sum;
    inst.call_state.iSumM = init_sum;
    inst.call_state.bRefP = true;

    chooseBest(inst, api, ctx, n);

    const ni: usize = @intCast(n);
    inst.frame_info[ni].match = inst.call_state.iUseFrame;
    switch (toUpper(inst.call_state.iUseFrame)) {
        'C' => {
            inst.call_state.iSumM = inst.call_state.iSumC;
            inst.call_state.iSumPM = inst.call_state.iSumPC;
        },
        'P' => {
            inst.call_state.iSumM = inst.call_state.iSumP;
            inst.call_state.iSumPM = inst.call_state.iSumPP;
        },
        'N' => {
            inst.call_state.iSumM = inst.call_state.iSumN;
            inst.call_state.iSumPM = inst.call_state.iSumPN;
        },
        else => {},
    }
    inst.frame_info[ni].ivC = inst.call_state.iSumC;
    inst.frame_info[ni].ivP = inst.call_state.iSumP;
    inst.frame_info[ni].ivN = inst.call_state.iSumN;
    inst.frame_info[ni].ivM = inst.call_state.iSumM;
    inst.frame_info[ni].ivPC = inst.call_state.iSumPC;
    inst.frame_info[ni].ivPP = inst.call_state.iSumPP;
    inst.frame_info[ni].ivPN = inst.call_state.iSumPN;
    const pt: i64 = inst.pthreshold_adj;
    inst.frame_info[ni].ip = if (inst.call_state.iSumM < pt and inst.call_state.iSumPM < pt * 3) 'P' else 'I';
}

// ---------------------------------------------------------------------------
// ChooseBest — populate edge map, run EvalIV against C and P, pick best.
// ---------------------------------------------------------------------------

fn chooseBest(inst: *Filter, api: c.VSAPI, ctx: *c.VSFrameContext, n: i32) void {
    const srcC = api.getFrameFilter.?(plane.clipFrame(n, inst.max_frames), inst.node, ctx);
    const srcP = api.getFrameFilter.?(plane.clipFrame(n - 1, inst.max_frames), inst.node, ctx);
    defer api.freeFrame.?(srcC);
    defer api.freeFrame.?(srcP);
    const vC = viewOf(api, srcC.?);
    const vP = viewOf(api, srcP.?);

    ensureMotionMap(inst, api, ctx, inst.call_state.currentFrame);
    ensureMotionMap(inst, api, ctx, inst.call_state.currentFrame + 1);

    // Even rows of edge map: from srcC at offset 0.
    @memset(inst.call_state.edgeMap, 0);
    edge_mod.makeDeMap(inst.width, inst.height, 0, inst.call_state.edgeMap,
        vC.y, vC.y_stride, vC.u, vC.u_stride, vC.v, vC.v_stride);

    const ev_c = eval_iv_mod.evalIv(inst.width, inst.height, inst.pthreshold_adj,
        inst.call_state.edgeMap,
        vC.y, vC.y_stride, vC.u, vC.u_stride, vC.v, vC.v_stride,  // src = C
        vC.y, vC.y_stride, vC.u, vC.u_stride, vC.v, vC.v_stride); // ref = C
    inst.call_state.iSumC = ev_c.counter;
    inst.call_state.iSumPC = ev_c.counterp;

    const ev_p = eval_iv_mod.evalIv(inst.width, inst.height, inst.pthreshold_adj,
        inst.call_state.edgeMap,
        vC.y, vC.y_stride, vC.u, vC.u_stride, vC.v, vC.v_stride,  // src = C
        vP.y, vP.y_stride, vP.u, vP.u_stride, vP.v, vP.v_stride); // ref = P
    inst.call_state.iSumP = ev_p.counter;
    inst.call_state.iSumPP = ev_p.counterp;

    _ = decide_mod.compCp(n, inst.width, inst.height, inst.max_frames, inst.frame_info, &inst.call_state);
}

// ---------------------------------------------------------------------------
// MotionMap cache — fills frame_info[n].diffP0..S1 if not already done.
// ---------------------------------------------------------------------------

fn ensureMotionMap(inst: *Filter, api: c.VSAPI, ctx: *c.VSFrameContext, n_in: i32) void {
    const n = plane.clipFrame(n_in, inst.max_frames);
    if (inst.frame_info[@intCast(n)].diffP0 >= 0) return;

    const srcP = api.getFrameFilter.?(plane.clipFrame(n - 1, inst.max_frames), inst.node, ctx);
    const srcC = api.getFrameFilter.?(n, inst.node, ctx);
    defer api.freeFrame.?(srcP);
    defer api.freeFrame.?(srcC);
    const vP = viewOf(api, srcP.?);
    const vC = viewOf(api, srcC.?);

    const stats = motion_mod.makeMotionMap(inst.width, inst.height,
        vP.y, vP.y_stride, vC.y, vC.y_stride);
    inst.frame_info[@intCast(n)].diffP0 = stats.diffP0;
    inst.frame_info[@intCast(n)].diffP1 = stats.diffP1;
    inst.frame_info[@intCast(n)].diffS0 = stats.diffS0;
    inst.frame_info[@intCast(n)].diffS1 = stats.diffS1;
}

// ---------------------------------------------------------------------------
// MakeOutput — copy or deinterlace, with prev-frame scene-change shortcut.
// ---------------------------------------------------------------------------

fn makeOutput(inst: *Filter, api: c.VSAPI, ctx: *c.VSFrameContext, dst: *c.VSFrame, n: i32) void {
    const ni: usize = @intCast(n);
    inst.call_state.currentFrame = n;
    inst.call_state.iSumC = inst.frame_info[ni].ivC;
    inst.call_state.iSumP = inst.frame_info[ni].ivP;
    inst.call_state.iSumN = inst.frame_info[ni].ivN;
    inst.call_state.iSumM = inst.frame_info[ni].ivM;
    inst.call_state.iSumPC = inst.frame_info[ni].ivPC;
    inst.call_state.iSumPP = inst.frame_info[ni].ivPP;
    inst.call_state.iSumPN = inst.frame_info[ni].ivPN;
    inst.call_state.bRefP = true;
    inst.call_state.iUseFrame = toUpper(inst.frame_info[ni].match);

    if (inst.frame_info[ni].ip == 'P') {
        copyCpnInto(inst, api, ctx, dst, n);
    } else if (!drawPrevFrame(inst, api, ctx, dst, n)) {
        deintInto(inst, api, ctx, dst, n);
    }
}

fn copyCpnInto(inst: *Filter, api: c.VSAPI, ctx: *c.VSFrameContext, dst: *c.VSFrame, n: i32) void {
    const srcC = api.getFrameFilter.?(plane.clipFrame(n, inst.max_frames), inst.node, ctx);
    defer api.freeFrame.?(srcC);
    const vC = viewOf(api, srcC.?);
    var srcR_opt: ?*const c.VSFrame = null;
    var vR: FrameView = vC;
    switch (toUpper(inst.call_state.iUseFrame)) {
        'P' => {
            srcR_opt = api.getFrameFilter.?(plane.clipFrame(n - 1, inst.max_frames), inst.node, ctx);
            vR = viewOf(api, srcR_opt.?);
        },
        'N' => {
            srcR_opt = api.getFrameFilter.?(plane.clipFrame(n + 1, inst.max_frames), inst.node, ctx);
            vR = viewOf(api, srcR_opt.?);
        },
        else => {},
    }
    defer if (srcR_opt) |r| api.freeFrame.?(r);

    const vD = viewOfMut(api, dst);
    output_mod.copyCPNField(inst.width, inst.height,
        vD.y, vD.y_stride, vD.u, vD.u_stride, vD.v, vD.v_stride,
        vC.y, vC.y_stride, vC.u, vC.u_stride, vC.v, vC.v_stride,
        vR.y, vR.y_stride, vR.u, vR.u_stride, vR.v, vR.v_stride);
}

fn deintInto(inst: *Filter, api: c.VSAPI, ctx: *c.VSFrameContext, dst: *c.VSFrame, n: i32) void {
    const srcC = api.getFrameFilter.?(plane.clipFrame(n, inst.max_frames), inst.node, ctx);
    defer api.freeFrame.?(srcC);
    const vC = viewOf(api, srcC.?);

    var srcR_opt: ?*const c.VSFrame = null;
    var ref_y: [*]const u8 = vC.y;
    var ref_y_stride = vC.y_stride;
    switch (toUpper(inst.call_state.iUseFrame)) {
        'P' => {
            srcR_opt = api.getFrameFilter.?(plane.clipFrame(n - 1, inst.max_frames), inst.node, ctx);
            const vR = viewOf(api, srcR_opt.?);
            ref_y = vR.y;
            ref_y_stride = vR.y_stride;
        },
        'N' => {
            srcR_opt = api.getFrameFilter.?(plane.clipFrame(n + 1, inst.max_frames), inst.node, ctx);
            const vR = viewOf(api, srcR_opt.?);
            ref_y = vR.y;
            ref_y_stride = vR.y_stride;
        },
        else => {},
    }
    defer if (srcR_opt) |r| api.freeFrame.?(r);

    // MakeSimpleBlurMap_YV12 -> motionMap4DI
    motion_mod.makeSimpleBlurMap(inst.width, inst.height,
        inst.call_state.motionMap4DI,
        vC.y, vC.y_stride,
        ref_y, ref_y_stride);

    // MakeMotionMap2Max_YV12 -> motionMap4DIMax
    const srcP = api.getFrameFilter.?(plane.clipFrame(n - 1, inst.max_frames), inst.node, ctx);
    const srcN = api.getFrameFilter.?(plane.clipFrame(n + 1, inst.max_frames), inst.node, ctx);
    defer api.freeFrame.?(srcP);
    defer api.freeFrame.?(srcN);
    const vP = viewOf(api, srcP.?);
    const vN = viewOf(api, srcN.?);
    motion_mod.makeMotionMap2Max(inst.width, inst.height,
        inst.call_state.motionMap4DIMax,
        vP.y, vP.y_stride, vP.u, vP.u_stride, vP.v, vP.v_stride,
        vC.y, vC.y_stride, vC.u, vC.u_stride, vC.v, vC.v_stride,
        vN.y, vN.y_stride, vN.u, vN.u_stride, vN.v, vN.v_stride);

    // The field_map scratch was previously edgeMap (we don't need edgeMap
    // during output). Reuse it to avoid an extra allocation, matching the
    // upstream's per-call pField alloc.
    const field_map = inst.call_state.edgeMap;
    const vD = viewOfMut(api, dst);
    output_mod.deintOneField(inst.width, inst.height,
        inst.call_state.motionMap4DI,
        inst.call_state.motionMap4DIMax,
        field_map,
        vD.y, vD.y_stride, vD.u, vD.u_stride, vD.v, vD.v_stride,
        vC.y, vC.y_stride, vC.u, vC.u_stride, vC.v, vC.v_stride,
        ref_y, ref_y_stride);
}

fn drawPrevFrame(inst: *Filter, api: c.VSAPI, ctx: *c.VSFrameContext, dst: *c.VSFrame, n: i32) bool {
    const n_prev = plane.clipFrame(n - 1, inst.max_frames);
    const n_next = plane.clipFrame(n + 1, inst.max_frames);
    const old_cur = inst.call_state.currentFrame;
    const old_use = inst.call_state.iUseFrame;

    getFrameSub(inst, api, ctx, n_prev);
    getFrameSub(inst, api, ctx, n_next);

    inst.call_state.currentFrame = old_cur;

    var result = false;
    if (inst.frame_info[@intCast(n_prev)].ip == 'P' and inst.frame_info[@intCast(n_next)].ip == 'P') {
        const srcP = api.getFrameFilter.?(n_prev, inst.node, ctx);
        const srcC = api.getFrameFilter.?(plane.clipFrame(n, inst.max_frames), inst.node, ctx);
        defer api.freeFrame.?(srcP);
        defer api.freeFrame.?(srcC);
        const vP = viewOf(api, srcP.?);
        const vC = viewOf(api, srcC.?);
        result = scene_mod.checkSceneChange(inst.width, inst.height,
            vP.y, vP.y_stride, vC.y, vC.y_stride);
    }
    if (result) {
        inst.call_state.iUseFrame = inst.frame_info[@intCast(n_prev)].match;
        copyCpnInto(inst, api, ctx, dst, n_prev);
    }
    inst.call_state.iUseFrame = old_use;
    return result;
}

// ---------------------------------------------------------------------------
// Parameter validation & helpers (moved from plugin.zig)
// ---------------------------------------------------------------------------

pub fn validateInput(vi: *const c.VSVideoInfo) ?[*:0]const u8 {
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
