//! VapourSynth API 4 C bindings.
//!
//! Single @cImport boundary — every Zig file in this project reaches the
//! VapourSynth C API by writing:
//!
//!     const c = @import("c.zig");
//!     c.VSPlugin, c.VSAPI, c.cfYUV, ...
//!
//! Having it consolidated here keeps translate-c results consistent and
//! avoids duplicate symbol churn during incremental builds.

pub const _c = @cImport({
    @cInclude("VapourSynth4.h");
    @cInclude("VSHelper4.h");
    @cInclude("VSConstants4.h");
});

// Re-export selected items individually. `pub usingnamespace` was removed in
// Zig 0.15+, so we list what we use. Add more as the algorithm port lands.

// --- Plugin / API structs and function-pointer tables ---------------------
pub const VSPlugin = _c.VSPlugin;
pub const VSPLUGINAPI = _c.VSPLUGINAPI;
pub const VSAPI = _c.VSAPI;
pub const VSCore = _c.VSCore;
pub const VSMap = _c.VSMap;
pub const VSNode = _c.VSNode;
pub const VSFrame = _c.VSFrame;
pub const VSFrameContext = _c.VSFrameContext;
pub const VSVideoInfo = _c.VSVideoInfo;
pub const VSVideoFormat = _c.VSVideoFormat;
pub const VSFilterDependency = _c.VSFilterDependency;

// --- Constants ------------------------------------------------------------
pub const VAPOURSYNTH_API_VERSION = _c.VAPOURSYNTH_API_VERSION;
pub const VS_MAKE_VERSION = _c.VS_MAKE_VERSION;

pub const cfYUV = _c.cfYUV;
pub const cfRGB = _c.cfRGB;
pub const cfGray = _c.cfGray;
pub const cfUndefined = _c.cfUndefined;

pub const stInteger = _c.stInteger;
pub const stFloat = _c.stFloat;

pub const fmParallel = _c.fmParallel;
pub const fmParallelRequests = _c.fmParallelRequests;
pub const fmUnordered = _c.fmUnordered;

pub const rpGeneral = _c.rpGeneral;
pub const rpStrictSpatial = _c.rpStrictSpatial;
pub const rpNoFrameReuse = _c.rpNoFrameReuse;

pub const arInitial = _c.arInitial;
pub const arAllFramesReady = _c.arAllFramesReady;
pub const arError = _c.arError;
