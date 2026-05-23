/*
VS_IT Copyright(C) 2002 thejam79, 2003 minamina, 2014 msg7086
API 4 port — see reference/vapoursynth-cpp-api4/README.md.

GPL v2+ (same as upstream).
*/

#pragma once
#include "vs_it_interface.h"

struct CFrameInfo {
    char pos;
    char match;
    char matchAcc;
    char ip;
    char out;
    char mflag;
    int diffP0;
    int diffP1;
    int diffS0;
    int diffS1;
    long ivC, ivP, ivN, ivM;
    long ivPC, ivPP, ivPN;
};

struct CTFblockInfo {
    int cfi;
    char level;
    char itype;
};

class IScriptEnvironment
{
public:
    int m_iRealFrame;
    unsigned char *m_edgeMap, *m_motionMap4DI, *m_motionMap4DIMax;

    long m_iSumC, m_iSumP, m_iSumN, m_iSumM;
    long m_iSumPC, m_iSumPP, m_iSumPN, m_iSumPM;
    int m_iCurrentFrame;
    bool m_bRefP;
    int m_iUsePrev, m_iUseNext;
    int m_iUseFrame;

    VSFrameContext *frameCtx;
    VSCore *core;
    const VSAPI *vsapi;
    VSNode *node;
    const VSVideoInfo *vi;
    IScriptEnvironment(VSFrameContext *_frameCtx, VSCore *_core, const VSAPI *_vsapi, VSNode *_node)
        : frameCtx(_frameCtx), core(_core), vsapi(_vsapi), node(_node) {
        vi = vsapi->getVideoInfo(node);
        m_iSumC = m_iSumP = m_iSumN = 0;
        m_iUsePrev = m_iUseNext = 0;
    }
    ~IScriptEnvironment() { }
    VSFrame *NewVideoFrame(const VSVideoInfo * vi) {
        return vsapi->newVideoFrame(&vi->format, vi->width, vi->height, nullptr, core);
    }
    const VSFrame *GetFrame(int n) {
        // API 4 *requires* getFrameFilter inside a filter's getFrame callback —
        // upstream's original API3 code used the sync vsapi->getFrame, which
        // is now undefined behaviour. We also clip `n` to [0, numFrames-1]:
        // the upstream algorithm fetches n-1 / n+1 even at the clip edges
        // (e.g. MakeMotionMap2Max_YV12 at frame 0 wants frame -1). Under API3
        // getFrame at n<0 was effectively clipped by the core; under API4
        // it would deref null and crash.
        n = VSMAX(0, VSMIN(n, vi->numFrames - 1));
        return vsapi->getFrameFilter(n, node, frameCtx);
    }
    void FreeFrame(const VSFrame* source) {
        vsapi->freeFrame(source);
    }
    __forceinline const unsigned char* SYP(const VSFrame * pv, int y, int plane = 0) {
        y = VSMAX(0, VSMIN(vi->height - 1, y));
        auto rPtr = vsapi->getReadPtr(pv, plane);
        auto rStr = vsapi->getStride(pv, plane);
        return rPtr + (plane == 0 ? y : (y >> 2 << 1) + y % 2) * rStr;
    }
    __forceinline unsigned char* DYP(VSFrame * pv, int y, int plane = 0) {
        y = VSMAX(0, VSMIN(vi->height - 1, y));
        auto wPtr = vsapi->getWritePtr(pv, plane);
        auto wStr = vsapi->getStride(pv, plane);
        return wPtr + (plane == 0 ? y : (y >> 2 << 1) + y % 2) * wStr;
    }
};
