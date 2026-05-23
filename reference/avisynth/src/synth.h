// original IT0051 by thejam79
#ifndef IT_SYNTH_H
#define IT_SYNTH_H

#pragma warning (push,1)
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include <memory>
#include <limits.h>
#include <string.h>
#include <intrin.h>
#include "avisynth.h"
#include "info.h"
#pragma warning (pop)

#pragma warning( disable : 4035 )

///////////////////////////////////////////////////////////////////////////
#ifndef _MM_SHUFFLE
#define _MM_SHUFFLE(z, y, x, w) (z<<6) | (y<<4) | (x<<2) | w
#endif

#define USE_MMX2 	_asm { emms } _asm { sfence }

#define FALSE 0
#define TRUE 1

//#define max __max
//#define min __min
#define min(a, b) (((a) < (b)) ? (a) : (b))
#define max(a, b) (((a) > (b)) ? (a) : (b))


typedef unsigned long Pixel;
typedef __m128i Pixel4;
typedef __m128i Vec4;


int getI(unsigned char t, unsigned char b, unsigned char c)
{
	return min(min(abs(t - c), abs(b - c)), abs(((t + b + 1) >> 1) - c));
	//	return min(abs(t - c), abs(b - c));
}

int getI2(int t, int b, int c)
{
	//	return min(min(abs(t - c), abs(b - c)), abs(((t + b + 1) >> 1) - c));
	return abs(t + b - 2 * c);
}


static inline int avg(unsigned char p1, unsigned char p2)
{
	return (p1 + p2 + 1) >> 1;
}

int min3(unsigned char p0, unsigned char p1, unsigned char p2)
{
	return min(min(p0, p1), p2);
}

int max3(unsigned char p0, unsigned char p1, unsigned char p2)
{
	return max(max(p0, p1), p2);
}

int add3(unsigned char p0, unsigned char p1, unsigned char p2)
{
	return p0 + p1 + p2;
}


inline int getY(Pixel pix) { return pix & 0xff; }
inline int getU(Pixel pix) { return (pix >> 8) & 0xff; }
inline int getV(Pixel pix) { return (pix >> 16) & 0xff; }

inline int getY1(Pixel pix) { return pix & 0xff; }
inline int getU1(Pixel pix) { return (pix >> 8) & 0xff; }
inline int getY2(Pixel pix) { return (pix >> 16) & 0xff; }
inline int getV1(Pixel pix) { return (pix >> 24) & 0xff; }

static inline int BR(int v)
{
	return max(0, min(255, v));
}

static inline int BSR(int v)
{
	return max(-128, min(127, v));
}

static int range(int v, int b, int t)
{
	return max(b, min(t, v));
}

static inline Pixel YUV2Pix(int Y, int U, int V)
{
	Y = min(255, max(0, Y));
	U = min(255, max(0, U));
	V = min(255, max(0, V));
	return Y + (U << 8) + (V << 16);
}

static inline Pixel YUYV2Pix(int Y1, int U, int Y2, int V)
{
	return BR(Y1) + (BR(U) << 8) + (BR(Y2) << 16) + (BR(V) << 24);
}

///////////////////////////////////////////////////////////////////////////
static inline Pixel darken(Pixel p1)
{
	return YUYV2Pix(getY1(p1) >> 1, getU1(p1), getY2(p1) >> 1, getV1(p1));
}

///////////////////////////////////////////////////////////////////////////
class GFilter : public GenericVideoFilter {
protected:
	int width;
	int height;
	int m_bSwap;
	int m_iField;
	PVideoFrame m_pvf[32];
	int m_ipvfIndex[32];
	int m_iMaxFrames;
	int m_iError;
public:
  GFilter(PClip _child) : GenericVideoFilter(_child) {
		width = vi.width;
		height = vi.height;
		m_bSwap = false;
		m_iField = false;
		m_iMaxFrames = vi.num_frames;
		for (int k = 0; k < 32; ++k) {
			m_pvf[k] = 0;
			m_ipvfIndex[k] = -1;
		}
	};
	PVideoFrame& __stdcall GetChildFrame(int n, IScriptEnvironment* env) {
		n = clipFrame(n);
		int fi = n % 8;
		if (m_ipvfIndex[fi] == n && !(!m_ipvfIndex[fi]))
			return m_pvf[fi];
		++m_iError;
		m_pvf[fi] = child->GetFrame(n, env);
		m_ipvfIndex[fi] = n;
		return m_pvf[fi];
	}
	inline int clipFrame(int n) {
		return max(0, min(n, m_iMaxFrames - 1));
	}
	inline int clipOutFrame(int n) {
		return max(0, min(n, vi.num_frames - 1));
	}
	inline int clipX(int x) {
		x = max(0, min(width - 1, x));
		return x;
	}
	inline int clipY(int y) {
		return max(0, min(height - 1, y));
	}
	inline int clipYH(int y) {
		return max(0, min((height >> 1) - 1, y));
	}
	inline const unsigned char* SYP(PVideoFrame &pv, int y, int plane = PLANAR_Y) {
		y = max(0, min(height - 1, y));
		if (m_bSwap)
			y = y ^ 1;
		if (plane == PLANAR_Y)
		{
			return &pv->GetReadPtr()[y * pv->GetPitch()];
		}
		else
		{
			return &pv->GetReadPtr(plane)[(((y >> 2) << 1) + (y % 2)) * pv->GetPitch(plane)];
		}
	}
	inline unsigned char* DYP(PVideoFrame &pv, int y, int plane = PLANAR_Y) {
		y = max(0, min(height - 1, y));
		if (plane == PLANAR_Y)
		{
			return pv->GetWritePtr() + y * pv->GetPitch();
		}
		else
		{
			return pv->GetWritePtr(plane) + (((y >> 2) << 1) + (y % 2)) * pv->GetPitch(plane);
		}
	}
	inline unsigned char* B2YP(unsigned char *dst, int y) {
		y = max(0, min(height - 1, y));
		return dst + y * width * 2;
	}
	inline unsigned char* BYP(unsigned char *dst, int y) {
		y = max(0, min(height - 1, y));
		return dst + y * width;
	}
};


class CBuffer {
	unsigned char *buf;
	int width, height;
};

#endif // IT_SYNTH_H
