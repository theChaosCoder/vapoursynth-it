/*
VS_IT Copyright(C) 2002 thejam79, 2003 minamina, 2014 msg7086
API 4 port — see reference/vapoursynth-cpp-api4/README.md.

GPL v2+ (same as upstream).
*/

#include "vs_it_interface.h"

typedef IT INSTANCE;

void VS_CC itFree(void * instanceData, VSCore * core, const VSAPI * vsapi) {
    INSTANCE * d = static_cast<INSTANCE*>(instanceData);
    vsapi->freeNode(d->node);
    delete d;
}

const VSFrame *VS_CC itGetFrame(int n, int activationReason, void * instanceData, void ** frameData,
                                VSFrameContext * frameCtx, VSCore * core, const VSAPI * vsapi) {
    INSTANCE * d = static_cast<INSTANCE*>(instanceData);
    IScriptEnvironment env(frameCtx, core, vsapi, d->node);
    if (activationReason == arInitial) {
        d->GetFramePre(&env, n);
        return nullptr;
    }
    if (activationReason != arAllFramesReady)
        return nullptr;

    return d->GetFrame(&env, n);
}

static void VS_CC itCreate(const VSMap * in, VSMap * out, void * userData, VSCore * core, const VSAPI * vsapi) {
    int err;

    VSNode * node = vsapi->mapGetNode(in, "clip", 0, &err);
    const VSVideoInfo * vi = vsapi->getVideoInfo(node);

    if (vi->width == 0 || vi->height == 0) {
        vsapi->freeNode(node);
        vsapi->mapSetError(out, "clip must be constant format");
        return;
    }

    if (vi->format.sampleType != stInteger ||
        vi->format.bitsPerSample != 8 ||
        vi->format.colorFamily != cfYUV ||
        vi->format.subSamplingW != 1 ||
        vi->format.subSamplingH != 1) {
        vsapi->freeNode(node);
        vsapi->mapSetError(out, "only YUV420P8 input supported. You can you up.");
        return;
    }

    if (vi->width & 15) {
        vsapi->freeNode(node);
        vsapi->mapSetError(out, "width must be mod 16");
        return;
    }

    if (vi->height & 1) {
        vsapi->freeNode(node);
        vsapi->mapSetError(out, "height must be even");
        return;
    }

    if (vi->width > MAX_WIDTH) {
        vsapi->freeNode(node);
        vsapi->mapSetError(out, "width too large");
        return;
    }

    PARAM_INT(fps, 24);
    PARAM_INT(threshold, 20);
    PARAM_INT(pthreshold, 75);

    INSTANCE * d = new INSTANCE(new VSVideoInfo(*vi), node, fps, threshold, pthreshold, vsapi);

    VSFilterDependency deps[] = {{ node, rpGeneral }};
    vsapi->createVideoFilter(out, "IT", d->vi, itGetFrame, itFree, fmParallelRequests, deps, 1, d, core);
    return;
}

VS_EXTERNAL_API(void) VapourSynthPluginInit2(VSPlugin * plugin, const VSPLUGINAPI * vspapi) {
    vspapi->configPlugin("in.7086.it", "it",
                         "VapourSynth IVTC Filter v" IT_VERSION,
                         VS_MAKE_VERSION(1, 0),
                         VAPOURSYNTH_API_VERSION, 0, plugin);
    vspapi->registerFunction("IT",
                             "clip:vnode;fps:int:opt;threshold:int:opt;pthreshold:int:opt;",
                             "clip:vnode;",
                             itCreate, nullptr, plugin);
}
