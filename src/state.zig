//! Per-frame and per-block state structures, ported from
//! `reference/vapoursynth-cpp/src/IScriptEnvironment.h`.
//!
//! These arrays are filled lazily as the filter walks through the clip.
//! Each entry starts in the `'U'`(nknown) sentinel state and is overwritten
//! the first time the algorithm considers that frame / block.

const std = @import("std");

/// Per-input-frame state. Allocated `numFrames + 6` times (the +6 is a
/// guard so out-of-range index probes near the clip end don't trash neighbours).
pub const CFrameInfo = extern struct {
    pos: u8,
    match: u8,
    matchAcc: u8,
    ip: u8,
    out: u8,
    mflag: u8,

    diffP0: i32,
    diffP1: i32,
    diffS0: i32,
    diffS1: i32,

    ivC: i64,
    ivP: i64,
    ivN: i64,
    ivM: i64,
    ivPC: i64,
    ivPP: i64,
    ivPN: i64,

    pub const init: CFrameInfo = .{
        .pos = 'U',
        .match = 'U',
        .matchAcc = 'U',
        .ip = 'U',
        .out = 'U',
        .mflag = 'U',
        .diffP0 = -1,
        .diffP1 = -1,
        .diffS0 = 0,
        .diffS1 = 0,
        .ivC = 0,
        .ivP = 0,
        .ivN = 0,
        .ivM = 0,
        .ivPC = 0,
        .ivPP = 0,
        .ivPN = 0,
    };
};

/// Per-5-frame-block state. `cfi` (chosen frame index 0..4) is the in-block
/// position of the frame that gets dropped in 24fps mode.
pub const CTFblockInfo = extern struct {
    cfi: i32,
    level: u8,
    itype: u8,

    pub const init: CTFblockInfo = .{
        .cfi = 0,
        .level = 'U',
        .itype = 'U',
    };
};

/// Ephemeral state for one in-flight GetFrame call. The C++ upstream wraps
/// this in a fake `IScriptEnvironment` instance allocated on the stack per
/// call; we model it as a plain struct so it can be embedded into the filter
/// instance (sound under fmParallelRequests where calls are serialised) or
/// stack-allocated per-call later if we ever switch to fmParallel.
pub const CallState = struct {
    /// scratch buffers, lifetime = one GetFrame call
    edgeMap: []u8,
    motionMap4DI: []u8,
    motionMap4DIMax: []u8,

    /// current output frame the filter is producing (post-decimation index)
    realFrame: i32 = 0,
    /// current input frame the algorithm is reasoning about (pre-decimation)
    currentFrame: i32 = 0,

    iSumC: i64 = 0,
    iSumP: i64 = 0,
    iSumN: i64 = 0,
    iSumM: i64 = 0,
    iSumPC: i64 = 0,
    iSumPP: i64 = 0,
    iSumPN: i64 = 0,
    iSumPM: i64 = 0,

    bRefP: bool = true,
    iUsePrev: i32 = 0,
    iUseNext: i32 = 0,

    /// 'C', 'P', 'N' (uppercase = strong match, lowercase = weak) — picked by
    /// chooseBest and consumed by the output stage.
    iUseFrame: u8 = 'C',

    pub fn resetForFrame(self: *CallState, n: i32) void {
        self.realFrame = n;
        self.currentFrame = n;
        self.iSumC = 0;
        self.iSumP = 0;
        self.iSumN = 0;
        self.iSumM = 0;
        self.iSumPC = 0;
        self.iSumPP = 0;
        self.iSumPN = 0;
        self.iSumPM = 0;
        self.bRefP = true;
        self.iUsePrev = 0;
        self.iUseNext = 0;
        self.iUseFrame = 'C';
        @memset(self.edgeMap, 0);
        @memset(self.motionMap4DI, 0);
        @memset(self.motionMap4DIMax, 0);
    }
};

test "CFrameInfo.init has sentinel values matching upstream" {
    const fi = CFrameInfo.init;
    try std.testing.expectEqual(@as(u8, 'U'), fi.match);
    try std.testing.expectEqual(@as(u8, 'U'), fi.ip);
    try std.testing.expectEqual(@as(i32, -1), fi.diffP0);
    try std.testing.expectEqual(@as(i32, -1), fi.diffP1);
}

test "CTFblockInfo.init has sentinel values" {
    const bi = CTFblockInfo.init;
    try std.testing.expectEqual(@as(u8, 'U'), bi.level);
    try std.testing.expectEqual(@as(u8, 'U'), bi.itype);
}
