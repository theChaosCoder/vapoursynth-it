/*
VS_IT Copyright(C) 2002 thejam79, 2003 minamina, 2014 msg7086
API 4 port: this file is a mechanical migration of the upstream VS_IT
plugin to VapourSynth API 4. See `reference/vapoursynth-cpp-api4/README.md`
for the why; the algorithm itself is unchanged.

GPL v2+ (same as upstream).
*/

#pragma once
#include <string.h>
#include <math.h>
#include <stdlib.h>
#include <ctype.h>
#include <stdio.h>
#include <stdint.h>
#include <VapourSynth4.h>
#include <VSHelper4.h>

// VSHelper4 puts vsh_aligned_malloc, vsh_aligned_free and bitblt under the
// `vsh::` namespace in C++. Hoist them so the rest of the legacy code still
// compiles unmodified.
using namespace vsh;

#ifdef _MSC_VER
#include <intrin.h>
#define alignas(x) __declspec(align(x))
#define ALIGNED_ARRAY(decl, alignment) alignas(alignment) decl
#else
#define __forceinline inline
#define ALIGNED_ARRAY(decl, alignment) __attribute__((aligned(alignment))) decl
#define _aligned_malloc(size, alignment) vsh_aligned_malloc<unsigned char>((size), (alignment))
#define _aligned_free(buffer) vsh_aligned_free(buffer)
#endif

// Upstream calls vs_bitblt; under VSHelper4 the name is `bitblt` inside vsh::.
#define vs_bitblt bitblt

#define PARAM_INT(name, def) int name = vsapi->mapGetIntSaturated(in, #name, 0, &err); if (err) { name = def; }

#define IT_VERSION "0103." "1.1-api4"

#include "IScriptEnvironment.h"
#include "vs_it.h"
