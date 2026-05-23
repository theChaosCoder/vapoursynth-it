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
const blend_mod = @import("blend.zig");

/// Field-order parameter values. Upstream's `ref="TOP"` corresponds to
/// `REF_PREV` semantics in the Avisynth original (match against previous
/// frame). The VS upstream port simplified this away and only supports the
/// `top` mode; we expose the parameter for compatibility with Avisynth
/// scripts but only `top` is fully implemented today.
pub const Ref = enum { top, bottom, all, none };

/// Deinterlace strategy when a frame is classified interlaced (ip='I').
/// Upstream VapourSynth hardcodes `one_field`; the Avisynth original
/// supports four modes. We implement `none` and `one_field`; `deinterlace`
/// and `simple_blur` would need their Avisynth implementations ported and
/// currently raise an error.
pub const DiMode = enum(u8) { none = 0, deinterlace = 1, simple_blur = 2, one_field = 3 };

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

    ref: Ref,
    blend: bool,
    dimode: DiMode,

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
        ref: Ref,
        blend: bool,
        dimode: DiMode,
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
            .ref = ref,
            // Avisynth: blend is ignored when fps != 24. Fold that here.
            .blend = blend and fps == 24,
            .dimode = dimode,
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

    // ref: "TOP" (default), "BOTTOM", "ALL", "NONE" — Avisynth-compatible.
    // Currently only "TOP" is fully supported; the others would require
    // the next-frame-evaluation path the VS upstream stripped from
    // ChooseBest. Until that's ported we reject them explicitly so users
    // don't get silently-wrong output.
    const ref_str = mapGetDataDefault(api, in.?, "ref", "TOP");
    const ref_val: Ref = blk: {
        if (strEqlCi(ref_str, "TOP")) break :blk .top;
        if (strEqlCi(ref_str, "BOTTOM")) break :blk .bottom;
        if (strEqlCi(ref_str, "ALL")) break :blk .all;
        if (strEqlCi(ref_str, "NONE")) break :blk .none;
        api.mapSetError.?(out_map, "IT: ref must be one of \"TOP\", \"BOTTOM\", \"ALL\", \"NONE\"");
        api.freeNode.?(node);
        return;
    };
    if (ref_val != .top) {
        api.mapSetError.?(out_map,
            "IT: ref=\"BOTTOM\"/\"ALL\"/\"NONE\" is recognised but not yet implemented in the Zig port " ++
            "(would need the prev/next-frame evaluation path the VapourSynth upstream removed).");
        api.freeNode.?(node);
        return;
    }

    const blend = mapGetIntDefault(api, in.?, "blend", 0) != 0;

    // diMode: 0=NONE (copy with field-match only), 1=DEINTERLACE,
    // 2=SIMPLE_BLUR, 3=ONE_FIELD (the VS upstream default; what we
    // implement today). 1 and 2 would need the original Avisynth
    // implementations ported.
    const dimode_int = mapGetIntDefault(api, in.?, "diMode", 3);
    const dimode_val: DiMode = switch (dimode_int) {
        0 => .none,
        1 => .deinterlace,
        2 => .simple_blur,
        3 => .one_field,
        else => {
            api.mapSetError.?(out_map, "IT: diMode must be 0, 1, 2 or 3");
            api.freeNode.?(node);
            return;
        },
    };
    if (dimode_val == .deinterlace or dimode_val == .simple_blur) {
        api.mapSetError.?(out_map,
            "IT: diMode=1 (DEINTERLACE) and diMode=2 (SIMPLE_BLUR) are not yet ported. " ++
            "Use diMode=0 (NONE) or diMode=3 (ONE_FIELD, default).");
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
        ref_val,
        blend,
        dimode_val,
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
    var base24: i32 = 0;
    var tf24: i32 = 0;
    if (inst.fps == 24) {
        tf24 = n + @divTrunc(n, 4);
        base24 = @divTrunc(tf24, 5) * 5;
        input_n = resolveInputFrame24(inst, api, ctx, n);
    } else {
        getFrameSub(inst, api, ctx, n);
    }

    const dst_opt = api.newVideoFrame.?(&inst.vi.format, inst.vi.width, inst.vi.height, null, core);
    if (dst_opt == null) return null;
    const dst = dst_opt.?;

    if (inst.fps == 24 and shouldBlendBlock(inst, base24)) {
        blendInto(inst, api, ctx, core, dst, base24, tf24);
    } else {
        makeOutput(inst, api, ctx, dst, input_n);
    }
    return dst;
}

// ---------------------------------------------------------------------------
// Frame-request planning
// ---------------------------------------------------------------------------

fn requestNeededFrames(inst: *Filter, api: c.VSAPI, ctx: *c.VSFrameContext, out_n: i32) void {
    // Frame-reach analysis (worst case):
    //  - ChooseBest(n) reads [n-1, n+1] (srcC, srcP, ensureMotionMap of n+1).
    //  - GetFrameSub(n) -> ChooseBest(n)               : reach [n-1, n+1]
    //  - MakeOutput(n) may call DrawPrevFrame(n) which
    //    triggers GetFrameSub(n-1) and GetFrameSub(n+1):
    //      * GetFrameSub(n-1)  -> reach [n-2, n  ]
    //      * GetFrameSub(n+1)  -> reach [n,   n+2]
    //  -> union per output frame: [n-2, n+2].
    //  - For fps=24, the same applies for every frame in the 5-frame block.
    if (inst.fps == 24) {
        const tf = out_n + @divTrunc(out_n, 4);
        const base = @divTrunc(tf, 5) * 5;
        // Range to cover: GetFrameSub(base..base+4) -> [base-1, base+5],
        // plus DrawPrevFrame on the chosen input frame within [base, base+4]
        // -> can extend to [base-2, base+6]. When blend=true the algorithm
        // additionally renders MakeOutput for source frames in
        // [base-1, base+5] (blend kernel size 3 with start in [-1, 3]),
        // and each of those drawPrevFrame paths reaches another ±2 — so
        // we widen to [base-3, base+7] for that case.
        const lo: i32 = if (inst.blend) base - 3 else base - 2;
        const hi: i32 = if (inst.blend) base + 7 else base + 6;
        var i: i32 = lo;
        while (i <= hi) : (i += 1) {
            const clipped = plane.clipFrame(i, inst.max_frames);
            api.requestFrameFilter.?(clipped, inst.node, ctx);
        }
    } else {
        var i: i32 = out_n - 2;
        while (i <= out_n + 2) : (i += 1) {
            const clipped = plane.clipFrame(i, inst.max_frames);
            api.requestFrameFilter.?(clipped, inst.node, ctx);
        }
    }
}

/// Returns true if `blend=true` actually triggers blending for this 5-frame
/// block — gated by motion thresholds the Avisynth original computes from
/// the cached diffS0/diffS1 stats. Mirrors the `flag` heuristic at di.cpp
/// line 3181.
fn shouldBlendBlock(inst: *Filter, base: i32) bool {
    if (!inst.blend) return false;
    var min_d: i32 = inst.frame_info[@intCast(plane.clipFrame(base, inst.max_frames))].diffS1;
    var avg_d: i32 = 0;
    var i: i32 = 0;
    while (i < 5) : (i += 1) {
        const idx: usize = @intCast(plane.clipFrame(base + i, inst.max_frames));
        min_d = @min(min_d, inst.frame_info[idx].diffS1);
        avg_d += inst.frame_info[idx].diffS0;
    }
    const thr = plane.adjPara(1000, inst.width, inst.height);
    if (min_d < thr) return false;
    // The C `((avgD - minD) / 4) / 3` is signed truncation; replicate exactly.
    const secondary = @divTrunc(@divTrunc(avg_d - min_d, 4), 3);
    if (min_d < secondary) return false;
    return true;
}

/// `BlendFrame_YV12` analogue: render each source frame via MakeOutput,
/// then run the temporal blend. Allocates `size` temporary VSFrames.
fn blendInto(inst: *Filter, api: c.VSAPI, ctx: *c.VSFrameContext, core: ?*c.VSCore, dst: *c.VSFrame, base: i32, tf_frame: i32) void {
    const kernel = blend_mod.buildKernel(tf_frame - base);
    const size: usize = @intCast(kernel.size);

    var srcs: [16]blend_mod.SourceView = undefined;
    var temps: [16]?*c.VSFrame = .{null} ** 16;
    defer for (temps[0..size]) |t| if (t) |f| api.freeFrame.?(f);

    var z: usize = 0;
    while (z < size) : (z += 1) {
        const fno = plane.clipFrame(base + kernel.start + @as(i32, @intCast(z)), inst.max_frames);
        const tmp_opt = api.newVideoFrame.?(&inst.vi.format, inst.vi.width, inst.vi.height, null, core);
        if (tmp_opt == null) return;
        const tmp = tmp_opt.?;
        temps[z] = tmp;
        makeOutput(inst, api, ctx, tmp, fno);
        const v = viewOfMut(api, tmp);
        srcs[z] = .{
            .y = v.y, .y_stride = v.y_stride,
            .u = v.u, .u_stride = v.u_stride,
            .v = v.v, .v_stride = v.v_stride,
        };
    }

    const vD = viewOfMut(api, dst);
    blend_mod.blendFrames(
        inst.width, inst.height, kernel, srcs[0..size],
        vD.y, vD.y_stride, vD.u, vD.u_stride, vD.v, vD.v_stride,
    );
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
        return;
    }
    // ip == 'I': dispatch on diMode.
    switch (inst.dimode) {
        .none => {
            // DI_MODE_NONE in Avisynth: skip the deinterlacer, just field-copy.
            copyCpnInto(inst, api, ctx, dst, n);
        },
        .one_field => {
            if (!drawPrevFrame(inst, api, ctx, dst, n)) {
                deintInto(inst, api, ctx, dst, n);
            }
        },
        // .deinterlace, .simple_blur are rejected at create() time.
        else => unreachable,
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

fn mapGetDataDefault(
    api: c.VSAPI,
    map: *const c.VSMap,
    key: [*:0]const u8,
    default: []const u8,
) []const u8 {
    var err: c_int = 0;
    const ptr = api.mapGetData.?(map, key, 0, &err);
    if (err != 0 or ptr == null) return default;
    var sz_err: c_int = 0;
    const sz = api.mapGetDataSize.?(map, key, 0, &sz_err);
    if (sz_err != 0 or sz <= 0) return default;
    return ptr[0..@intCast(sz)];
}

fn strEqlCi(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        const la = if (ca >= 'A' and ca <= 'Z') ca + 32 else ca;
        const lb = if (cb >= 'A' and cb <= 'Z') cb + 32 else cb;
        if (la != lb) return false;
    }
    return true;
}
