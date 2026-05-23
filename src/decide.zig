//! Decision logic — picks the "use frame" (C/P/N) and decides which frame to
//! drop in 5-frame decimation blocks for fps=24 output.
//!
//! Ported from `reference/vapoursynth-cpp/src/vs_it_process.cpp`. Functions
//! are pure / stateless on their parameters: they read and write the
//! `frame_info` / `block_info` arrays and `CallState`, but do not fetch
//! frames — the caller (filter.zig / chooseBest) is responsible for that.
//!
//! Some of the original code looks odd (`if (ncf != 0 || 1)` is a tautology,
//! the `flag` re-mflag flip can move `+` ↔ `*`). All such quirks are preserved
//! verbatim so the Zig port stays bit-compatible with the upstream C path.

const std = @import("std");
const state = @import("state.zig");
const plane = @import("plane.zig");

const CFrameInfo = state.CFrameInfo;
const CTFblockInfo = state.CTFblockInfo;
const CallState = state.CallState;

/// Marks frame (base + n) as decimated with code `c`, records the in-block
/// position on the block.
pub fn setFt(
    base: i32,
    n: i32,
    c: u8,
    max_frames: i32,
    frame_info: []CFrameInfo,
    block_info: []CTFblockInfo,
) void {
    const idx: usize = @intCast(plane.clipFrame(base + n, max_frames));
    frame_info[idx].mflag = c;
    const bidx: usize = @intCast(@divTrunc(base, 5));
    block_info[bidx].cfi = n;
    block_info[bidx].level = '0';
}

/// Picks C / P / N (uppercase or lowercase) for the current frame, based on
/// motion patterns and IV evidence. Mutates `cs.iUseFrame` and
/// `frame_info[n].pos`. Returns true when a "strong" decision was made (the
/// upstream return value seems mostly informational; we preserve it).
pub fn compCp(
    cur_frame: i32,
    width: i32,
    height: i32,
    max_frames: i32,
    frame_info: []CFrameInfo,
    cs: *CallState,
) bool {
    const n = cur_frame;
    const ni: usize = @intCast(n);
    const np1: usize = @intCast(plane.clipFrame(n + 1, max_frames));

    const p0 = frame_info[ni].diffP0;
    const p1 = frame_info[ni].diffP1;
    const n0 = frame_info[np1].diffP0;
    const n1 = frame_info[np1].diffP1;
    const ps0 = frame_info[ni].diffS0;
    const ps1 = frame_info[ni].diffS1;
    const ns0 = frame_info[np1].diffS0;
    const ns1 = frame_info[np1].diffS1;

    const th = plane.adjPara(5, width, height);
    const thm = plane.adjPara(5, width, height);
    const ths = plane.adjPara(200, width, height);

    const spe = p0 < th and ps0 < ths;
    const spo = p1 < th and ps1 < ths;
    const sne = n0 < th and ns0 < ths;
    const sno = n1 < th and ns1 < ths;

    const mpe = p0 > thm;
    const mpo = p1 > thm;
    const mne = n0 > thm;
    const mno = n1 > thm;

    const thcomb: i64 = plane.adjPara(20, width, height);

    if (n != 0) {
        const dc_p = if (cs.iSumC - cs.iSumP >= 0) cs.iSumC - cs.iSumP else cs.iSumP - cs.iSumC;
        const sum_total = cs.iSumC + cs.iSumP;
        if ((cs.iSumC < thcomb and cs.iSumP < thcomb) or dc_p * 10 < sum_total) {
            if (dc_p > plane.adjPara(8, width, height)) {
                cs.iUseFrame = if (cs.iSumP >= cs.iSumC) 'c' else 'p';
                return true;
            }
            const dpc_pp = if (cs.iSumPC - cs.iSumPP >= 0) cs.iSumPC - cs.iSumPP else cs.iSumPP - cs.iSumPC;
            if (dpc_pp > plane.adjPara(10, width, height)) {
                cs.iUseFrame = if (cs.iSumPP >= cs.iSumPC) 'c' else 'p';
                return true;
            }

            if (spe and mpo) { cs.iUseFrame = 'p'; return true; }
            if (mpe and spo) { cs.iUseFrame = 'c'; return true; }
            if (mne and sno) { cs.iUseFrame = 'p'; return true; }
            if (sne and mno) { cs.iUseFrame = 'c'; return true; }
            if (spe and spo) { cs.iUseFrame = 'c'; return false; }
            if (sne and sno) { cs.iUseFrame = 'c'; return false; }
            if (mpe and mpo and mne and mno) { cs.iUseFrame = 'c'; return false; }

            if (cs.iSumPC > cs.iSumPP) { cs.iUseFrame = 'p'; return true; }
            cs.iUseFrame = 'c';
            return false;
        }
    }

    frame_info[ni].pos = '.';
    if (cs.iSumP >= cs.iSumC) {
        cs.iUseFrame = 'C';
        if (!spe) frame_info[ni].pos = '.';
    } else {
        cs.iUseFrame = 'P';
        if (spe and !sno) frame_info[ni].pos = '2';
        if (!spe and sno) frame_info[ni].pos = '3';
    }
    return true;
}

/// Mirror of compCp for the N (next-frame) candidate. Ported from
/// `reference/avisynth/src/di.cpp::CompCN`. Used when `ref="BOTTOM"`, or
/// when `ref="ALL"` picks the N branch because `sumP >= sumN`.
pub fn compCn(
    cur_frame: i32,
    width: i32,
    height: i32,
    max_frames: i32,
    frame_info: []CFrameInfo,
    cs: *CallState,
) bool {
    const n = cur_frame;
    const ni: usize = @intCast(n);
    const np1: usize = @intCast(plane.clipFrame(n + 1, max_frames));

    const p0 = frame_info[ni].diffP0;
    const p1 = frame_info[ni].diffP1;
    const n0 = frame_info[np1].diffP0;
    const n1 = frame_info[np1].diffP1;
    const ps0 = frame_info[ni].diffS0;
    const ps1 = frame_info[ni].diffS1;
    const ns0 = frame_info[np1].diffS0;
    const ns1 = frame_info[np1].diffS1;

    const th = plane.adjPara(5, width, height);
    const thm = plane.adjPara(5, width, height);
    const ths = plane.adjPara(200, width, height);

    const spe = p0 < th and ps0 < ths;
    const spo = p1 < th and ps1 < ths;
    const sne = n0 < th and ns0 < ths;
    const sno = n1 < th and ns1 < ths;

    const mpe = p0 > thm;
    const mpo = p1 > thm;
    const mne = n0 > thm;
    const mno = n1 > thm;

    const thcomb: i64 = plane.adjPara(20, width, height);

    if (n != 0) {
        const dc_n = if (cs.iSumC - cs.iSumN >= 0) cs.iSumC - cs.iSumN else cs.iSumN - cs.iSumC;
        const sum_cn = cs.iSumC + cs.iSumN;
        if ((cs.iSumC < thcomb and cs.iSumN < thcomb) or dc_n * 10 < sum_cn) {
            if (dc_n > plane.adjPara(8, width, height)) {
                cs.iUseFrame = if (cs.iSumN >= cs.iSumC) 'c' else 'n';
                return true;
            }
            const dpc_pn = if (cs.iSumPC - cs.iSumPN >= 0) cs.iSumPC - cs.iSumPN else cs.iSumPN - cs.iSumPC;
            if (dpc_pn > plane.adjPara(10, width, height)) {
                cs.iUseFrame = if (cs.iSumPN >= cs.iSumPC) 'c' else 'n';
                return true;
            }

            if (spe and mpo) { cs.iUseFrame = 'c'; return true; }
            if (mpe and spo) { cs.iUseFrame = 'N'; return true; }
            if (mne and sno) { cs.iUseFrame = 'c'; return true; }
            if (sne and mno) { cs.iUseFrame = 'n'; return true; }
            if (spe and spo) { cs.iUseFrame = 'c'; return false; }
            if (sne and sno) { cs.iUseFrame = 'c'; return false; }
            if (mpe and mpo and mne and mno) { cs.iUseFrame = 'c'; return false; }

            if (cs.iSumPC > cs.iSumPN) { cs.iUseFrame = 'n'; return true; }
            cs.iUseFrame = 'c';
            return false;
        }
    }

    frame_info[ni].pos = '.';
    if (cs.iSumN >= cs.iSumC) {
        cs.iUseFrame = 'C';
        if (spe and mpo) frame_info[ni].pos = '2';
    } else {
        cs.iUseFrame = 'N';
        if (spo and !sne) frame_info[ni].pos = '0';
        if (mpo and sne) frame_info[ni].pos = '1';
    }
    return true;
}

/// 5-frame-block decimation decision. Marks the frame to drop via mflag and
/// records it in block_info. Skips work if the block was already decided.
pub fn decide(
    n: i32,
    width: i32,
    height: i32,
    max_frames: i32,
    frame_info: []CFrameInfo,
    block_info: []CTFblockInfo,
) void {
    const block_idx: usize = @intCast(@divTrunc(n, 5));
    if (block_info[block_idx].level != 'U') return;

    const base = @divTrunc(n, 5) * 5;

    // Pass 1: mflag from diffP0, threshold = max(mmin, min(diffP0)) * 5
    var min0: i32 = frame_info[@intCast(plane.clipFrame(base, max_frames))].diffP0;
    {
        var i: i32 = 1;
        while (i < 5) : (i += 1) {
            const v = frame_info[@intCast(plane.clipFrame(base + i, max_frames))].diffP0;
            min0 = @min(min0, v);
        }
    }
    const mmin = plane.adjPara(50, width, height);
    {
        var i: i32 = 0;
        while (i < 5) : (i += 1) {
            const idx: usize = @intCast(plane.clipFrame(base + i, max_frames));
            const m = frame_info[idx].diffP0;
            frame_info[idx].mflag = if (m >= @max(mmin, min0) * 5) '.' else '+';
        }
    }
    var ncf: i32 = 0;
    var cfi: i32 = -1;
    {
        var i: i32 = 0;
        while (i < 5) : (i += 1) {
            const idx: usize = @intCast(plane.clipFrame(base + i, max_frames));
            if (frame_info[idx].mflag == '.') ncf += 1 else cfi = i;
        }
    }

    // Pass 2 (fallback when no "low motion" frame found): use diffS0 with *3 threshold.
    const mmin2 = plane.adjPara(50, width, height);
    if (ncf == 0) {
        min0 = frame_info[@intCast(plane.clipFrame(base, max_frames))].diffS0;
        var i: i32 = 1;
        while (i < 5) : (i += 1) {
            const v = frame_info[@intCast(plane.clipFrame(base + i, max_frames))].diffS0;
            min0 = @min(min0, v);
        }
        i = 0;
        while (i < 5) : (i += 1) {
            const idx: usize = @intCast(plane.clipFrame(base + i, max_frames));
            const m = frame_info[idx].diffS0;
            frame_info[idx].mflag = if (m >= @max(mmin2, min0) * 3) '.' else '+';
        }
        ncf = 0;
        cfi = -1;
        i = 0;
        while (i < 5) : (i += 1) {
            const idx: usize = @intCast(plane.clipFrame(base + i, max_frames));
            if (frame_info[idx].mflag == '.') ncf += 1 else cfi = i;
        }
    }

    // Strong: exactly four duplicates -> drop the one outlier.
    if (ncf == 4 and cfi >= 0) {
        setFt(base, cfi, 'D', max_frames, frame_info, block_info);
        return;
    }

    // Upstream code branch is `if (ncf != 0 || 1)` — always taken. Preserved.
    {
        var flag = false;
        var i: i32 = 0;
        while (i < 5) : (i += 1) {
            const idx: usize = @intCast(plane.clipFrame(base + i, max_frames));
            const rr_i: usize = @intCast(plane.clipFrame(base + @mod(i + 2 + 5, 5), max_frames));
            const r_i: usize = @intCast(plane.clipFrame(base + @mod(i + 1 + 5, 5), max_frames));
            const l_i: usize = @intCast(plane.clipFrame(base + @mod(i - 1 + 5, 5), max_frames));
            if (frame_info[idx].mflag != '.' and frame_info[idx].match == 'P') {
                if (frame_info[idx].mflag == '+') {
                    frame_info[idx].mflag = '*';
                    flag = true;
                }
                if (frame_info[r_i].mflag == '+') {
                    frame_info[r_i].mflag = '*';
                    flag = true;
                }
                if (frame_info[l_i].mflag == '+') {
                    frame_info[l_i].mflag = '*';
                    flag = true;
                }
            }
            if (frame_info[idx].match == 'N') {
                if (frame_info[r_i].mflag == '+') {
                    frame_info[r_i].mflag = '*';
                    flag = true;
                }
                if (frame_info[rr_i].mflag == '+') {
                    frame_info[rr_i].mflag = '*';
                    flag = true;
                }
            }
        }
        if (flag) {
            i = 0;
            while (i < 5) : (i += 1) {
                const idx: usize = @intCast(plane.clipFrame(base + i, max_frames));
                const c = frame_info[idx].mflag;
                if (c == '+') frame_info[idx].mflag = '*' else if (c == '*') frame_info[idx].mflag = '+';
            }
        }

        i = 0;
        while (i < 5) : (i += 1) {
            const idx: usize = @intCast(plane.clipFrame(base + i, max_frames));
            if (frame_info[idx].pos == '2') {
                setFt(base, i, 'd', max_frames, frame_info, block_info);
                return;
            }
        }

        if (base - 5 >= 0 and block_info[@intCast(@divTrunc(base, 5) - 1)].level != 'U') {
            const tcfi = block_info[@intCast(@divTrunc(base, 5) - 1)].cfi;
            const cidx: usize = @intCast(base + tcfi);
            if (frame_info[cidx].mflag == '+') {
                setFt(base, tcfi, 'y', max_frames, frame_info, block_info);
                return;
            }
        }

        var pnpos: [5]i32 = undefined;
        var pncnt: usize = 0;
        i = 0;
        while (i < 5) : (i += 1) {
            const idx: usize = @intCast(plane.clipFrame(base + i, max_frames));
            const m = frame_info[idx].match;
            const up = if (m >= 'a' and m <= 'z') m - 32 else m;
            if (up == 'P') {
                pnpos[pncnt] = i;
                pncnt += 1;
            }
        }
        if (pncnt == 2) {
            var k = pnpos[0];
            if (pnpos[0] == 0 and pnpos[1] == 4) k = 4;
            const kidx: usize = @intCast(plane.clipFrame(base + k, max_frames));
            if (frame_info[kidx].mflag != '.') {
                setFt(base, k, 'x', max_frames, frame_info, block_info);
                return;
            }
        }

        pncnt = 0;
        i = 0;
        while (i < 5) : (i += 1) {
            const idx: usize = @intCast(plane.clipFrame(base + i, max_frames));
            const m = frame_info[idx].match;
            const up = if (m >= 'a' and m <= 'z') m - 32 else m;
            if (up != 'N') {
                pnpos[pncnt] = i;
                pncnt += 1;
            }
        }
        if (pncnt == 2) {
            var k = pnpos[0];
            if (pnpos[0] == 3 and pnpos[1] == 4) k = 4;
            k = @mod(k + 2, 5);
            const kidx: usize = @intCast(plane.clipFrame(base + k, max_frames));
            if (frame_info[kidx].mflag != '.') {
                setFt(base, k, 'x', max_frames, frame_info, block_info);
                return;
            }
        }

        i = 0;
        while (i < 5) : (i += 1) {
            const idx: usize = @intCast(plane.clipFrame(base + i, max_frames));
            if (frame_info[idx].mflag == '+') {
                setFt(base, i, 'd', max_frames, frame_info, block_info);
                return;
            }
        }
    }

    // Final fallback: drop the frame with the smallest diffS0.
    var cfi_final: i32 = 0;
    var minx: i32 = frame_info[@intCast(plane.clipFrame(base, max_frames))].diffS0;
    var i: i32 = 1;
    while (i < 5) : (i += 1) {
        const idx: usize = @intCast(plane.clipFrame(base + i, max_frames));
        const m = frame_info[idx].diffS0;
        if (m < minx) {
            cfi_final = i;
            minx = m;
        }
    }
    setFt(base, cfi_final, 'z', max_frames, frame_info, block_info);
}

// ---------------------------------------------------------------------------
const testing = std.testing;

fn makeFrameInfos(n: usize, alloc: std.mem.Allocator) ![]CFrameInfo {
    const buf = try alloc.alloc(CFrameInfo, n);
    for (buf) |*f| f.* = CFrameInfo.init;
    return buf;
}

fn makeBlockInfos(n: usize, alloc: std.mem.Allocator) ![]CTFblockInfo {
    const buf = try alloc.alloc(CTFblockInfo, n);
    for (buf) |*b| b.* = CTFblockInfo.init;
    return buf;
}

test "setFt records the dropped frame slot" {
    const fi = try makeFrameInfos(20, testing.allocator);
    defer testing.allocator.free(fi);
    const bi = try makeBlockInfos(8, testing.allocator);
    defer testing.allocator.free(bi);

    setFt(5, 2, 'D', 20, fi, bi);
    try testing.expectEqual(@as(u8, 'D'), fi[7].mflag);
    try testing.expectEqual(@as(i32, 2), bi[1].cfi);
    try testing.expectEqual(@as(u8, '0'), bi[1].level);
}

test "decide: 4 high-motion + 1 low-motion duplicate -> drop the duplicate ('D')" {
    const fi = try makeFrameInfos(20, testing.allocator);
    defer testing.allocator.free(fi);
    const bi = try makeBlockInfos(8, testing.allocator);
    defer testing.allocator.free(bi);

    // In a high-action sequence where pulldown duplicated one field, the
    // duplicate appears as a LOW-motion frame and the rest are HIGH. Upstream
    // marks high-motion frames with '.' and drops the lone '+' as 'D'.
    fi[0].diffP0 = 9000; fi[0].diffS0 = 9000;
    fi[1].diffP0 = 9000; fi[1].diffS0 = 9000;
    fi[2].diffP0 = 100;  fi[2].diffS0 = 100;  // duplicate
    fi[3].diffP0 = 9000; fi[3].diffS0 = 9000;
    fi[4].diffP0 = 9000; fi[4].diffS0 = 9000;

    decide(0, 720, 480, 20, fi, bi);
    try testing.expectEqual(@as(u8, '0'), bi[0].level);
    try testing.expectEqual(@as(i32, 2), bi[0].cfi);
    try testing.expectEqual(@as(u8, 'D'), fi[2].mflag);
}

test "decide: idempotent — second call is a no-op" {
    const fi = try makeFrameInfos(20, testing.allocator);
    defer testing.allocator.free(fi);
    const bi = try makeBlockInfos(8, testing.allocator);
    defer testing.allocator.free(bi);

    // Inverse pattern from the previous test: frame 3 is the duplicate.
    for (fi[0..5], 0..) |*f, i| {
        f.diffP0 = if (i == 3) 50 else 9000;
        f.diffS0 = if (i == 3) 50 else 9000;
    }
    decide(0, 720, 480, 20, fi, bi);
    const cfi_first = bi[0].cfi;
    // Now mutate something to detect if decide re-runs:
    bi[0].cfi = 999;
    decide(0, 720, 480, 20, fi, bi);
    try testing.expectEqual(@as(i32, 999), bi[0].cfi);
    _ = cfi_first;
}

test "compCp: equal sums, first frame uses default branch" {
    const fi = try makeFrameInfos(20, testing.allocator);
    defer testing.allocator.free(fi);
    const e_buf = try testing.allocator.alloc(u8, 64 * 48);
    defer testing.allocator.free(e_buf);
    const m1 = try testing.allocator.alloc(u8, 64 * 48);
    defer testing.allocator.free(m1);
    const m2 = try testing.allocator.alloc(u8, 64 * 48);
    defer testing.allocator.free(m2);
    var cs = CallState{
        .edgeMap = e_buf,
        .motionMap4DI = m1,
        .motionMap4DIMax = m2,
    };
    cs.iSumC = 100;
    cs.iSumP = 200;
    fi[0].diffP0 = 1000;
    fi[0].diffP1 = 1000;
    fi[1].diffP0 = 1000;
    fi[1].diffP1 = 1000;
    _ = compCp(0, 720, 480, 20, fi, &cs);
    try testing.expectEqual(@as(u8, 'C'), cs.iUseFrame);
}
