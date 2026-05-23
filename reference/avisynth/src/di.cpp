// IT.dll v0.1.03 Copyright(C) 2002 thejam79, 2003 minamina
// Avisynth Plugin - Inverse Telecine (YUY2 and YV12 Only, IT0051 base)

// This program is free software; you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 2 of the License, or
// (at your option) any later version.
// 
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
// 
// You should have received a copy of the GNU General Public License
// along with this program; if not, write to the Free Software
// Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA

//#define DEBUG_SHOW_INTERLACE
//#define DEBUG
#include "synth.h"

const int MAX_WIDTH = 8192;

#if !defined(_WIN64)
#define rax	eax
#define rbx	ebx
#define rcx	ecx
#define rdx	edx
#define rsi	esi
#define rdi	edi
#define rbp	ebp
#else
#define rax	rax
#define rbx	rbx
#define rcx	rcx
#define rdx	rdx
#define rsi	rsi
#define rdi	rdi
#define rbp	rbp
#endif


///////////////////////////////////////////////////////////////////////////
inline int GetIV(unsigned char pC, unsigned char pT, unsigned char pB)
{
	unsigned char t = (unsigned char)min(abs(pT - pC), abs(pB - pC));
	return min(t, abs(((pB + pT + 1) >> 1) - pC));
}

inline Pixel GetPix(const unsigned char *p)
{
	return *((Pixel*)p);
}

inline void SetPix(const unsigned char *p, Pixel pix)
{
	*((Pixel*)p) = pix;
}


///////////////////////////////////////////////////////////////////////////
void memcpy16(void *dst, const void *src, int len)
{
	int len1 = len & ~0x1f;
	__asm {
		mov ecx,len1
		sar ecx,5
		mov rsi,src
		mov rdi,dst
		align 16
loop1:
		movq mm0,[rsi]
		movq mm1,[rsi+8]
		movq mm2,[rsi+16]
		movq mm3,[rsi+24]
		add rsi,32
		movntq [rdi],mm0
		movntq [rdi+8],mm1
		movntq [rdi+16],mm2
		movntq [rdi+24],mm3
		add rdi,32
		loop loop1
	}
	int len2 = len - len1;
	const unsigned char *src1 = (const unsigned char *)src;
	unsigned char *dst1 = (unsigned char *)dst;
	for (int i = 0; i < len2; ++i) {
		dst1[i] = src1[i];
	}
}


static inline int diff2(Pixel p1, Pixel p2)
{
	short iY1 = (short)getY(p1);
	short iY2 = (short)getY(p2);
//	short iU1 = getU(p1);
//	short iU2 = getU(p2);
//	short iV1 = getV(p1);
//	short iV2 = getV(p2);
	//	return max(max((iY1 - iY2),abs(iU1 - iU2)),abs(iV1 - iV2));
	//	return max(max(abs(iY1 - iY2),abs(iU1 - iU2)),abs(iV1 - iV2));
	//	return abs(iY1 - iY2) + abs(iU1 - iU2) + abs(iV1 - iV2);
	return abs(iY1 - iY2);
}


inline Pixel AvgPix(Pixel p1, Pixel p2)
{
	_asm {
		movd mm0,p1
		pavgb mm0,p2
		movd eax,mm0
	}
}



inline Pixel blend(Pixel p1, Pixel p2, Pixel p3)
{
	_asm {
		movd mm0,p1
		pavgb mm0,p3
		pavgb mm0,p2
		movd eax,mm0
	}
}

inline Pixel larp(Pixel p1, Pixel p2, int v1, int v2)
{
	__asm {
		pxor mm7,mm7
		movd mm0,p1
		movd mm1,p2
		punpcklbw mm0,mm7
		movd mm2,v1
		punpcklbw mm1,mm7
		movd mm3,v2
		pshufw mm2,mm2,0
		pshufw mm3,mm3,0
		pmullw mm0,mm2
		pmullw mm1,mm3
		paddw mm0,mm1
		psrlw mm0,7
		packuswb mm0,mm7
		movd eax,mm0
	}
}

///////////////////////////////////////////////////////////////////////////
inline Pixel CubicInterpolation(Pixel pixTTT, Pixel pixT, Pixel pixB, Pixel pixBBB) 
{
	static const __int64 scale = 0x0005000500050005i64;
	_asm {
		movd mm0,pixB
		movd mm1,pixT
		movd mm2,pixBBB
		movd mm3,pixTTT
		pxor mm7,mm7
		punpcklbw mm0,mm7
		punpcklbw mm1,mm7
		punpcklbw mm2,mm7
		punpcklbw mm3,mm7
		paddw mm0,mm1
		paddw mm2,mm3
		pmullw mm0,scale
		psubw mm0,mm2
		psraw mm0,3
		packuswb mm0,mm7
		movd eax,mm0
	}
	/*
	short Y = (5 * (getY(pixB) + getY(pixT)) - (getY(pixBBB) + getY(pixTTT))) >> 3;
	short U = (5 * (getU(pixB) + getU(pixT)) - (getU(pixBBB) + getU(pixTTT))) >> 3;
	short V = (5 * (getV(pixB) + getV(pixT)) - (getV(pixBBB) + getV(pixTTT))) >> 3;
	return YUV2Pix(Y, U, V);
	*/
}

///////////////////////////////////////////////////////////////////////////
class CFrameInfo {
public:
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

class CTFblockInfo {
public:
	int cfi;
	char level;
	char itype;
};


class IT : public GFilter {
private:
	enum
	{
		DI_MODE_NONE,
		DI_MODE_DEINTERLACE,
		DI_MODE_SIMPLE_BLUR,
		DI_MODE_ONE_FIELD,
		DI_MODE_END,
		DI_MODE_DEINTERLACE_B,
	};
	int m_iDiMode;
	CFrameInfo *m_frameInfo;
	CTFblockInfo *m_blockInfo;
	enum { REF_NONE, REF_ALL, REF_PREV, REF_NEXT, REF_AUTO } m_eRef, m_eRefInit;
	int m_iUseFrame;
	int m_bDebug;
	bool m_bBlend;
	int m_iPThreshold;
	int m_iThreshold;
	bool m_bReadLog, m_bWriteLog;
	int m_iCurrentFrame;
	int m_iCounter;
	int m_iFPS;
	bool m_bRefP, m_bRefN;
	int m_iUsePrev, m_iUseNext;

	FILE *m_fpLog;
	char *m_szLogFile;

	unsigned char *m_edgeMap, *m_motionMap4DI, *m_motionMap4DIMax;

	long m_iSumC, m_iSumP, m_iSumN, m_iSumM;
	long m_iSumPC, m_iSumPP, m_iSumPN, m_iSumPM;

	PVideoFrame m_PVOut[8];
	int m_iPVOutIndex[8];

	int m_iRealFrame;
	IScriptEnvironment* m_env;
public:
	static AVSValue __cdecl Create(AVSValue args, void* /*user_data*/, IScriptEnvironment* env) {
		return new IT(args[0].AsClip(), 
													 args[1].AsInt(24), 
													 args[2].AsInt(20), 
													 args[3].AsInt(75), 
													 args[4].AsString("TOP"), 
													 args[5].AsBool(false), 
													 args[6].AsBool(false), 
													 args[7].AsString(NULL), 
													 args[8].AsString(NULL), 
													 args[9].AsString(NULL), 
													 args[10].AsInt(DI_MODE_DEINTERLACE),
													 env);
	}

	PVideoFrame __stdcall GetFrame(int n, IScriptEnvironment* env);
	IT(PClip _child, 
							int _fps,
							int _threshold, int _pthreshold, const char *_ref,
							bool _blend, 
							bool _debug, 
							const char *_read,
							const char *_write,
							const char *_log,
							int _dimode,
							IScriptEnvironment* env) : 
		GFilter(_child) , 
		m_iFPS(_fps), 
		m_iThreshold(_threshold), 
		m_iPThreshold(_pthreshold), 
		m_bBlend(_blend),
		m_bDebug(_debug),
		m_iDiMode(_dimode)
	{
		if (stricmp(_ref, "ALL") == 0) {
			m_eRef = REF_ALL;
			//		} else if (stricmp(_ref, "AUTO") == 0) {
			//			m_eRef = REF_AUTO;
		} else if (stricmp(_ref, "TOP") == 0) {
			m_eRef = REF_PREV;
		} else if (stricmp(_ref, "BOTTOM") == 0) {
			m_eRef = REF_NEXT;
		} else if (stricmp(_ref, "NONE") == 0) {
			m_eRef = REF_NONE;
		} else {
			env->ThrowError("IT:illegal option");
		}
		if (m_iFPS != 24) {
			m_bBlend = false;
		}

		m_iCounter = 0;
		m_iError = 0;
		width = vi.width;
		height = vi.height;
		m_eRefInit = m_eRef;
		m_iUsePrev = m_iUseNext = 0;
		m_bReadLog = false;
		m_bWriteLog = false;

		m_iPThreshold = AdjPara(m_iPThreshold);

		if (vi.IsYUY2() || vi.IsYV12()) {
		} else {
			env->ThrowError("IT:YUY2 or YV12 data only");
		}
		if (width & 15) {
			env->ThrowError("IT:width size must be even");
		}
		if (height & 1) {
			env->ThrowError("IT:height size must be even");
		}
		m_frameInfo = new CFrameInfo[m_iMaxFrames + 6];

		int i;
		for (i = 0; i < 8; ++i) {
			m_PVOut[i] = 0;
			m_iPVOutIndex[i] = -1;
		}
		for (i = 0; i < m_iMaxFrames + 6; ++i) {
			m_frameInfo[i].match = 'U';
			m_frameInfo[i].matchAcc = 'U';
			m_frameInfo[i].pos = 'U';
			m_frameInfo[i].ip = 'U';
			m_frameInfo[i].mflag = 'U';
			m_frameInfo[i].diffP0 = -1;
			m_frameInfo[i].diffP1 = -1;
		}
		m_blockInfo = new CTFblockInfo[m_iMaxFrames / 5 + 6];
		for (i = 0; i < m_iMaxFrames / 5 + 1; ++i) {
			m_blockInfo[i].level = 'U';
			m_blockInfo[i].itype = 'U';
		}

		m_edgeMap = new unsigned char[width * height];
		//		m_motionMap = new unsigned char[width * height];
		memset(m_edgeMap, width * height, 0);
		//		memset(m_motionMap, width * height, 0);

		m_motionMap4DI = new unsigned char[width * height];
		memset(m_motionMap4DI, width * height, 0);

		m_motionMap4DIMax = new unsigned char[width * height];
		ZeroMemory(m_motionMap4DI, width * height);

		m_iSumC = m_iSumP = m_iSumN = 0;
		m_iUsePrev = m_iUseNext = 0;
		m_eRef = m_eRefInit;

		if (m_iFPS == 24) {
			vi.num_frames = vi.num_frames * (5 - 1) / 5;
			vi.SetFPS(vi.fps_numerator * (5 - 1), vi.fps_denominator * 5);
		}

		if (_read != NULL) {
			if (_write != NULL || _log != NULL)
				env->ThrowError("IT:illegal option");
			m_szLogFile = _strdup(_read);
			m_bReadLog = true;
			ReadLog();
		}
		if (_write != NULL) {
			if (_read != NULL || _log != NULL)
				env->ThrowError("IT:illegal option");
			m_szLogFile = _strdup(_write);
			m_bWriteLog = true;

			m_fpLog = fopen(m_szLogFile, "wt");
			if (m_fpLog == NULL)
				env->ThrowError("IT:can't open log file");
		}
		if (_log != NULL) {
			if (_read != NULL || _write != NULL)
				env->ThrowError("IT:illegal option");
			m_szLogFile = _strdup(_log);

			m_fpLog = fopen(m_szLogFile, "rt");
			if (m_fpLog == NULL) {
				m_fpLog = fopen(m_szLogFile, "wt");
				if (m_fpLog == NULL) {
					env->ThrowError("IT:can't open log file");
				} else {
					m_bWriteLog = true;
				}
			} else {
				m_bReadLog = true;
				fclose(m_fpLog);
				ReadLog();
			}
		}
		if (!(DI_MODE_NONE <= m_iDiMode && m_iDiMode < DI_MODE_END))
		{
			m_iDiMode = DI_MODE_DEINTERLACE;
		}
	}
	~IT() {
		if (m_bWriteLog)
			WriteLog();
		//		fclose(m_fpLog);
		delete [] m_frameInfo;
		delete [] m_blockInfo;
		delete [] m_edgeMap;
		//		delete [] m_motionMap;
		delete [] m_motionMap4DI;
		delete [] m_motionMap4DIMax;
	}

	bool CheckSceneChange(int n);
	void GetFrameSub(int n, IScriptEnvironment* env);
	void __stdcall EvalIV(int n, PVideoFrame &ref, long &counter, long &counterp, IScriptEnvironment* env);
	void __stdcall EvalIV_YV12(int n, PVideoFrame &ref, long &counter, long &counterp, IScriptEnvironment* env);
	void __stdcall MakeDEmap(PVideoFrame &ref, int offset);
	void __stdcall MakeDEmap_YV12(PVideoFrame &ref, int offset);
	void __stdcall MakeMotionMap(int fno, bool flag);
	void __stdcall MakeMotionMap_YV12(int fno, bool flag);
	void __stdcall MakeMotionMap2(int fno, bool flag);
	void __stdcall MakeMotionMap2_YV12(int fno, bool flag);
	void __stdcall MakeMotionMap2Max(int fno, bool flag);
	void __stdcall MakeMotionMap2Max_YV12(int fno, bool flag);
	void __stdcall MakeSimpleBlurMap(int fno, bool flag);
	void __stdcall MakeSimpleBlurMap_YV12(int fno, bool flag);
	void __stdcall CopyCPNField(PVideoFrame &dst, int n, IScriptEnvironment* env);
	void __stdcall Deinterlace(PVideoFrame &dst, int n, int nParameterMode = DI_MODE_DEINTERLACE);
	void __stdcall Deinterlace_YV12(PVideoFrame &dst, int n, int nParameterMode = DI_MODE_DEINTERLACE);
	void __stdcall SimpleBlur(PVideoFrame &dst, int n);
	void __stdcall SimpleBlur_YV12(PVideoFrame &dst, int n);
	void __stdcall DeintOneField(PVideoFrame &dst, int n);
	void __stdcall DeintOneField_YV12(PVideoFrame &dst, int n);
	void __stdcall ShowInterlaceArea(PVideoFrame &dst, int n);
	void __stdcall ShowDifference();
	void __stdcall ChooseBest(int n, IScriptEnvironment* env);
	bool __stdcall CompCP();
	bool __stdcall CompCN();
	void __stdcall Decide(int n, IScriptEnvironment* env);
	void __stdcall SetFT(int base, int n, char c);
	void __stdcall ReadLog();
	void __stdcall WriteLog();
	void __stdcall BlendFrame(PVideoFrame &dst, int base, int n);
	void __stdcall BlendFrame_YV12(PVideoFrame &dst, int base, int n);
	bool __stdcall DrawPrevFrame(PVideoFrame& dst, int n);
	PVideoFrame __stdcall MakeOutput(PVideoFrame &dst, int n, IScriptEnvironment* env);
	int GetDiffVal(int n, int p = 0) {
		if (p == 0)
			return m_frameInfo[clipFrame(n)].diffP0;
		else
			return m_frameInfo[clipFrame(n)].diffS0;
	}
	int AdjPara(int v) {
		return (((v * width) / 720) * height) / 480;
	}
	void __stdcall PrintDebugInfo(PVideoFrame &dst, int n);
};

void IT::ReadLog()
{
	m_fpLog = fopen(m_szLogFile, "rt");
	if (m_fpLog == NULL) {
		throw AvisynthError("IT:can't open log file");
		return;
	}

	char buf[0x400];
	char match[1024], mflag[1024], ip[1024];
	int i;
	//	while(fscanf(m_fpLog, "%d %s %s %s\n", i, match, mflag, ip)) {
	while(fgets(buf, 0x400, m_fpLog)) {
		//	fclose(m_fpLog);
		//		return;

		//		fgets(buf, 0x400, m_fpLog)) {
		//		fsscanf(fp, "%d %s %s %s\n", i, match, mflag, ip);
		sscanf(buf, "%d %s %s %s", &i, match, mflag, ip);
		for (int j = 0; j < 5; ++j) {
			if (i + j < m_iMaxFrames) {
				m_frameInfo[i + j].match = match[j];
				m_frameInfo[i + j].mflag = mflag[j];
				m_frameInfo[i + j].ip = ip[j];
				m_blockInfo[(i + j) / 5].level = '0';

			}
		}
	}
}

void IT::WriteLog()
{
	if (m_fpLog == NULL)
		throw AvisynthError("IT:can't open log file");
	for (int i = 0; i < m_iMaxFrames; i += 5) {
		char match[6], mflag[6], ip[6];
		match[5] = 0;
		mflag[5] = 0;
		ip[5] = 0;

		for (int j = 0; j < 5; ++j) {
			if (i + j < m_iMaxFrames) {
				match[j] = m_frameInfo[i + j].match;
				mflag[j] = m_frameInfo[i + j].mflag;
				ip[j] = m_frameInfo[i + j].ip;
			} else {
				match[j] = '*';
				mflag[j] = '*';
				ip[j] = '*';
			}
		}
		fprintf(m_fpLog, "%7d %s %s %s\n", i, match, mflag, ip);
	}
	fclose(m_fpLog);
}

///////////////////////////////////////////////////////////////////////////
void IT::MakeDEmap(PVideoFrame &ref, int offset)
{
	const __int64 maskY = 0x00ff00ff00ff00ffi64;
	const int twidth = width;

	for(int yy = 0; yy < height; yy += 2) {
		int y = yy + offset;
		const unsigned char *pTT = SYP(ref, y - 2);
		const unsigned char *pC = SYP(ref, y);
		const unsigned char *pBB = SYP(ref, y + 2);
		unsigned char *pED = m_edgeMap + y * width;
		__asm {
			pxor mm7,mm7
			movq mm6,maskY
			mov rbx,pTT
			mov rax,pC
			mov rcx,pBB
			mov rdi,pED
			xor esi,esi
			align 16
loopA:
			prefetchnta [rax+rsi*2+16]
			prefetchnta [rbx+rsi*2+16]
			prefetchnta [rcx+rsi*2+16]
			movq mm1,[rbx+rsi*2]
			movq mm3,[rbx+rsi*2+8]
			movq mm0,[rax+rsi*2]
			movq mm2,[rax+rsi*2+8]
			pavgb mm1,[rcx+rsi*2]
			pavgb mm3,[rcx+rsi*2+8]
			psubusb mm0,mm1
			psubusb mm2,mm3
			psubusb mm1,[rax+rsi*2]
			psubusb mm3,[rax+rsi*2+8]
			por mm0,mm1
			por mm2,mm3

			movq mm1,mm0
			pshufw mm4,mm0,_MM_SHUFFLE(2, 3, 0, 1)
			psrld mm1,8
			pmaxub mm0,mm1
			psrld mm4,8
			pmaxub mm0,mm4

			movq mm1,mm2
			pshufw mm4,mm2,_MM_SHUFFLE(2, 3, 0, 1)
			psrld mm1,8
			pmaxub mm2,mm1
			psrld mm4,8
			pmaxub mm2,mm4

			pand mm0,mm6
			pand mm2,mm6
			packuswb mm0,mm7
			lea rsi,[rsi+8]
			packuswb mm2,mm7
			cmp esi,twidth
			punpckldq mm0,mm2
			movntq [rdi+rsi-8],mm0
			jl loopA
		}
		/*
		for (int x = 0; x < width; ++x) {
			int k = x * 2;
			int vy = abs(pC[k] - avg(pTT[k], pBB[k]));
			int vu, vv;
			if ((x & 1) == 0) {
				vu = abs(pC[k + 1] - avg(pTT[k + 1], pBB[k + 1]));
				vv = abs(pC[k + 3] - avg(pTT[k + 3], pBB[k + 3]));
			} else {
				vu = abs(pC[k - 1] - avg(pTT[k - 1], pBB[k - 1]));
				vv = abs(pC[k + 1] - avg(pTT[k + 1], pBB[k + 1]));
			}
			if (max(vy, max(vu, vv)) != pED[x])
				throw AvisynthError("AviUtlFilterProxy: error calling startProc");
		}
		*/
	}
}

#define MAKE_DE_MAP_ASM_INIT(C, TT, BB) \
	__asm mov rax,C \
	__asm mov rbx,TT \
	__asm mov rcx,BB

#define MAKE_DE_MAP_ASM(mmm, step, offset) \
	__asm movq mm7,[rbx+rsi*step+offset] \
	__asm movq mmm,[rax+rsi*step+offset] \
	__asm pavgb mm7,[rcx+rsi*step+offset] \
	__asm psubusb mmm,mm7 \
	__asm psubusb mm7,[rax+rsi*step+offset] \
	__asm por mmm,mm7

///////////////////////////////////////////////////////////////////////////
void IT::MakeDEmap_YV12(PVideoFrame &ref, int offset)
{
	const int twidth = width >> 1;

	for(int yy = 0; yy < height; yy += 2) {
		int y = yy + offset;
		const unsigned char *pTT = SYP(ref, y - 2);
		const unsigned char *pC = SYP(ref, y);
		const unsigned char *pBB = SYP(ref, y + 2);
		const unsigned char *pTT_U = SYP(ref, y - 2, PLANAR_U);
		const unsigned char *pC_U = SYP(ref, y, PLANAR_U);
		const unsigned char *pBB_U = SYP(ref, y + 2, PLANAR_U);
		const unsigned char *pTT_V = SYP(ref, y - 2, PLANAR_V);
		const unsigned char *pC_V = SYP(ref, y, PLANAR_V);
		const unsigned char *pBB_V = SYP(ref, y + 2, PLANAR_V);
		unsigned char *pED = m_edgeMap + y * width;
		__asm {
			mov rdi,pED
			xor esi,esi
			align 16
loopA:
			MAKE_DE_MAP_ASM_INIT(pC, pTT, pBB)
			MAKE_DE_MAP_ASM(mm0, 2, 0)
			MAKE_DE_MAP_ASM(mm3, 2, 8)
			MAKE_DE_MAP_ASM_INIT(pC_U, pTT_U, pBB_U)
			MAKE_DE_MAP_ASM(mm1, 1, 0)
			MAKE_DE_MAP_ASM(mm4, 1, 4)
			MAKE_DE_MAP_ASM_INIT(pC_V, pTT_V, pBB_V)
			MAKE_DE_MAP_ASM(mm2, 1, 0)
			MAKE_DE_MAP_ASM(mm5, 1, 4)

			pmaxub mm2,mm1
			pmaxub mm5,mm4
			punpcklbw mm2,mm2
			punpcklbw mm5,mm5
			pmaxub mm0,mm2
			pmaxub mm3,mm5

			lea esi,[esi+8]
			movntq [rdi+rsi*2-16],mm0
			cmp esi,twidth
			movntq [rdi+rsi*2-8],mm3
			jl loopA
		}
	}
	USE_MMX2
}

///////////////////////////////////////////////////////////////////////////
void IT::MakeMotionMap(int n, bool flag)
{
	n = clipFrame(n);
	if (flag == false && m_frameInfo[n].diffP0 >= 0) {
		return;
	}
	if (m_frameInfo[n].diffP0 >= 0) {
		++m_iError;
		//		throw AvisynthError("AviUtlFilterProxy: error calling startProc");
	}

	const __int64 maskY = 0x00ff00ff00ff00ffi64;
	const __int64 mask1 = 0x0101010101010101i64;

	const int twidth = width;
	const int widthminus8 = width - 8;
	const int widthminus16 = width - 16;
	unsigned short th[4], th2[4];
	unsigned char mbTh[8], mbTh2[8];
	int i;
	for (i = 0; i < 4; ++i) {
		th[i] = 12 * 3;
		th2[i] = 6 * 3;
		//		th2[i] = 12;
	}
	for (i = 0; i < 8; ++i) {
		mbTh[i] = 12 * 3;
		mbTh2[i] = 6 * 3;
	}


	PVideoFrame &srcP = GetChildFrame(n - 1, m_env);
	PVideoFrame &srcC = GetChildFrame(n, m_env);
//	PVideoFrame &srcN = GetChildFrame(n + 1, m_env);
	__declspec(align(16)) short bufP0[MAX_WIDTH];
	__declspec(align(16)) unsigned char bufP1[MAX_WIDTH];
	int pe0 = 0, po0 = 0, pe1 = 0, po1 = 0;
	for(int yy = 16; yy < height - 16; ++yy) {
		int y = yy;
		const unsigned char *pC = SYP(srcC, y);
		const unsigned char *pP = SYP(srcP, y);
//		const unsigned char *pN = SYP(srcN, y);
		//		unsigned char *pD = m_motionMap + y * width;
		{
			_asm {
				pxor mm7,mm7
				movq mm6,maskY
				mov rax,pC
				mov rbx,pP
				lea rdi,bufP0
				xor esi,esi
				align 16
loopA:
				prefetchnta [rax+rsi*2+16]
				prefetchnta [rbx+rsi*2+16]
				movq mm0,[rax+rsi*2]
				movq mm1,[rbx+rsi*2]
				pand mm0,mm6
				pand mm1,mm6
				lea esi,[esi+4]
				psubw mm0,mm1
				cmp esi,twidth
				movntq [rdi+rsi*2-8],mm0
				jl loopA
			}
			/*
			for(int x = 0; x < width; ++x) {
				int k = x * 2;
				//				int valP = min(max(-128, pC[k] - pP[k]), 127);
				int valP = (pC[k] - pP[k]);
				if (bufP0[x] != valP)
					throw AvisynthError("AviUtlFilterProxy: error calling startProc");
				//				bufP0[x] = BR(valP + 128);
			}
			*/
		}
		{
			_asm {
				lea rax,bufP0
				lea rdi,bufP1
				mov esi,8
				align 16
loopB:
				prefetchnta [rax+rsi+16]
				movq mm0,[rax+rsi*2-2]
				movq mm1,mm7
				paddw mm0,[rax+rsi*2+2]
				movq mm2,[rax+rsi*2]
				psubw mm0,mm2
				movq mm3,mm7
				psubw mm0,mm2
				psubw mm3,mm2
				psubw mm1,mm0
				pmaxsw mm2,mm3
				pmaxsw mm0,mm1
				lea esi,[esi+4]
				psubusw mm2,mm0
				cmp esi,widthminus8
				packuswb mm2,mm7
				movd [rdi+rsi-4],mm2
				jl loopB
			}
			/*
			for(int x = 8; x < width - 8; ++x) {
				int dxP = abs(bufP0[x + 1] + bufP0[x - 1] - 2 *  bufP0[x]);
				int valP = abs(bufP0[x]);
				valP = max(0, valP - dxP);
				if (bufP1[x] != valP)
					throw AvisynthError("AviUtlFilterProxy: error calling startProc");
				bufP1[x] = valP;
			}
			*/
		}
		int tsum = 0, tsum1 = 0;
		{
			//			unsigned char sum[8];
			//			unsigned char sum[8];
			_asm {
				movq mm5,mbTh
					//				movq mm4,mask1
				lea rax,bufP1
				mov esi,16
					//				mov rdi,pD
				pxor mm4,mm4
				pxor mm3,mm3
				align 16
loopC:
				prefetchnta [rax+rsi+16]
				movq mm0,[rax+rsi-1]
				paddusb mm0,[rax+rsi+1]
				paddusb mm0,[rax+rsi]
				movq mm1,mm0
				psubusb mm0,mm5
				psubusb mm1,mbTh2
				pcmpeqb mm0,mm7
				pcmpeqb mm1,mm7
				pcmpeqb mm0,mm7
				pcmpeqb mm1,mm7
					//				movntq [rdi+rsi],mm0
				lea esi,[esi+8]
				pand mm0,mask1
				pand mm1,mask1
				cmp esi,widthminus16
				paddb mm4,mm0
				paddb mm3,mm1
				jl loopC
				
				psadbw mm4,mm7
				movd tsum,mm4

				psadbw mm3,mm7
				movd tsum1,mm3
			}
			/*
			int cnt = 0, cnt2 = 0;
			for(int x = 16; x < width - 16; ++x) {
				int p = bufP1[x - 1] + bufP1[x] + bufP1[x + 1];
				if (p > 12 * 3) {
					++cnt;
					if (pD[x] != 0xff)
						throw AvisynthError("AviUtlFilterProxy: error calling startProc");
				} else {
					if (pD[x] != 0x00)
						throw AvisynthError("AviUtlFilterProxy: error calling startProc");
				}
				if (p > 6 * 3) {
					++cnt2;
				}
			}
			if (cnt != tsum)
				throw AvisynthError("AviUtlFilterProxy: error calling startProc");
			if (cnt2 != tsum1)
				throw AvisynthError("AviUtlFilterProxy: error calling startProc");
			*/
			if ((y & 1) == 0) {
				pe0 += tsum;
				pe1 += tsum1;
			} else {
				po0 += tsum;
				po1 += tsum1;
			}
		}
	}
	m_frameInfo[n].diffP0 = pe0;
	m_frameInfo[n].diffP1 = po0;
	m_frameInfo[n].diffS0 = pe1;
	m_frameInfo[n].diffS1 = po1;
	USE_MMX2
}

///////////////////////////////////////////////////////////////////////////
void IT::MakeMotionMap_YV12(int n, bool flag)
{
	n = clipFrame(n);
	if (flag == false && m_frameInfo[n].diffP0 >= 0) {
		return;
	}
	if (m_frameInfo[n].diffP0 >= 0) {
		++m_iError;
		//		throw AvisynthError("AviUtlFilterProxy: error calling startProc");
	}

//	const __int64 maskY = 0x00ff00ff00ff00ffi64;
	const __int64 mask1 = 0x0101010101010101i64;

	const int twidth = width;
	const int widthminus8 = width - 8;
	const int widthminus16 = width - 16;
	unsigned short th[4], th2[4];
	unsigned char mbTh[8], mbTh2[8];
	int i;
	for (i = 0; i < 4; ++i) {
		th[i] = 12 * 3;
		th2[i] = 6 * 3;
		//		th2[i] = 12;
	}
	for (i = 0; i < 8; ++i) {
		mbTh[i] = 12 * 3;
		mbTh2[i] = 6 * 3;
	}


	PVideoFrame &srcP = GetChildFrame(n - 1, m_env);
	PVideoFrame &srcC = GetChildFrame(n, m_env);
//	PVideoFrame &srcN = GetChildFrame(n + 1, m_env);
	__declspec(align(16)) short bufP0[MAX_WIDTH];
	__declspec(align(16)) unsigned char bufP1[MAX_WIDTH];
	int pe0 = 0, po0 = 0, pe1 = 0, po1 = 0;
	for(int yy = 16; yy < height - 16; ++yy) {
		int y = yy;
		const unsigned char *pC = SYP(srcC, y);
		const unsigned char *pP = SYP(srcP, y);
		{
			_asm {
				pxor mm7,mm7
				mov rax,pC
				mov rbx,pP
				lea rdi,bufP0
				xor esi,esi
				align 16
loopA:
				prefetchnta [rax+rsi+16]
				prefetchnta [rbx+rsi+16]
				movd mm0,[rax+rsi]
				movd mm1,[rbx+rsi]
				punpcklbw mm0,mm7
				punpcklbw mm1,mm7
				lea esi,[esi+4]
				psubw mm0,mm1
				cmp esi,twidth
				movntq [rdi+rsi*2-8],mm0
				jl loopA
			}
		}
		{
			_asm {
				lea rax,bufP0
				lea rdi,bufP1
				mov esi,8
				align 16
loopB:
				prefetchnta [rax+rsi+16]
				movq mm0,[rax+rsi*2-2]
				movq mm1,mm7
				paddw mm0,[rax+rsi*2+2]
				movq mm2,[rax+rsi*2]
				psubw mm0,mm2
				movq mm3,mm7
				psubw mm0,mm2
				psubw mm3,mm2
				psubw mm1,mm0
				pmaxsw mm2,mm3
				pmaxsw mm0,mm1
				lea esi,[esi+4]
				psubusw mm2,mm0
				cmp esi,widthminus8
				packuswb mm2,mm7
				movd [rdi+rsi-4],mm2
				jl loopB
			}
		}
		int tsum = 0, tsum1 = 0;
		{
			//			unsigned char sum[8];
			//			unsigned char sum[8];
			_asm {
				movq mm5,mbTh
					//				movq mm4,mask1
				lea rax,bufP1
				mov esi,16
					//				mov rdi,pD
				pxor mm4,mm4
				pxor mm3,mm3
				align 16
loopC:
				prefetchnta [rax+rsi+16]
				movq mm0,[rax+rsi-1]
				paddusb mm0,[rax+rsi+1]
				paddusb mm0,[rax+rsi]
				movq mm1,mm0
				psubusb mm0,mm5
				psubusb mm1,mbTh2
				pcmpeqb mm0,mm7
				pcmpeqb mm1,mm7
				pcmpeqb mm0,mm7
				pcmpeqb mm1,mm7
					//				movntq [rdi+rsi],mm0
				lea esi,[esi+8]
				pand mm0,mask1
				pand mm1,mask1
				cmp esi,widthminus16
				paddb mm4,mm0
				paddb mm3,mm1
				jl loopC
				
				psadbw mm4,mm7
				movd tsum,mm4

				psadbw mm3,mm7
				movd tsum1,mm3
			}
			if ((y & 1) == 0) {
				pe0 += tsum;
				pe1 += tsum1;
			} else {
				po0 += tsum;
				po1 += tsum1;
			}
		}
	}
	m_frameInfo[n].diffP0 = pe0;
	m_frameInfo[n].diffP1 = po0;
	m_frameInfo[n].diffS0 = pe1;
	m_frameInfo[n].diffS1 = po1;
	USE_MMX2
}

///////////////////////////////////////////////////////////////////////////
void IT::EvalIV(int n, PVideoFrame &ref, long &counter, long &counterp, IScriptEnvironment *env)
{
	const __int64 maskY = 0x00ff00ff00ff00ffi64;
	const __int64 mask1 = 0x0101010101010101i64;
	unsigned char th[8], th2[8];
	unsigned char rsum[8], psum[8];
	unsigned short psum0[4], psum1[4];
//	const int twidth = width;

	PVideoFrame srcC = GetChildFrame(n, env);
	for (int i = 0; i < 8; ++i) {
		th[i] = 40;
		th2[i] = 6;
	}

	if (vi.IsYV12())
	{
		MakeDEmap_YV12(ref, 1);
	}
	else
	{
		MakeDEmap(ref, 1);
	}

	const int widthminus16 = width - 16;
	int sum = 0, sum2 = 0; //, sumS = 0;
	for(int yy = 16; yy < height - 16; yy += 2) {
		int y;
		if (m_iField == 0) {
			y = yy + 1;
		} else {
			y = yy + 0;
		}
		const unsigned char *pT = SYP(srcC, y - 1);
		const unsigned char *pC = SYP(ref, y);
		const unsigned char *pB = SYP(srcC, y + 1);

		const unsigned char *peT = &m_edgeMap[clipY(y - 1) * width];
		const unsigned char *peC = &m_edgeMap[clipY(y) * width];
		const unsigned char *peB = &m_edgeMap[clipY(y + 1) * width];

		//		unsigned char *pmW = m_pImap + width * y;
		__asm {
			pxor mm7,mm7
			movq mm6,maskY
			mov rbx,pT
			mov rax,pC
			mov rcx,pB
				//			mov rdi,pmW
			mov esi,16

			movq rsum,mm7
			movq psum,mm7
			movq psum0,mm7
			movq psum1,mm7
			align 16
loopB:
			prefetchnta [rax+rsi*2+16]
			prefetchnta [rbx+rsi*2+16]
			prefetchnta [rcx+rsi*2+16]
				// comb 0
			movq mm0,[rax+rsi*2]
			movq mm1,[rbx+rsi*2]
			movq mm2,mm0
			movq mm4,mm0
			psubusb mm0,[rbx+rsi*2]
			psubusb mm1,mm2
			movq mm3,[rcx+rsi*2]
			por mm0,mm1

			movq mm1,[rbx+rsi*2]
			psubusb mm3,mm2
			pavgb mm1,[rcx+rsi*2]
			psubusb mm2,[rcx+rsi*2]
			psubusb mm4,mm1
			por mm2,mm3
			psubusb mm1,[rax+rsi*2]
			pminub mm0,mm2
			por mm1,mm4
			movq mm5,[rax+rsi*2+8]
			pminub mm0,mm1

			movq mm2,mm0
			pshufw mm3,mm0,_MM_SHUFFLE(2, 3, 0, 1)
			psrld mm2,8
			pmaxub mm0,mm2
			psrld mm3,8
			pmaxub mm0,mm3


			movq mm2,mm5
			pand mm0,mm6
			movq mm4,mm5
			packuswb mm0,mm7

				// comb 1
			movq mm1,[rbx+rsi*2+8]
			psubusb mm5,[rbx+rsi*2+8]
			psubusb mm1,mm2
			movq mm3,[rcx+rsi*2+8]
			por mm5,mm1
			movq mm1,[rbx+rsi*2+8]
			psubusb mm3,mm2
			pavgb mm1,[rcx+rsi*2+8]
			psubusb mm2,[rcx+rsi*2+8]
			psubusb mm4,mm1
			por mm2,mm3
			psubusb mm1,[rax+rsi*2+8]
			pminub mm5,mm2
			por mm1,mm4
			mov rdx,peC
			pminub mm5,mm1

			movq mm2,mm5
			pshufw mm3,mm5,_MM_SHUFFLE(2, 3, 0, 1)
			psrld mm2,8
			pmaxub mm5,mm2
			psrld mm3,8
			pmaxub mm5,mm3


			movq mm3,[rdx+rsi]
			pand mm5,mm6

			mov rdx,peT
			packuswb mm5,mm7
			pmaxub mm3,[rdx+rsi]
			punpckldq mm0,mm5
			mov rdx,peB
			pmaxub mm3,[rdx+rsi]
			movq mm1,mm0
			psubusb mm0,mm3
			psubusb mm0,mm3

				///
			mov rdx,peC
				//			psubusb mm1,[edx+esi]
			psubusb mm1,mm3
			psubusb mm1,mm3

			psubusb mm0,th
			pcmpeqb mm0,mm7
			pcmpeqb mm0,mm7
			pand mm0,mask1
			paddusb mm0,rsum
			movq rsum,mm0

			psubusb mm1,th2
			pcmpeqb mm1,mm7
			pcmpeqb mm1,mm7
			pand mm1,mask1
			paddusb mm1,psum
			movq psum,mm1

			lea esi,[esi+8]
			cmp esi,widthminus16
			jl loopB
		}
		sum += rsum[0] + rsum[1] + rsum[2] + rsum[3] + rsum[4] + rsum[5] + rsum[6] + rsum[7]; 
		sum2 += psum[0] + psum[1] + psum[2] + psum[3] + psum[4] + psum[5] + psum[6] + psum[7]; 
		//		sum2 += psum0[0] + psum0[1] + psum0[2] + psum0[3]; 
		//		sum2 += psum1[0] + psum1[1] + psum1[2] + psum1[3]; 
		if (sum > m_iPThreshold) {
			sum = m_iPThreshold;
			break;
		}
	}
	counter = sum;
	counterp = sum2;

	USE_MMX2
	return;
}

#define EVAL_IV_ASM_INIT(C, T, B) \
	__asm mov rax,C \
	__asm mov rbx,T \
	__asm mov rcx,B

#define EVAL_IV_ASM(mmm, step) \
	__asm movq mmm,[rax+rsi*step] \
	__asm movq mm1,[rbx+rsi*step] \
	__asm movq mm2,mmm \
	__asm movq mm4,mmm \
	__asm psubusb mmm,[rbx+rsi*step] \
	__asm psubusb mm1,mm2 \
	__asm movq mm3,[rcx+rsi*step] \
	__asm por mmm,mm1 \
	__asm movq mm1,[rbx+rsi*step] \
	__asm psubusb mm3,mm2 \
	__asm pavgb mm1,[rcx+rsi*step] \
	__asm psubusb mm2,[rcx+rsi*step] \
	__asm psubusb mm4,mm1 \
	__asm por mm2,mm3 \
	__asm psubusb mm1,[rax+rsi*step] \
	__asm pminub mmm,mm2 \
	__asm por mm1,mm4 \
	__asm pminub mmm,mm1

///////////////////////////////////////////////////////////////////////////
void IT::EvalIV_YV12(int n, PVideoFrame &ref, long &counter, long &counterp, IScriptEnvironment *env)
{
	const __int64 mask1 = 0x0101010101010101i64;
	unsigned char th[8], th2[8];
	unsigned char rsum[8], psum[8];
	unsigned short psum0[4], psum1[4];

	PVideoFrame srcC = GetChildFrame(n, env);
	for (int i = 0; i < 8; ++i) {
		th[i] = 40;
		th2[i] = 6;
	}

	if (vi.IsYV12())
	{
		MakeDEmap_YV12(ref, 1);
	}
	else
	{
		MakeDEmap(ref, 1);
	}

	const int widthminus16 = (width - 16) >> 1;
	int sum = 0, sum2 = 0; //, sumS = 0;
	for(int yy = 16; yy < height - 16; yy += 2) {
		int y;
		if (m_iField == 0) {
			y = yy + 1;
		} else {
			y = yy + 0;
		}
		const unsigned char *pT = SYP(srcC, y - 1);
		const unsigned char *pC = SYP(ref, y);
		const unsigned char *pB = SYP(srcC, y + 1);
		const unsigned char *pT_U = SYP(srcC, y - 1, PLANAR_U);
		const unsigned char *pC_U = SYP(ref, y, PLANAR_U);
		const unsigned char *pB_U = SYP(srcC, y + 1, PLANAR_U);
		const unsigned char *pT_V = SYP(srcC, y - 1, PLANAR_V);
		const unsigned char *pC_V = SYP(ref, y, PLANAR_V);
		const unsigned char *pB_V = SYP(srcC, y + 1, PLANAR_V);

		const unsigned char *peT = &m_edgeMap[clipY(y - 1) * width];
		const unsigned char *peC = &m_edgeMap[clipY(y) * width];
		const unsigned char *peB = &m_edgeMap[clipY(y + 1) * width];

		//		unsigned char *pmW = m_pImap + width * y;
		__asm {
			pxor mm7,mm7
				//			mov edi,pmW
			mov esi,16

			movq rsum,mm7
			movq psum,mm7
			movq psum0,mm7
			movq psum1,mm7
			align 16
loopB:
			EVAL_IV_ASM_INIT(pC, pT, pB)
			EVAL_IV_ASM(mm0, 2)

			EVAL_IV_ASM_INIT(pC_U, pT_U, pB_U)
			EVAL_IV_ASM(mm5, 1)

			EVAL_IV_ASM_INIT(pC_V, pT_V, pB_V)
			EVAL_IV_ASM(mm6, 1)

			pmaxub mm5,mm6
			punpcklbw mm5,mm5
			pmaxub mm0,mm5			; mm0 <- max(y, max(u, v))

			mov rdx,peC
			movq mm3,[rdx+rsi*2]
			mov rdx,peT
			pmaxub mm3,[rdx+rsi*2]
			mov rdx,peB
			pmaxub mm3,[rdx+rsi*2]	; mm3 <- max(peC[x], max(peT[x], peB[x]))

			psubusb mm0,mm3
			psubusb mm0,mm3
			movq mm1,mm0

			psubusb mm0,th
			pcmpeqb mm0,mm7
			pcmpeqb mm0,mm7
			pand mm0,mask1
			paddusb mm0,rsum		; if (max - maxpe * 2 > 40) sum++
			movq rsum,mm0

			psubusb mm1,th2
			pcmpeqb mm1,mm7
			pcmpeqb mm1,mm7
			pand mm1,mask1
			paddusb mm1,psum		; if (max - maxpe * 2 > 6) sum2++
			movq psum,mm1

			lea esi,[esi+4]
			cmp esi,widthminus16
			jl loopB
		}
		sum += rsum[0] + rsum[1] + rsum[2] + rsum[3] + rsum[4] + rsum[5] + rsum[6] + rsum[7]; 
		sum2 += psum[0] + psum[1] + psum[2] + psum[3] + psum[4] + psum[5] + psum[6] + psum[7]; 
		//		sum2 += psum0[0] + psum0[1] + psum0[2] + psum0[3]; 
		//		sum2 += psum1[0] + psum1[1] + psum1[2] + psum1[3]; 
		if (sum > m_iPThreshold) {
			sum = m_iPThreshold;
			break;
		}
	}
	counter = sum;
	counterp = sum2;

	USE_MMX2
	return;
}

///////////////////////////////////////////////////////////////////////////
void IT::MakeMotionMap2(int n, bool /*flag*/)
{
	const __int64 maskY = 0x00ff00ff00ff00ffi64;
//	const __int64 mask1 = 0x0001000100010001i64;

	const int twidth = width;

	PVideoFrame srcP = GetChildFrame(n - 1, m_env);
	PVideoFrame srcC = GetChildFrame(n, m_env);
	PVideoFrame srcN = GetChildFrame(n + 1, m_env);
	for(int y = 0; y < height; y += 2) {
		unsigned char *pD = m_motionMap4DI + y * width;
		{
			const unsigned char *pC = SYP(srcC, y);
			const unsigned char *pP = SYP(srcP, y);
			const unsigned char *pN = SYP(srcN, y);
			_asm {
				pxor mm7,mm7
				movq mm6,maskY
				mov rax,pC
				mov rbx,pP
				mov rcx,pN
				mov rdi,pD
				xor esi,esi
				align 16
loopA:
				prefetchnta [rax+rsi*2+16]
				prefetchnta [rbx+rsi*2+16]
				prefetchnta [rcx+rsi*2+16]
					///P
				movq mm0,[rax+rsi*2]
				movq mm2,mm0
				movq mm1,[rbx+rsi*2]
				psubusb mm0,mm1
				psubusb mm1,mm2
				por mm0,mm1

				movq mm2,mm0
				pshufw mm3,mm0,_MM_SHUFFLE(2, 3, 0, 1)
				psrld mm2,8
				pmaxub mm0,mm2
				psrld mm3,8
				pmaxub mm0,mm3

					//				pand mm0,mm6
					//				packuswb mm0,mm7
				movq mm5,mm0

					///N
				movq mm0,[rax+rsi*2]
				movq mm2,mm0
				movq mm1,[rcx+rsi*2]
				psubusb mm0,mm1
				psubusb mm1,mm2
				por mm0,mm1

				movq mm2,mm0
				pshufw mm3,mm0,_MM_SHUFFLE(2, 3, 0, 1)
				psrld mm2,8
				pmaxub mm0,mm2
				psrld mm3,8
				pmaxub mm0,mm3

				pminub mm0,mm5
				pand mm0,mm6
				packuswb mm0,mm7
					//				movq mm5,mm0

				lea esi,[esi+4]
				cmp esi,twidth
				movd [rdi+rsi-4],mm0
				jl loopA
			}
			/*
			for(int x = 0; x < width; ++x) {
				int k = x * 2;
				int val0 = max(abs(pC[k] - pP[k]), abs(pC[k + 1] - pP[k + 1]));
				int val1 = max(abs(pC[k] - pN[k]), abs(pC[k + 1] - pN[k + 1]));
				if ((x & 1) == 0) {
					val0 = max(val0, abs(pC[k + 3] - pP[k + 3]));
					val1 = max(val1, abs(pC[k + 3] - pN[k + 3]));
				} else {
					val0 = max(val0, abs(pC[k - 1] - pP[k - 1]));
					val1 = max(val1, abs(pC[k - 1] - pN[k - 1]));
				}

				if (pD[x] != min(val0, val1))
					throw AvisynthError("AviUtlFilterProxy: error calling startProc");
				pD[x] = min(val0, val1);
			}
			*/
		}
	}
	USE_MMX2
}

#define MAKE_MOTION_MAP2_ASM_INIT(C, P) \
	__asm mov rax,C \
	__asm mov rbx,P

#define MAKE_MOTION_MAP2_ASM(mmm, step) \
	__asm movq mmm,[rax+rsi*step] \
	__asm movq mm2,mmm \
	__asm movq mm1,[rbx+rsi*step] \
	__asm psubusb mmm,mm1 \
	__asm psubusb mm1,mm2 \
	__asm por mmm,mm1

///////////////////////////////////////////////////////////////////////////
void IT::MakeMotionMap2_YV12(int n, bool /*flag*/)
{
//	const __int64 maskY = 0x00ff00ff00ff00ffi64;
//	const __int64 mask1 = 0x0001000100010001i64;

	const int twidth = width >> 1;

	PVideoFrame srcP = GetChildFrame(n - 1, m_env);
	PVideoFrame srcC = GetChildFrame(n, m_env);
	PVideoFrame srcN = GetChildFrame(n + 1, m_env);
	for(int y = 0; y < height; y += 2) {
		unsigned char *pD = m_motionMap4DI + y * width;
		{
			const unsigned char *pC = SYP(srcC, y);
			const unsigned char *pP = SYP(srcP, y);
			const unsigned char *pN = SYP(srcN, y);
			const unsigned char *pC_U = SYP(srcC, y, PLANAR_U);
			const unsigned char *pP_U = SYP(srcP, y, PLANAR_U);
			const unsigned char *pN_U = SYP(srcN, y, PLANAR_U);
			const unsigned char *pC_V = SYP(srcC, y, PLANAR_V);
			const unsigned char *pP_V = SYP(srcP, y, PLANAR_V);
			const unsigned char *pN_V = SYP(srcN, y, PLANAR_V);
			_asm {
				mov rdi,pD
				xor esi,esi
				align 16
loopA:
					///P
				MAKE_MOTION_MAP2_ASM_INIT(pC, pP)
				MAKE_MOTION_MAP2_ASM(mm0, 2)

				MAKE_MOTION_MAP2_ASM_INIT(pC_U, pP_U)
				MAKE_MOTION_MAP2_ASM(mm3, 1)

				MAKE_MOTION_MAP2_ASM_INIT(pC_V, pP_V)
				MAKE_MOTION_MAP2_ASM(mm4, 1)

				pmaxub mm3,mm4
				punpcklbw mm3,mm3
				pmaxub mm0,mm3

					///N
				MAKE_MOTION_MAP2_ASM_INIT(pC, pN)
				MAKE_MOTION_MAP2_ASM(mm5, 2)

				MAKE_MOTION_MAP2_ASM_INIT(pC_U, pN_U)
				MAKE_MOTION_MAP2_ASM(mm3, 1)

				MAKE_MOTION_MAP2_ASM_INIT(pC_V, pN_V)
				MAKE_MOTION_MAP2_ASM(mm4, 1)

				pmaxub mm3,mm4
				punpcklbw mm3,mm3
				pmaxub mm5,mm3

				pminub mm0,mm5

				lea esi,[esi+4]
				cmp esi,twidth
				movntq [rdi+rsi*2-8],mm0
				jl loopA
			}
		}
	}
	USE_MMX2
}

///////////////////////////////////////////////////////////////////////////
void IT::MakeMotionMap2Max(int n, bool /*flag*/)
{
	const __int64 maskY = 0x00ff00ff00ff00ffi64;
//	const __int64 mask1 = 0x0001000100010001i64;

	const int twidth = width;

	PVideoFrame srcP = GetChildFrame(n - 1, m_env);
	PVideoFrame srcC = GetChildFrame(n, m_env);
	PVideoFrame srcN = GetChildFrame(n + 1, m_env);
//	for(int y = 0; y < height; y += 2) {
	for(int y = 0; y < height; y++) {
		unsigned char *pD = m_motionMap4DIMax + y * width;
		{
			const unsigned char *pC = SYP(srcC, y);
			const unsigned char *pP = SYP(srcP, y);
			const unsigned char *pN = SYP(srcN, y);
			_asm {
				pxor mm7,mm7
				movq mm6,maskY
				mov rax,pC
				mov rbx,pP
				mov rcx,pN
				mov rdi,pD
				xor esi,esi
				align 16
loopA:
				prefetchnta [rax+rsi*2+16]
				prefetchnta [rbx+rsi*2+16]
				prefetchnta [rcx+rsi*2+16]
					///P
				movq mm0,[rax+rsi*2]
				movq mm2,mm0
				movq mm1,[rbx+rsi*2]
				psubusb mm0,mm1
				psubusb mm1,mm2
				por mm0,mm1

				movq mm2,mm0
				pshufw mm3,mm0,_MM_SHUFFLE(2, 3, 0, 1)
				psrld mm2,8
				pmaxub mm0,mm2
				psrld mm3,8
				pmaxub mm0,mm3

					//				pand mm0,mm6
					//				packuswb mm0,mm7
				movq mm5,mm0

					///N
				movq mm0,[rax+rsi*2]
				movq mm2,mm0
				movq mm1,[rcx+rsi*2]
				psubusb mm0,mm1
				psubusb mm1,mm2
				por mm0,mm1

				movq mm2,mm0
				pshufw mm3,mm0,_MM_SHUFFLE(2, 3, 0, 1)
				psrld mm2,8
				pmaxub mm0,mm2
				psrld mm3,8
				pmaxub mm0,mm3

//				pminub mm0,mm5
				pmaxub mm0,mm5
				pand mm0,mm6
				packuswb mm0,mm7
					//				movq mm5,mm0

				lea esi,[esi+4]
				cmp esi,twidth
				movd [rdi+rsi-4],mm0
				jl loopA
			}
		}
	}
	USE_MMX2
}

///////////////////////////////////////////////////////////////////////////
void IT::MakeMotionMap2Max_YV12(int n, bool /*flag*/)
{
	const int twidth = width >> 1;

	PVideoFrame srcP = GetChildFrame(n - 1, m_env);
	PVideoFrame srcC = GetChildFrame(n, m_env);
	PVideoFrame srcN = GetChildFrame(n + 1, m_env);

//	for(int y = 0; y < height; y += 2) {
	for(int y = 0; y < height; y++) {
		unsigned char *pD = m_motionMap4DIMax + y * width;
//		unsigned char *pDB = m_motionMap4DIMax + (y + 1) * width;
		{
			const unsigned char *pC = SYP(srcC, y);
			const unsigned char *pP = SYP(srcP, y);
			const unsigned char *pN = SYP(srcN, y);
			const unsigned char *pC_U = SYP(srcC, y, PLANAR_U);
			const unsigned char *pP_U = SYP(srcP, y, PLANAR_U);
			const unsigned char *pN_U = SYP(srcN, y, PLANAR_U);
			const unsigned char *pC_V = SYP(srcC, y, PLANAR_V);
			const unsigned char *pP_V = SYP(srcP, y, PLANAR_V);
			const unsigned char *pN_V = SYP(srcN, y, PLANAR_V);

			_asm {
				mov rdi,pD
				xor esi,esi
				align 16
loopA:
					///P
				MAKE_MOTION_MAP2_ASM_INIT(pC, pP)
				MAKE_MOTION_MAP2_ASM(mm0, 2)

				MAKE_MOTION_MAP2_ASM_INIT(pC_U, pP_U)
				MAKE_MOTION_MAP2_ASM(mm3, 1)

				MAKE_MOTION_MAP2_ASM_INIT(pC_V, pP_V)
				MAKE_MOTION_MAP2_ASM(mm4, 1)

				pmaxub mm3,mm4
				punpcklbw mm3,mm3
				pmaxub mm0,mm3

					///N
				MAKE_MOTION_MAP2_ASM_INIT(pC, pN)
				MAKE_MOTION_MAP2_ASM(mm5, 2)

				MAKE_MOTION_MAP2_ASM_INIT(pC_U, pN_U)
				MAKE_MOTION_MAP2_ASM(mm3, 1)

				MAKE_MOTION_MAP2_ASM_INIT(pC_V, pN_V)
				MAKE_MOTION_MAP2_ASM(mm4, 1)

				pmaxub mm3,mm4
				punpcklbw mm3,mm3
				pmaxub mm5,mm3

//				pminub mm0,mm5
				pmaxub mm0,mm5

				lea esi,[esi+4]
				cmp esi,twidth
				movntq [rdi+rsi*2-8],mm0
				jl loopA
			}
		}
	}
	USE_MMX2
}

// mmA <- abs(mmA - mmB)
#define MAKE_BLUR_MAP_ASM(mmA, mmB) \
	__asm movq mm7,mmA \
	__asm psubusb mmA,mmB \
	__asm psubusb mmB,mm7 \
	__asm por mmA,mmB

///////////////////////////////////////////////////////////////////////////
void IT::MakeSimpleBlurMap(int n, bool /*flag*/)
{
	const __int64 maskY = 0x00ff00ff00ff00ffi64;

	int twidth = width;
	PVideoFrame &srcC = GetChildFrame(n, m_env);
	PVideoFrame *srcR;
	switch (toupper(m_iUseFrame)) {
	default:
	case 'C':
		srcR = &srcC;
		break;
	case 'P':
		srcR = &GetChildFrame(n - 1, m_env);
		break;
	case 'N':
		srcR = &GetChildFrame(n + 1, m_env);
		break;
	}

	const unsigned char *pT;
	const unsigned char *pC;
	const unsigned char *pB;
	for(int y = 0; y < height; y++)
	{
		unsigned char *pD = m_motionMap4DI + y * width;
		{
			if (y % 2)
			{
				pT = SYP(srcC, y - 1);
				pC = SYP(*srcR, y);
				pB = SYP(srcC, y + 1);
			}
			else
			{
				pT = SYP(*srcR, y - 1);
				pC = SYP(srcC, y);
				pB = SYP(*srcR, y + 1);
			}
			_asm {
				mov rax,pC
				mov rbx,pT
				mov rcx,pB
				mov rdi,pD
				movq mm6,maskY
				xor esi,esi
				align 16
loopA:
				movq mm0,[rax+rsi*2]
				movq mm5,[rax+rsi*2+8]
				pand mm0,mm6
				pand mm5,mm6
				packuswb mm0,mm5

				movq mm1,[rbx+rsi*2]
				movq mm5,[rbx+rsi*2+8]
				pand mm1,mm6
				pand mm5,mm6
				packuswb mm1,mm5

				movq mm2,mm0
				movq mm3,mm1
				MAKE_BLUR_MAP_ASM(mm0, mm1)

				movq mm4,[rcx+rsi*2]
				movq mm5,[rcx+rsi*2+8]
				pand mm4,mm6
				pand mm5,mm6
				packuswb mm4,mm5

				movq mm1,mm4
				MAKE_BLUR_MAP_ASM(mm2, mm4)

				MAKE_BLUR_MAP_ASM(mm3, mm1)

				paddusb mm0,mm2
				psubusb mm0,mm3
				psubusb mm0,mm3

				lea esi,[esi+8]
				cmp esi,twidth
				movntq [rdi+rsi-8],mm0
				jl loopA
			}
		}
	}
	USE_MMX2
}

///////////////////////////////////////////////////////////////////////////
void IT::MakeSimpleBlurMap_YV12(int n, bool /*flag*/)
{
	int twidth = width;
	PVideoFrame &srcC = GetChildFrame(n, m_env);
	PVideoFrame *srcR;
	switch (toupper(m_iUseFrame)) {
	default:
	case 'C':
		srcR = &srcC;
		break;
	case 'P':
		srcR = &GetChildFrame(n - 1, m_env);
		break;
	case 'N':
		srcR = &GetChildFrame(n + 1, m_env);
		break;
	}

	const unsigned char *pT;
	const unsigned char *pC;
	const unsigned char *pB;
	for(int y = 0; y < height; y++)
	{
		unsigned char *pD = m_motionMap4DI + y * width;
		{
			if (y % 2)
			{
				pT = SYP(srcC, y - 1);
				pC = SYP(*srcR, y);
				pB = SYP(srcC, y + 1);
			}
			else
			{
				pT = SYP(*srcR, y - 1);
				pC = SYP(srcC, y);
				pB = SYP(*srcR, y + 1);
			}
			_asm {
				mov rax,pC
				mov rbx,pT
				mov rcx,pB
				mov rdi,pD
				xor esi,esi
				align 16
loopA:
				movq mm0,[rax+rsi]
				movq mm1,[rbx+rsi]
				movq mm2,mm0
				movq mm3,mm1
				MAKE_BLUR_MAP_ASM(mm0, mm1)

				movq mm4,[rcx+rsi]
				movq mm1,mm4
				MAKE_BLUR_MAP_ASM(mm2, mm4)

				MAKE_BLUR_MAP_ASM(mm3, mm1)

				paddusb mm0,mm2
				psubusb mm0,mm3
				psubusb mm0,mm3

				lea esi,[esi+8]
				cmp esi,twidth
				movntq [rdi+rsi-8],mm0
				jl loopA
			}
		}
	}
	USE_MMX2
}

///////////////////////////////////////////////////////////////////////////
void IT::Deinterlace(PVideoFrame &dst, int n, int nParameterMode)
{
	const __int64 maskY = 0x00ff00ff00ff00ffi64;
//	const __int64 mask1 = 0x0101010101010101i64;
	const int twidth = width;

	//	PVideoFrame &ref = GetChildFrame(n, m_env);
	PVideoFrame &srcP = GetChildFrame(n - 1, m_env);
	PVideoFrame &srcC = GetChildFrame(n, m_env);
	PVideoFrame &srcN = GetChildFrame(n + 1, m_env);

	MakeMotionMap2(m_iCurrentFrame, true);

	for(int yy = 0; yy < height; yy += 2) {
		int y;
		if (m_iField == 0) {
			y = yy + 1;
		} else {
			y = yy + 0;
		}
		memcpy(DYP(dst, y ^ 1), SYP(srcC, y ^ 1), width * 2);

		const unsigned char *pT = SYP(srcC, y - 1);
		const unsigned char *pC = SYP(srcC, y);
		const unsigned char *pB = SYP(srcC, y + 1);
		const unsigned char *pP = SYP(srcP, y);
		const unsigned char *pN = SYP(srcN, y);
		const unsigned char *pmMT = m_motionMap4DI + width * clipY(y - 1);
		const unsigned char *pmMB = m_motionMap4DI + width * clipY(y + 1);
		unsigned char *pD = DYP(dst, y);
		__declspec(align(16)) unsigned char bufC[MAX_WIDTH], bufP[MAX_WIDTH], bufCP[MAX_WIDTH], bufN[MAX_WIDTH], bufCN[MAX_WIDTH];

		_asm {
			pxor mm7,mm7
			movq mm6,maskY
			mov rbx,pT
			mov rcx,pB
			xor esi,esi
			align 16
loopX:
			//			prefetchnta [rax+rsi*2+16]
			//			prefetchnta [rbx+rsi*2+16]
			//			prefetchnta [rcx+rsi*2+16]

			mov rax,pC
			movq mm4,[rax+rsi*2]

			movq mm1,[rbx+rsi*2]
			movq mm0,mm4
			pavgb mm1,[rcx+rsi*2]
			psubusb mm0,mm1
			psubusb mm1,mm4
			pmaxub mm0,mm1

			movq mm2,mm4
			movq mm3,[rbx+rsi*2]
			psubusb mm2,[rbx+rsi*2]
			psubusb mm3,mm4
			por mm2,mm3
			pminub mm0,mm2

			movq mm2,mm4
			movq mm3,[rcx+rsi*2]
			psubusb mm2,[rcx+rsi*2]
			psubusb mm3,mm4
			por mm2,mm3
			pminub mm0,mm2
			
			movq mm1,mm0
			psrld mm0,8
			pmaxub mm0,mm1
			pshufw mm2,mm0,_MM_SHUFFLE(2, 3, 0, 1)
			pmaxub mm0,mm2
			pand mm0,mm6
			packuswb mm0,mm7
			lea rdi,bufC
			movd [rdi+rsi],mm0

				// P
			mov rax,pP
			movq mm4,[rax+rsi*2]

			movq mm1,[rbx+rsi*2]
			movq mm0,mm4
			pavgb mm1,[rcx+rsi*2]
			psubusb mm0,mm1
			psubusb mm1,mm4
			pmaxub mm0,mm1

			movq mm2,mm4
			movq mm3,[rbx+rsi*2]
			psubusb mm2,[rbx+rsi*2]
			psubusb mm3,mm4
			por mm2,mm3
			pminub mm0,mm2

			movq mm2,mm4
			movq mm3,[rcx+rsi*2]
			psubusb mm2,[rcx+rsi*2]
			psubusb mm3,mm4
			por mm2,mm3
			pminub mm0,mm2
			
			movq mm1,mm0
			psrld mm0,8
			pmaxub mm0,mm1
			pshufw mm2,mm0,_MM_SHUFFLE(2, 3, 0, 1)
			pmaxub mm0,mm2
			pand mm0,mm6
			packuswb mm0,mm7
			lea rdi,bufP
			movd [rdi+rsi],mm0

				// N
			mov rax,pN
			movq mm4,[rax+rsi*2]

			movq mm1,[rbx+rsi*2]
			movq mm0,mm4
			pavgb mm1,[rcx+rsi*2]
			psubusb mm0,mm1
			psubusb mm1,mm4
			pmaxub mm0,mm1

			movq mm2,mm4
			movq mm3,[rbx+rsi*2]
			psubusb mm2,[rbx+rsi*2]
			psubusb mm3,mm4
			por mm2,mm3
			pminub mm0,mm2

			movq mm2,mm4
			movq mm3,[rcx+rsi*2]
			psubusb mm2,[rcx+rsi*2]
			psubusb mm3,mm4
			por mm2,mm3
			pminub mm0,mm2
			
			movq mm1,mm0
			psrld mm0,8
			pmaxub mm0,mm1
			pshufw mm2,mm0,_MM_SHUFFLE(2, 3, 0, 1)
			pmaxub mm0,mm2
			pand mm0,mm6
			packuswb mm0,mm7
			lea rdi,bufN
			movd [rdi+rsi],mm0


				// PC
			mov rax,pC
			movq mm4,[rax+rsi*2]
			mov rax,pP
			pavgb mm4,[rax+rsi*2]

			movq mm1,[rbx+rsi*2]
			movq mm0,mm4
			pavgb mm1,[rcx+rsi*2]
			psubusb mm0,mm1
			psubusb mm1,mm4
			pmaxub mm0,mm1

			movq mm2,mm4
			movq mm3,[rbx+rsi*2]
			psubusb mm2,[rbx+rsi*2]
			psubusb mm3,mm4
			por mm2,mm3
			pminub mm0,mm2

			movq mm2,mm4
			movq mm3,[rcx+rsi*2]
			psubusb mm2,[rcx+rsi*2]
			psubusb mm3,mm4
			por mm2,mm3
			pminub mm0,mm2
			
			movq mm1,mm0
			psrld mm0,8
			pmaxub mm0,mm1
			pshufw mm2,mm0,_MM_SHUFFLE(2, 3, 0, 1)
			pmaxub mm0,mm2
			pand mm0,mm6
			packuswb mm0,mm7
			lea rdi,bufCP
			movd [rdi+rsi],mm0

				// CN
			mov rax,pC
			movq mm4,[rax+rsi*2]
			mov rax,pN
			pavgb mm4,[rax+rsi*2]

			movq mm1,[rbx+rsi*2]
			movq mm0,mm4
			pavgb mm1,[rcx+rsi*2]
			psubusb mm0,mm1
			psubusb mm1,mm4
			pmaxub mm0,mm1

			movq mm2,mm4
			movq mm3,[rbx+rsi*2]
			psubusb mm2,[rbx+rsi*2]
			psubusb mm3,mm4
			por mm2,mm3
			pminub mm0,mm2

			movq mm2,mm4
			movq mm3,[rcx+rsi*2]
			psubusb mm2,[rcx+rsi*2]
			psubusb mm3,mm4
			por mm2,mm3
			pminub mm0,mm2
			
			movq mm1,mm0
			psrld mm0,8
			pmaxub mm0,mm1
			pshufw mm2,mm0,_MM_SHUFFLE(2, 3, 0, 1)
			pmaxub mm0,mm2
			pand mm0,mm6
			packuswb mm0,mm7
			lea rdi,bufCN
			movd [rdi+rsi],mm0

			lea esi,[esi+4]
			cmp esi,twidth
			jl loopX
		}

		for (int x = 0; x < width; x += 2) {
			int k = x * 2;
			/*
			int u = k + 1;
			int z = k + 2;
			int v = k + 3;
			int iyc = GetIV(pC[k], pT[k], pB[k]);
			int iuc = GetIV(pC[u], pT[u], pB[u]);
			int ivc = GetIV(pC[v], pT[v], pB[v]);
			int izc = GetIV(pC[z], pT[z], pB[z]);

			int iyr = GetIV(pR[k], pT[k], pB[k]);
			int iur = GetIV(pR[u], pT[u], pB[u]);
			int ivr = GetIV(pR[v], pT[v], pB[v]);
			int izr = GetIV(pR[z], pT[z], pB[z]);

			int iym = GetIV(avg(pC[k], pR[k]), pT[k], pB[k]);
			int ium = GetIV(avg(pC[u], pR[u]), pT[u], pB[u]);
			int ivm = GetIV(avg(pC[v], pR[v]), pT[v], pB[v]);
			int izm = GetIV(avg(pC[z], pR[z]), pT[z], pB[z]);
			//1427
			int ic = max(max(iyc, izc), max(iuc, ivc));
			int ir = max(max(iyr, izr), max(iur, ivr));
			int im = max(max(iym, izm), max(ium, ivm));
			//			int ic = iyc + iuc + ivc;
			//			int ir = iyr + iur + ivr;
			//			int im = iym + ium + ivm;
			int iv;

			if (ic != bufC[x])
				throw AvisynthError("AviUtlFilterProxy: error calling startProc");
			if (ir != bufR[x])
				throw AvisynthError("AviUtlFilterProxy: error calling startProc");
			if (im != bufM[x])
				throw AvisynthError("AviUtlFilterProxy: error calling startProc");
			*/
				
			int ivc = bufC[x];
			int ivp = bufP[x];
			int ivn = bufN[x];
			int ivcp = bufCP[x];
			int ivcn = bufCN[x];
			int iv;

			Pixel pixC = GetPix(&pC[k]);
			Pixel pixN = GetPix(&pN[k]);
			Pixel pixP = GetPix(&pP[k]);

			if (ivcp < ivp) {
				pixP = AvgPix(pixC, pixP);
				ivp = ivcp;
			}
			if (ivcn < ivn) {
				pixN = AvgPix(pixC, pixN);
				ivn = ivcn;
			}
			if (ivn < ivp) {
				if (ivc < ivn) {
					SetPix(&pD[k], pixC);
					iv = ivc;
				} else {
					SetPix(&pD[k], pixN);
					iv = ivn;
				}
			} else {
				if (ivc < ivp) {
					SetPix(&pD[k], pixC);
					iv = ivc;
				} else {
					SetPix(&pD[k], pixP);
					iv = ivp;
				}
			}

			bool bDraw = false;
			if (nParameterMode == DI_MODE_DEINTERLACE)
			{
				bDraw = iv > 8 && (pmMT[x] > 12 || pmMB[x] > 12);
			}
			else
			{
				bDraw = pmMT[x] > 12 || pmMB[x] > 12;
			}
			if (bDraw)
			{
				//				pD[k + 0] = 0x80;
				//				pD[k + 1] = 0x80;
				//				pD[k + 2] = 0x80;
				//				pD[k + 3] = 0x80;
				pD[k + 0] = (unsigned char)((pT[k + 0] + pB[k + 0]) >> 1);
				pD[k + 1] = (unsigned char)((pT[k + 1] + pB[k + 1]) >> 1);
				pD[k + 2] = (unsigned char)((pT[k + 2] + pB[k + 2]) >> 1);
				pD[k + 3] = (unsigned char)((pT[k + 3] + pB[k + 3]) >> 1);
			}
		}
	}
	USE_MMX2
	return;
}

#define DEINTERLACE_ASM_1_INIT(C, T, B) \
	__asm mov rax,C \
	__asm mov rbx,T \
	__asm mov rcx,B

#define DEINTERLACE_ASM_1(mmm, step) \
	__asm movq mm4,[rax+rsi*step] \
	__asm movq mm1,[rbx+rsi*step] \
	__asm movq mmm,mm4 \
	__asm pavgb mm1,[rcx+rsi*step] \
	__asm psubusb mmm,mm1 \
	__asm psubusb mm1,mm4 \
	__asm pmaxub mmm,mm1 \
	__asm movq mm2,mm4 \
	__asm movq mm3,[rbx+rsi*step] \
	__asm psubusb mm2,[rbx+rsi*step] \
	__asm psubusb mm3,mm4 \
	__asm por mm2,mm3 \
	__asm pminub mmm,mm2 \
	__asm movq mm2,mm4 \
	__asm movq mm3,[rcx+rsi*step] \
	__asm psubusb mm2,[rcx+rsi*step] \
	__asm psubusb mm3,mm4 \
	__asm por mm2,mm3 \
	__asm pminub mmm,mm2

#define DEINTERLACE_ASM_2_INIT(C, T, B, P) \
	__asm mov rax,C \
	__asm mov rbx,T \
	__asm mov rcx,B \
	__asm mov rdx,P

#define DEINTERLACE_ASM_2(mmm, step) \
	__asm movq mm4,[rax+rsi*step] \
	__asm pavgb mm4,[rdx+rsi*step] \
	__asm movq mm1,[rbx+rsi*step] \
	__asm movq mmm,mm4 \
	__asm pavgb mm1,[rcx+rsi*step] \
	__asm psubusb mmm,mm1 \
	__asm psubusb mm1,mm4 \
	__asm pmaxub mmm,mm1 \
	__asm movq mm2,mm4 \
	__asm movq mm3,[rbx+rsi*step] \
	__asm psubusb mm2,[rbx+rsi*step] \
	__asm psubusb mm3,mm4 \
	__asm por mm2,mm3 \
	__asm pminub mmm,mm2 \
	__asm movq mm2,mm4 \
	__asm movq mm3,[rcx+rsi*step] \
	__asm psubusb mm2,[rcx+rsi*step] \
	__asm psubusb mm3,mm4 \
	__asm por mm2,mm3 \
	__asm pminub mmm,mm2

///////////////////////////////////////////////////////////////////////////
void IT::Deinterlace_YV12(PVideoFrame &dst, int n, int nParameterMode)
{
//	const __int64 maskY = 0x00ff00ff00ff00ffi64;
//	const __int64 mask1 = 0x0101010101010101i64;
	const int twidth = width >> 1;

	//	PVideoFrame &ref = GetChildFrame(n, m_env);
	PVideoFrame &srcP = GetChildFrame(n - 1, m_env);
	PVideoFrame &srcC = GetChildFrame(n, m_env);
	PVideoFrame &srcN = GetChildFrame(n + 1, m_env);

	MakeMotionMap2_YV12(m_iCurrentFrame, true);

	for(int yy = 0; yy < height; yy += 2) {
		int y;
		if (m_iField == 0) {
			y = yy + 1;
		} else {
			y = yy + 0;
		}

		const unsigned char *pT = SYP(srcC, y - 1);
		const unsigned char *pC = SYP(srcC, y);
		const unsigned char *pB = SYP(srcC, y + 1);
		const unsigned char *pP = SYP(srcP, y);
		const unsigned char *pN = SYP(srcN, y);
		const unsigned char *pT_U = SYP(srcC, y - 1, PLANAR_U);
		const unsigned char *pC_U = SYP(srcC, y, PLANAR_U);
		const unsigned char *pB_U = SYP(srcC, y + 1, PLANAR_U);
		const unsigned char *pP_U = SYP(srcP, y, PLANAR_U);
		const unsigned char *pN_U = SYP(srcN, y, PLANAR_U);
		const unsigned char *pT_V = SYP(srcC, y - 1, PLANAR_V);
		const unsigned char *pC_V = SYP(srcC, y, PLANAR_V);
		const unsigned char *pB_V = SYP(srcC, y + 1, PLANAR_V);
		const unsigned char *pP_V = SYP(srcP, y, PLANAR_V);
		const unsigned char *pN_V = SYP(srcN, y, PLANAR_V);
		const unsigned char *pmMT = m_motionMap4DI + width * clipY(y - 1);
		const unsigned char *pmMB = m_motionMap4DI + width * clipY(y + 1);
		unsigned char *pD = DYP(dst, y);
		unsigned char *pD_U = DYP(dst, y, PLANAR_U);
		unsigned char *pD_V = DYP(dst, y, PLANAR_V);
		unsigned char bufC[MAX_WIDTH], bufP[MAX_WIDTH], bufCP[MAX_WIDTH], bufN[MAX_WIDTH], bufCN[MAX_WIDTH];

		_asm {
			xor esi,esi
			align 16
loopX:
			// pC
			DEINTERLACE_ASM_1_INIT(pC, pT, pB)
			DEINTERLACE_ASM_1(mm0, 2)
			// pC_U
			DEINTERLACE_ASM_1_INIT(pC_U, pT_U, pB_U)
			DEINTERLACE_ASM_1(mm5, 1)
			// pC_V
			DEINTERLACE_ASM_1_INIT(pC_V, pT_V, pB_V)
			DEINTERLACE_ASM_1(mm6, 1)

			pmaxub mm5,mm6
			punpcklbw mm5,mm5
			pmaxub mm0,mm5

			lea rdi,bufC
			movntq [rdi+rsi*2],mm0		; bufC <- max(y, max(u, v))


			// pP
			DEINTERLACE_ASM_1_INIT(pP, pT, pB)
			DEINTERLACE_ASM_1(mm0, 2)
			// pP_U
			DEINTERLACE_ASM_1_INIT(pP_U, pT_U, pB_U)
			DEINTERLACE_ASM_1(mm5, 1)
			// pP_V
			DEINTERLACE_ASM_1_INIT(pP_V, pT_V, pB_V)
			DEINTERLACE_ASM_1(mm6, 1)

			pmaxub mm5,mm6
			punpcklbw mm5,mm5
			pmaxub mm0,mm5

			lea rdi,bufP
			movntq [rdi+rsi*2],mm0


			// pN
			DEINTERLACE_ASM_1_INIT(pN, pT, pB)
			DEINTERLACE_ASM_1(mm0, 2)
			// pN_U
			DEINTERLACE_ASM_1_INIT(pN_U, pT_U, pB_U)
			DEINTERLACE_ASM_1(mm5, 1)
			// pN_V
			DEINTERLACE_ASM_1_INIT(pN_V, pT_V, pB_V)
			DEINTERLACE_ASM_1(mm6, 1)

			pmaxub mm5,mm6
			punpcklbw mm5,mm5
			pmaxub mm0,mm5

			lea rdi,bufN
			movntq [rdi+rsi*2],mm0


			// pCP
			DEINTERLACE_ASM_2_INIT(pC, pT, pB, pP)
			DEINTERLACE_ASM_2(mm0, 2)
			
			// pCP_U
			DEINTERLACE_ASM_2_INIT(pC_U, pT_U, pB_U, pP_U)
			DEINTERLACE_ASM_2(mm5, 1)

			// pCP_V
			DEINTERLACE_ASM_2_INIT(pC_V, pT_V, pB_V, pP_V)
			DEINTERLACE_ASM_2(mm6, 1)

			pmaxub mm5,mm6
			punpcklbw mm5,mm5
			pmaxub mm0,mm5

			lea rdi,bufCP
			movntq [rdi+rsi*2],mm0


			// pCN
			DEINTERLACE_ASM_2_INIT(pC, pT, pB, pN)
			DEINTERLACE_ASM_2(mm0, 2)
			
			// pCN_U
			DEINTERLACE_ASM_2_INIT(pC_U, pT_U, pB_U, pN_U)
			DEINTERLACE_ASM_2(mm5, 1)

			// pCN_V
			DEINTERLACE_ASM_2_INIT(pC_V, pT_V, pB_V, pN_V)
			DEINTERLACE_ASM_2(mm6, 1)

			pmaxub mm5,mm6
			punpcklbw mm5,mm5
			pmaxub mm0,mm5

			lea rdi,bufCN
			movntq [rdi+rsi*2],mm0


			lea esi,[esi+4]
			cmp esi,twidth
			jl loopX
		}

		memcpy(DYP(dst, y ^ 1), SYP(srcC, y ^ 1), width);
		if ((y >> 1) % 2)
		{
			memcpy(DYP(dst, y ^ 1, PLANAR_U), SYP(srcC, y ^ 1, PLANAR_U), width >> 1);
			memcpy(DYP(dst, y ^ 1, PLANAR_V), SYP(srcC, y ^ 1, PLANAR_V), width >> 1);
		}

		for (int x = 0; x < width; x++) {				
			int ivc = bufC[x];
			int ivp = bufP[x];
			int ivn = bufN[x];
			int ivcp = bufCP[x];
			int ivcn = bufCN[x];
			int iv;

			BYTE pixC = pC[x];
			BYTE pixN = pN[x];
			BYTE pixP = pP[x];
			int x_half = x >> 1;
			if (ivcp < ivp) {
				pixP = (BYTE)avg(pixC, pixP);
				ivp = ivcp;
			}
			if (ivcn < ivn) {
				pixN = (BYTE)avg(pixC, pixN);
				ivn = ivcn;
			}
			if (ivn < ivp) {
				if (ivc < ivn) {
					pD[x] = pixC;
					iv = ivc;
				} else {
					pD[x] = pixN;
					iv = ivn;
				}
			} else {
				if (ivc < ivp) {
					pD[x] = pixC;
					iv = ivc;
				} else {
					pD[x] = pixP;
					iv = ivp;
				}
			}

			bool bDraw = false;
			if (nParameterMode == DI_MODE_DEINTERLACE)
			{
				bDraw = iv > 8 && (pmMT[x] > 12 || pmMB[x] > 12);
			}
			else
			{
//				int nPrevX = clipX(x - 1);
//				int nNextX = clipX(x + 1);
				bDraw = pmMT[x] > 12 || pmMB[x] > 12;// ||
//					pmMT[nPrevX] > 12 || pmMB[nPrevX] > 12 ||
//					pmMT[nNextX] > 12 || pmMB[nNextX] > 12;
			}
			if (bDraw) {
				pD[x] = (unsigned char)((pT[x] + pB[x]) >> 1);
			}

			if ((y >> 1) % 2)
			{
				ivc = bufC[x];
				ivp = bufP[x];
				ivn = bufN[x];
				ivcp = bufCP[x];
				ivcn = bufCN[x];
				iv;

				BYTE pixC_U = pC_U[x_half];
				BYTE pixN_U = pN_U[x_half];
				BYTE pixP_U = pP_U[x_half];
				BYTE pixC_V = pC_V[x_half];
				BYTE pixN_V = pN_V[x_half];
				BYTE pixP_V = pP_V[x_half];

				if (ivcp < ivp) {
					pixP_U = (BYTE)avg(pixC_U, pixP_U);
					pixP_V = (BYTE)avg(pixC_V, pixP_V);
					ivp = ivcp;
				}
				if (ivcn < ivn) {
					pixN_U = (BYTE)avg(pixC_U, pixN_U);
					pixN_V = (BYTE)avg(pixC_V, pixN_V);
					ivn = ivcn;
				}
				if (ivn < ivp) {
					if (ivc < ivn) {
						pD_U[x_half] = pixC_U;
						pD_V[x_half] = pixC_V;
						iv = ivc;
					} else {
						pD_U[x_half] = pixN_U;
						pD_V[x_half] = pixN_V;
						iv = ivn;
					}
				} else {
					if (ivc < ivp) {
						pD_U[x_half] = pixC_U;
						pD_V[x_half] = pixC_V;
						iv = ivc;
					} else {
						pD_U[x_half] = pixP_U;
						pD_V[x_half] = pixP_V;
						iv = ivp;
					}
				}

				if (nParameterMode == DI_MODE_DEINTERLACE)
				{
					bDraw = iv > 8 && (pmMT[x] > 12 || pmMB[x] > 12);
				}
				if (bDraw) {
					pD_U[x_half] = pB_U[x_half];
					pD_V[x_half] = pB_V[x_half];
				}
			}
		}
	}
	USE_MMX2
	return;
}

///////////////////////////////////////////////////////////////////////////
void IT::SimpleBlur(PVideoFrame &dst, int n)
{
	MakeSimpleBlurMap(m_iCurrentFrame, true);

	int x, y, threshold = 0;
	for (y = 0; y < height; y++)
	{
		const unsigned char *pmMC = m_motionMap4DI + width * clipY(y);
		for (x = 0; x < width; x++)
		{
			if (pmMC[x] > 4)
			{
				threshold++;
			}
		}
	}
	bool bAllPixel = threshold > (width * height) >> 1;

	PVideoFrame &srcC = GetChildFrame(n, m_env);
	PVideoFrame *srcR;
	switch (toupper(m_iUseFrame)) {
	default:
	case 'C':
		srcR = &srcC;
		break;
	case 'P':
		srcR = &GetChildFrame(n - 1, m_env);
		break;
	case 'N':
		srcR = &GetChildFrame(n + 1, m_env);
		break;
	}

	const unsigned char *pT;
	const unsigned char *pC;
	const unsigned char *pB;

	for(y = 0; y < height; y++) {
		if (y % 2)
		{
			pT = SYP(srcC, y - 1);
			pC = SYP(*srcR, y);
			pB = SYP(srcC, y + 1);
		}
		else
		{
			pT = SYP(*srcR, y - 1);
			pC = SYP(srcC, y);
			pB = SYP(*srcR, y + 1);
		}
		const unsigned char *pmMC = m_motionMap4DI + width * clipY(y);
		unsigned char *pD = DYP(dst, y);

		for (x = 0; x < width; x += 2)
		{
			if (bAllPixel || pmMC[x - 1] > 12 || pmMC[x] > 12 || pmMC[x + 1] > 12)
			{
				pD[x * 2 + 0] = BYTE((pT[x * 2 + 0] + pB[x * 2 + 0] + (pC[x * 2 + 0] << 1)) >> 2);
				pD[x * 2 + 1] = BYTE((pT[x * 2 + 1] + pB[x * 2 + 1] + (pC[x * 2 + 1] << 1)) >> 2);
				pD[x * 2 + 3] = BYTE((pT[x * 2 + 3] + pB[x * 2 + 3] + (pC[x * 2 + 3] << 1)) >> 2);
			}
			else
			{
				pD[x * 2 + 0] = pC[x * 2 + 0];
				pD[x * 2 + 1] = pC[x * 2 + 1];
				pD[x * 2 + 3] = pC[x * 2 + 3];
			}
			if (bAllPixel || pmMC[x - 1 + 1] > 12 || pmMC[x + 1] > 12 || pmMC[x + 1 + 1] > 12)
			{
				pD[x * 2 + 2] = BYTE((pT[x * 2 + 2] + pB[x * 2 + 2] + (pC[x * 2 + 2] << 1)) >> 2);
			}
			else
			{
				pD[x * 2 + 2] = pC[x * 2 + 2];
			}
		}
	}
	USE_MMX2
	return;
}

///////////////////////////////////////////////////////////////////////////
void IT::SimpleBlur_YV12(PVideoFrame &dst, int n)
{
	MakeSimpleBlurMap_YV12(m_iCurrentFrame, true);

	int x, y, threshold = 0;
	for (y = 0; y < height; y++)
	{
		const unsigned char *pmMC = m_motionMap4DI + width * clipY(y);
		for (x = 0; x < width; x++)
		{
			if (pmMC[x] > 4)
			{
				threshold++;
			}
		}
	}
	bool bAllPixel = threshold > (width * height) >> 1;

	PVideoFrame &srcC = GetChildFrame(n, m_env);
	PVideoFrame *srcR;
	switch (toupper(m_iUseFrame)) {
	default:
	case 'C':
		srcR = &srcC;
		break;
	case 'P':
		srcR = &GetChildFrame(n - 1, m_env);
		break;
	case 'N':
		srcR = &GetChildFrame(n + 1, m_env);
		break;
	}

	const unsigned char *pT;
	const unsigned char *pC;
	const unsigned char *pB;
	const unsigned char *pT_U;
	const unsigned char *pC_U;
	const unsigned char *pB_U;
	const unsigned char *pT_V;
	const unsigned char *pC_V;
	const unsigned char *pB_V;

	for (y = 0; y < height; y++) {
		if (y % 2)
		{
			pT = SYP(srcC, y - 1);
			pC = SYP(*srcR, y);
			pB = SYP(srcC, y + 1);
			pT_U = SYP(srcC, y - 1, PLANAR_U);
			pC_U = SYP(*srcR, y, PLANAR_U);
			pB_U = SYP(srcC, y + 1, PLANAR_U);
			pT_V = SYP(srcC, y - 1, PLANAR_V);
			pC_V = SYP(*srcR, y, PLANAR_V);
			pB_V = SYP(srcC, y + 1, PLANAR_V);
		}
		else
		{
			pT = SYP(*srcR, y - 1);
			pC = SYP(srcC, y);
			pB = SYP(*srcR, y + 1);
			pT_U = SYP(*srcR, y - 1, PLANAR_U);
			pC_U = SYP(srcC, y, PLANAR_U);
			pB_U = SYP(*srcR, y + 1, PLANAR_U);
			pT_V = SYP(*srcR, y - 1, PLANAR_V);
			pC_V = SYP(srcC, y, PLANAR_V);
			pB_V = SYP(*srcR, y + 1, PLANAR_V);
		}
		const unsigned char *pmMC = m_motionMap4DI + width * clipY(y);
		unsigned char *pD = DYP(dst, y);
		unsigned char *pD_U = DYP(dst, y, PLANAR_U);
		unsigned char *pD_V = DYP(dst, y, PLANAR_V);

		for (x = 0; x < width; x++)
		{
			if (bAllPixel || pmMC[x - 1] > 12 || pmMC[x] > 12 || pmMC[x + 1] > 12)
			{
				pD[x] = BYTE((pT[x] + pB[x] + (pC[x] << 1)) >> 2);

				if ((y >> 1) % 2)
				{
					int x_half = x >> 1;
					pD_U[x_half] = BYTE((pT_U[x_half] + pB_U[x_half] + (pC_U[x_half] << 1)) >> 2);
					pD_V[x_half] = BYTE((pT_V[x_half] + pB_V[x_half] + (pC_V[x_half] << 1)) >> 2);
				}
			}
			else
			{
				pD[x] = pC[x];
				if ((y >> 1) % 2)
				{
					int x_half = x >> 1;
					pD_U[x_half] = pC_U[x_half];
					pD_V[x_half] = pC_V[x_half];
				}
			}
		}
	}
	USE_MMX2
	return;
}

///////////////////////////////////////////////////////////////////////////
void IT::CopyCPNField(PVideoFrame &dst, int n, IScriptEnvironment* env) 
{
	PVideoFrame &srcC = GetChildFrame(n, env);
	PVideoFrame *srcR;
	switch (toupper(m_iUseFrame)) {
	default:
	case 'C':
		srcR = &srcC;
		break;
	case 'P':
		srcR = &GetChildFrame(n - 1, env);
		break;
	case 'N':
		srcR = &GetChildFrame(n + 1, env);
		break;
	}

	int nPitch = dst->GetPitch();
	int nRowSize = dst->GetRowSize();
	int nPitchU = dst->GetPitch(PLANAR_U);
	int nRowSizeU = dst->GetRowSize(PLANAR_U);

	for(int yy = 0; yy < height; yy += 2) {
		int y, yo;
		if (m_iField == 0) {
			y = yy + 1;
			yo = yy + 0;
		} else {
			y = yy + 0;
			yo = yy + 1;
		}
//		memcpy16(DYP(dst, yo), SYP(srcC, yo), width * 2);
//		memcpy16(DYP(dst, y), SYP(*srcR, y), width * 2);
		env->BitBlt(DYP(dst, yo), nPitch, SYP(srcC, yo), nPitch, nRowSize, 1);
		env->BitBlt(DYP(dst, y), nPitch, SYP(*srcR, y), nPitch, nRowSize, 1);

		if (vi.IsYV12())
		{
			if ((yy >> 1) % 2)
			{
				env->BitBlt(DYP(dst, yo, PLANAR_U), nPitchU, SYP(srcC, yo, PLANAR_U), nPitchU, nRowSizeU, 1);
				env->BitBlt(DYP(dst, y, PLANAR_U), nPitchU, SYP(*srcR, y, PLANAR_U), nPitchU, nRowSizeU, 1);
				env->BitBlt(DYP(dst, yo, PLANAR_V), nPitchU, SYP(srcC, yo, PLANAR_V), nPitchU, nRowSizeU, 1);
				env->BitBlt(DYP(dst, y, PLANAR_V), nPitchU, SYP(*srcR, y, PLANAR_V), nPitchU, nRowSizeU, 1);
			}
		}
	}
	USE_MMX2
}


///////////////////////////////////////////////////////////////////////////
void IT::PrintDebugInfo(PVideoFrame &dst, int n) 
{
	int by = 0;
	char text[0x100];

	const char *szRef[] = { "NONE", "ALL", "PREV", "NEXT", "AUTO" };

	sprintf(text, "ref %s P th %d pth %d %d", 
					szRef[m_eRef], 
					m_iThreshold,
					m_iPThreshold,
					m_iCounter
					);
	DrawString(dst, 0, by++, text, vi.IsYUY2());

	sprintf(text, "frame no = %d <- %d", m_iRealFrame, n);
	DrawString(dst, 0, by++, text, vi.IsYUY2());

	int base = (n / 5) * 5;

//	if (1) {
		char szCombP[0x10], szCombN[0x10];
		if (m_bRefP)
			sprintf(szCombP, "%6d", m_iSumP);
		else
			strcpy(szCombP, "NOREF");
		if (m_bRefN)
			sprintf(szCombN, "%6d", m_iSumN);
		else
			strcpy(szCombN, "NOREF");
		sprintf(text, "C[%6d] P[%s] N[%s], MIN[%6d]", m_iSumC, szCombP, szCombN, m_iSumM);
		DrawString(dst, 0, by++, text, vi.IsYUY2());

		if (m_bRefP)
			sprintf(szCombP, "%6d", m_iSumPP);
		else
			strcpy(szCombP, "NOREF");
		if (m_bRefN)
			sprintf(szCombN, "%6d", m_iSumPN);
		else
			strcpy(szCombN, "NOREF");
		sprintf(text, "C[%6d] P[%s] N[%s]", m_iSumPC, szCombP, szCombN);
		DrawString(dst, 0, by++, text, vi.IsYUY2());

		sprintf(text, "L ME[%6d] PE[%6d]", m_frameInfo[n].diffP0, m_frameInfo[n].diffS0);
		DrawString(dst, 0, by++, text, vi.IsYUY2());

		sprintf(text, "P MO[%6d] PO[%6d]", m_frameInfo[n].diffP1, m_frameInfo[n].diffS1);
		DrawString(dst, 0, by++, text, vi.IsYUY2());

		sprintf(text, "ERROR %d", m_iError);
		DrawString(dst, 0, by++, text, vi.IsYUY2());
		//	sprintf(text, "P[%2d] N[%2d]", m_iUsePrev, m_iUseNext);

		int i;
		for (i = 0; i < 5; ++i) {
			sprintf(text, "%6d", m_frameInfo[base + i].diffP0);
			DrawString(dst, i * 7, by, text, vi.IsYUY2());
		}
		by++;
		for (i = 0; i < 5; ++i) {
			sprintf(text, "%6d", m_frameInfo[base + i].diffP1);
			DrawString(dst, i * 7, by, text, vi.IsYUY2());
		}
		by++;
//	}

	for (int y = 0; y < 12; ++y) {
		int f = base - y * 5;
		if (f < 0)
			break;
		char text[0x100];
		sprintf(text, "%7d", f);
		DrawString(dst, 0, y + by + 2, text, vi.IsYUY2());

		//		sprintf(text, "%c", m_frameInfo[f / 5].level);
		//		DrawString(dst, 20, y + 3, text, vi.IsYUY2());

		//		if (m_blockInfo[f / 5].itype == '3') {
		//			sprintf(text, "30p/30i");
		//		} else {
		//			sprintf(text, "24p");
		//		}
		//		DrawString(dst, 40, y + by + 2, text, vi.IsYUY2());
		
		//		sprintf(text, "%c", m_blockInfo[f / 5].level);
		//		DrawString(dst, 40, y + by + 2, text, vi.IsYUY2());


		char T[6];
		T[5] = 0;
		int x;
		for (x = 0; x < 5; ++x) {
			T[x] = m_frameInfo[f + x].match;
		}
		DrawString(dst, 8, by + y + 2, T, vi.IsYUY2());
		for (x = 0; x < 5; ++x) {
			T[x] = m_frameInfo[f + x].mflag;
		}
		DrawString(dst, 14, by + y + 2, T, vi.IsYUY2());
		for (x = 0; x < 5; ++x) {
			T[x] = m_frameInfo[f + x].ip == 'I' ? 'I' : '.';
		}
		DrawString(dst, 20, by + y + 2, T, vi.IsYUY2());
		for (x = 0; x < 5; ++x) {
			T[x] = m_frameInfo[f + x].pos;
		}
		DrawString(dst, 26, by + y + 2, T, vi.IsYUY2());
	}

	return;
}

///////////////////////////////////////////////////////////////////////////
bool IT::CompCP() 
{
	int n = m_iCurrentFrame;
	int p0 = m_frameInfo[n].diffP0;
	int p1 = m_frameInfo[n].diffP1;
	int n0 = m_frameInfo[clipFrame(n + 1)].diffP0;
	int n1 = m_frameInfo[clipFrame(n + 1)].diffP1;
	int ps0 = m_frameInfo[n].diffS0;
	int ps1 = m_frameInfo[n].diffS1;
	int ns0 = m_frameInfo[clipFrame(n + 1)].diffS0;
	int ns1 = m_frameInfo[clipFrame(n + 1)].diffS1;
	if (n0 < 0 || n1 < 0)
		throw AvisynthError("IT:can't open log file");
	//	int th = 5;
	//	int thm = 5;

	int th = AdjPara(5);
	int thm = AdjPara(5);
	int ths = AdjPara(200);

	bool spe = p0 < th && ps0 < ths;
	bool spo = p1 < th && ps1 < ths;
	bool sne = n0 < th && ns0 < ths;
	bool sno = n1 < th && ns1 < ths;

	bool mpe = p0 > thm;
	bool mpo = p1 > thm;
	bool mne = n0 > thm;
	bool mno = n1 > thm;

	//1773
	int thcomb = AdjPara(20);
	if (n != 0) {
		if ((m_iSumC < thcomb && m_iSumP < thcomb) || abs(m_iSumC - m_iSumP) * 10 < m_iSumC + m_iSumP) {
			if (abs(m_iSumC - m_iSumP) > AdjPara(8)) {
				if (m_iSumP >= m_iSumC) {
					m_iUseFrame = 'c';
					return true;
				} else {
					m_iUseFrame = 'p';
					return true;
				}
			}
			if (abs(m_iSumPC - m_iSumPP) > AdjPara(10)) {
				if (m_iSumPP >= m_iSumPC) {
					m_iUseFrame = 'c';
					return true;
				} else {
					m_iUseFrame = 'p';
					return true;
				}
			}

			if (spe && mpo) {
				m_iUseFrame = 'p';
				return true;
			}
			if (mpe && spo) {
				m_iUseFrame = 'c';
				return true;
			}
			if (mne && sno) {
				m_iUseFrame = 'p';
				return true;
			}
			if (sne && mno) {
				m_iUseFrame = 'c';
				return true;
			}
			if (spe && spo) {
				m_iUseFrame = 'c';
				return false;
			}
			if (sne && sno) {
				m_iUseFrame = 'c';
				return false;
			}
			if (mpe && mpo && mne && mno) {
				m_iUseFrame = 'c';
				return false;
			}

			//			return (m_iSumPC > m_iSumPP);
			if (m_iSumPC > m_iSumPP) {
				m_iUseFrame = 'p';
				return true;
			} else {
				m_iUseFrame = 'c';
				return false;
			}
		}
	}
//	m_frameInfo[clipFrame(n)].matchAcc = '0';
//	if (m_iSumC > m_iSumP) {
//	} else {
//		m_iUseFrame = 'C';
//		return false;
//	}
	m_frameInfo[n].pos = '.';
	if (m_iSumP >= m_iSumC) {
		m_iUseFrame = 'C';
		if (!spe) {
			m_frameInfo[n].pos = '.';
		}
		return true;
	} else {
		m_iUseFrame = 'P';
		if (spe && !sno) {
			m_frameInfo[n].pos = '2';
		} 
		if (!spe && sno) {
			m_frameInfo[n].pos = '3';
		}
		return true;
	}
}

//45965
///////////////////////////////////////////////////////////////////////////
bool IT::CompCN() 
{
	int n = m_iCurrentFrame;
	int p0 = m_frameInfo[n].diffP0;
	int p1 = m_frameInfo[n].diffP1;
	int n0 = m_frameInfo[clipFrame(n + 1)].diffP0;
	int n1 = m_frameInfo[clipFrame(n + 1)].diffP1;
	int ps0 = m_frameInfo[n].diffS0;
	int ps1 = m_frameInfo[n].diffS1;
	int ns0 = m_frameInfo[clipFrame(n + 1)].diffS0;
	int ns1 = m_frameInfo[clipFrame(n + 1)].diffS1;
	if (n0 < 0 || n1 < 0)
		throw AvisynthError("IT:can't open log file");
	int th = AdjPara(5);
	int thm = AdjPara(5);
	int ths = AdjPara(200);

	bool spe = p0 < th && ps0 < ths;
	bool spo = p1 < th && ps1 < ths;
	bool sne = n0 < th && ns0 < ths;
	bool sno = n1 < th && ns1 < ths;

	bool mpe = p0 > thm;
	bool mpo = p1 > thm;
	bool mne = n0 > thm;
	bool mno = n1 > thm;

	int thcomb = AdjPara(20);
	if (n != 0) {
		if ((m_iSumC < thcomb && m_iSumN < thcomb) || abs(m_iSumC - m_iSumN) * 10 < m_iSumC + m_iSumN) {
			if (abs(m_iSumC - m_iSumN) > AdjPara(8)) {
				if (m_iSumN >= m_iSumC) {
					m_iUseFrame = 'c';
					return true;
				} else {
					m_iUseFrame = 'n';
					return true;
				}
			}
			if (abs(m_iSumPC - m_iSumPN) > AdjPara(10)) {
				if (m_iSumPN >= m_iSumPC) {
					m_iUseFrame = 'c';
					return true;
				} else {
					m_iUseFrame = 'n';
					return true;
				}
			}

			if (spe && mpo) {
				m_iUseFrame = 'c';
				return true;
			}
			if (mpe && spo) {
				m_iUseFrame = 'N';
				return true;
			}
			if (mne && sno) {
				m_iUseFrame = 'c';
				return true;
			}
			if (sne && mno) {
				m_iUseFrame = 'n';
				return true;
			}
			if (spe && spo) {
				m_iUseFrame = 'c';
				return false;
			}
			if (sne && sno) {
				m_iUseFrame = 'c';
				return false;
			}
			if (mpe && mpo && mne && mno) {
				m_iUseFrame = 'c';
				return false;
			}

			//			return (m_iSumPC > m_iSumPN);
			if (m_iSumPC > m_iSumPN) {
				m_iUseFrame = 'n';
				return true;
			} else {
				m_iUseFrame = 'c';
				return false;
			}
		}
	}
	m_frameInfo[n].pos = '.';
	if (m_iSumN >= m_iSumC) {
		m_iUseFrame = 'C';
		if (spe && mpo) {
			m_frameInfo[n].pos = '2';
		} 
		//		if (!spe) {
		//			m_frameInfo[n].pos = '.';
		//		}
		return true;
	} else {
		m_iUseFrame = 'N';
		if (spo && !sne) {
			m_frameInfo[n].pos = '0';
		} 
		if (mpo && sne) {
			m_frameInfo[n].pos = '1';
		}
		return true;
	}
}

///////////////////////////////////////////////////////////////////////////
void IT::ChooseBest(int n, IScriptEnvironment* env) 
{
	PVideoFrame &srcC = GetChildFrame(n, env);
	//	MakeMotionMap(m_iCurrentFrame - 1, false);
	if (vi.IsYV12())
	{
		MakeMotionMap_YV12(m_iCurrentFrame, false);
		MakeMotionMap_YV12(m_iCurrentFrame + 1, false);
		MakeDEmap_YV12(srcC, 0);
		EvalIV_YV12(n, srcC, m_iSumC, m_iSumPC, env);
		if (m_bRefN) {
			PVideoFrame &srcN = GetChildFrame(n + 1, env);
			EvalIV_YV12(n, srcN, m_iSumN, m_iSumPN, env);
		}
		if (m_bRefP) {
			PVideoFrame &srcP = GetChildFrame(n - 1, env);
			EvalIV_YV12(n, srcP, m_iSumP, m_iSumPP, env);
		}
	}
	else
	{
		MakeMotionMap(m_iCurrentFrame, false);
		MakeMotionMap(m_iCurrentFrame + 1, false);
		MakeDEmap(srcC, 0);
		EvalIV(n, srcC, m_iSumC, m_iSumPC, env);
		if (m_bRefN) {
			PVideoFrame &srcN = GetChildFrame(n + 1, env);
			EvalIV(n, srcN, m_iSumN, m_iSumPN, env);
		}
		if (m_bRefP) {
			PVideoFrame &srcP = GetChildFrame(n - 1, env);
			EvalIV(n, srcP, m_iSumP, m_iSumPP, env);
		}
	}

	if (m_eRef == REF_PREV) {
		CompCP();
		return;
	}
	if (m_eRef == REF_NEXT) {
		CompCN();
		return;
	}

	if (m_iSumP < m_iSumN) {
		CompCP();
	} else {
		CompCN();
	}
}

///////////////////////////////////////////////////////////////////////////
#define FI(name, n) m_frameInfo[clipFrame(n)]. ## name

bool IT::CheckSceneChange(int n)
{
	PVideoFrame srcP = child->GetFrame(n - 1, m_env);
	PVideoFrame srcC = child->GetFrame(n, m_env);

	int rowSize = srcC->GetRowSize();

	int sum3 = 0;
	int x, y;

	int startY = 0;
	if (m_iField == 0)
	{
		startY = 1;
	}

	int nStep = vi.IsYUY2() + 1;

	for (y = startY; y < height; y += 2)
	{
		const unsigned char *pC = SYP(srcC, y);
		const unsigned char *pP = SYP(srcP, y);

		for (x = 0; x < rowSize; x += nStep)
		{
			int a = abs(pC[x] - pP[x]);
//			sum0 += a;
//			if (a > 50) sum1 += 1;
//			if (a > 100) sum2 += 1;
			if (a > 50) sum3 += 1;
		}
	}
	return sum3 > height * rowSize / 8;
}

PVideoFrame IT::GetFrame(int n, IScriptEnvironment* env) 
{
	++m_iCounter;
	m_iRealFrame = n;
	m_env = env;

	int tfFrame;
	if (m_iFPS == 24) {
		tfFrame = n + n / (5 - 1);
		if (m_iFPS == 30)
			tfFrame = n;

		int base = (tfFrame / 5) * 5;
		int i;

		for (i = 0; i < 5; ++i)
			GetFrameSub(base + i, env);
		Decide(base, env);

		bool iflag = true;
		for (i = 0; i < 5; ++i) {
			if (FI(ivC, base + i) >= m_iPThreshold) {
				iflag = false;
			}
		}
		if (iflag) {
			m_blockInfo[base / 5].itype = '3';
		} else {
			m_blockInfo[base / 5].itype = '2';
		}
		int no = tfFrame - base;
		for (i = 0; i < 5; ++i) {
			char f = FI(mflag, base + i);
			if (f != 'D' && f != 'd' && f != 'X' && f != 'x' && f != 'y' && f != 'z' && f != 'R') {
				if (no == 0)
					break;
				--no;
			}
		}
		if (m_iFPS != 30)
			n = clipFrame(i + base);

//		char f = FI(mflag, n - 1);
		PVideoFrame dst = env->NewVideoFrame(vi);
		bool flag = true;
		if (m_bBlend) {
			int minD = FI(diffS1, base), avgD = 0;
			for (i = 0; i < 5; ++i) {
				minD = min(minD, FI(diffS1, base + i));
				avgD += FI(diffS0, base + i);
			}
			if (minD < AdjPara(1000) || minD < ((avgD - minD) / 4) / 3) {
				flag = false;
			}
		} else {
			flag = false;
		}
		if (!flag) {
			MakeOutput(dst, n, env);
		} else {
			if (vi.IsYV12())
			{
				BlendFrame_YV12(dst, base, tfFrame);
			}
			else
			{
				BlendFrame(dst, base, tfFrame);
			}
		}
		return dst;
	} else {
		GetFrameSub(n, env);
		PVideoFrame dst = env->NewVideoFrame(vi);
		MakeOutput(dst, n, env);
		return dst;
	}
}

///////////////////////////////////////////////////////////////////////////
double GetF(double x) {
	x = fabs(x);
	return (x < 1.0) ? 1.0 - x : 0.0;
}

void IT::BlendFrame(PVideoFrame &dst, int base, int n) 
{
//	const __int64 maskY = 0x00ff00ff00ff00ffi64;
	const int twidth = width;

	double subrange_width = 5.0;
	double target_width = 4.0;

  double scale = double(target_width) / subrange_width;
	double filter_step = min(scale, 1.0);
  double support = 1.0 / filter_step;
  int size = int(ceil(support * 2));
//  int* result = new int[target_width * (1 + size) + 1];

  double step = subrange_width / target_width;
	double pos = (n - base) * step;

	int val[100];

  int start = int(pos + support) - size + 1;
  for (int i = base; i == base; ++i) {
    double t = 0.0;
    for (int j = 0; j < size; ++j)
      t += GetF((start+j - pos) * filter_step);
    double t2 = 0.0;
    for (int k= 0; k < size; ++k) {
      double t3 = t2 + GetF((start + k - pos) * filter_step) / t;
			int v = int(t3 * 256 + 0.5) - int(t2 * 256 + 0.5);
      t2 = t3;
			val[k] = v;
    }
  }

	//	char text[0x100];
	//	sprintf(text, "%d %d", size, val[2]);
	//	sprintf(text, "%d %d", start_pos, val[2]);
	//	m_env->ThrowError(text);

	PVideoFrame *src[20];

	for (int z = 0; z < size; ++z) {
		int fno = clipFrame(base + start + z);
		int in = fno % 8;
		if (m_iPVOutIndex[in] != fno || !m_PVOut[in]) {
			//			++m_iError;
			m_iPVOutIndex[in] = fno;
			m_PVOut[in] = m_env->NewVideoFrame(vi);
			MakeOutput(m_PVOut[in], fno, m_env);
		}
		src[z] = &m_PVOut[in];
	}

	for(int y = 0; y < height; ++y) {
		unsigned char *pD = DYP(dst, y);
		__declspec(align(16)) unsigned short buf[MAX_WIDTH * 2];
		int x;
		for(x = 0; x < width * 2; ++x) {
			buf[x] = 0;
		}

		for (int z = 0; z < size; ++z) {
			const unsigned char *pS = SYP(*src[z], y);
			unsigned short mS[4];
			mS[0] = mS[1] = mS[2] = mS[3] = (unsigned char)val[z];

			_asm {
				pxor mm7,mm7
				movq mm6,mS
				mov rax,pS
				lea rdi,buf
				xor esi,esi
loopB:
				movd mm0,[rax+rsi*2]	; mm0 <- pS
				punpcklbw mm0,mm7		; 2dot ‚¸‚Â
				pmullw mm0,mm6			; mm0 <- pS * mS
				movq mm1,[rdi+rsi*4]	; mm1 <- buf
				paddw mm0,mm1			; mm0 <- buf + pS * mS
				movntq [rdi+rsi*4],mm0	; buf <- buf + pS * mS

				lea esi,[esi+2]
				cmp esi,twidth
				jl loopB
			}
			//			int s = val[z];
			//			for(x = 0; x < width * 2; ++x) {
			//				buf[x] += pS[x] * s;
			//			}
		}
		_asm {
			pxor mm7,mm7
			lea rax,buf
			mov rdi,pD
			xor esi,esi
loopC:
			movq mm0,[rax+rsi*4]
			psrlw mm0,8
			packuswb mm0,mm7
			movd [rdi+rsi*2],mm0

			lea esi,[esi+2]
			cmp esi,twidth
			jl loopC
		}
	}
	USE_MMX2
}

void IT::BlendFrame_YV12(PVideoFrame &dst, int base, int n) 
{
//	const __int64 maskY = 0x00ff00ff00ff00ffi64;
	const int twidth = width >> 1;

	double subrange_width = 5.0;
	double target_width = 4.0;

  double scale = double(target_width) / subrange_width;
	double filter_step = min(scale, 1.0);
  double support = 1.0 / filter_step;
  int size = int(ceil(support * 2));
//  int* result = new int[target_width * (1 + size) + 1];

  double step = subrange_width / target_width;
	double pos = (n - base) * step;

	int val[100];

  int start = int(pos + support) - size + 1;
  for (int i = base; i == base; ++i) {
    double t = 0.0;
    for (int j = 0; j < size; ++j)
      t += GetF((start+j - pos) * filter_step);
    double t2 = 0.0;
    for (int k= 0; k < size; ++k) {
      double t3 = t2 + GetF((start + k - pos) * filter_step) / t;
			int v = int(t3 * 256 + 0.5) - int(t2 * 256 + 0.5);
      t2 = t3;
			val[k] = v;
    }
  }

	//	char text[0x100];
	//	sprintf(text, "%d %d", size, val[2]);
	//	sprintf(text, "%d %d", start_pos, val[2]);
	//	m_env->ThrowError(text);

	PVideoFrame *src[20];

	for (int z = 0; z < size; ++z) {
		int fno = clipFrame(base + start + z);
		int in = fno % 8;
		if (m_iPVOutIndex[in] != fno || !m_PVOut[in]) {
			//			++m_iError;
			m_iPVOutIndex[in] = fno;
			m_PVOut[in] = m_env->NewVideoFrame(vi);
			MakeOutput(m_PVOut[in], fno, m_env);
		}
		src[z] = &m_PVOut[in];
	}

	__declspec(align(16)) unsigned short buf[MAX_WIDTH];
	__declspec(align(16)) unsigned short buf_U[MAX_WIDTH];
	__declspec(align(16)) unsigned short buf_V[MAX_WIDTH];
	for(int y = 0; y < height; ++y) {
		unsigned char *pD = DYP(dst, y);
		unsigned char *pD_U = DYP(dst, y, PLANAR_U);
		unsigned char *pD_V = DYP(dst, y, PLANAR_V);

		::memset(buf, 0, sizeof(unsigned short) * width);
		::memset(buf_U, 0, sizeof(unsigned short) * (width >> 1));
		::memset(buf_V, 0, sizeof(unsigned short) * (width >> 1));

		for (int z = 0; z < size; ++z) {
			const unsigned char *pS = SYP(*src[z], y);
			const unsigned char *pS_U = SYP(*src[z], y, PLANAR_U);
			const unsigned char *pS_V = SYP(*src[z], y, PLANAR_V);
			unsigned short mS[4];
			unsigned short mS_U[4];
			unsigned short mS_V[4];
			mS[0] = mS[1] = mS[2] = mS[3] = (unsigned char)val[z];
			mS_U[0] = mS_U[1] = mS_U[2] = mS_U[3] = (unsigned char)val[z];
			mS_V[0] = mS_V[1] = mS_V[2] = mS_V[3] = (unsigned char)val[z];

			_asm {
				pxor mm7,mm7
				movq mm6,mS
				mov rax,pS
				mov rbx,pS_U
				mov rcx,pS_V
				xor esi,esi
loopB:
				lea rdi,buf
				movd mm0,[rax+rsi*2]	; mm0 <- pS
				punpcklbw mm0,mm7		; 4dot ‚¸‚Â
				pmullw mm0,mm6			; mm0 <- pS * mS
				movq mm1,[rdi+rsi*4]	; mm1 <- buf
				paddw mm0,mm1			; mm0 <- buf + pS * mS
				movntq [rdi+rsi*4],mm0	; buf <- buf + pS * mS

				movd mm0,[rax+rsi*2+4]
				punpcklbw mm0,mm7
				pmullw mm0,mm6
				movq mm1,[rdi+rsi*4+8]
				paddw mm0,mm1
				movntq [rdi+rsi*4+8],mm0

				lea rdi,buf_U
				movd mm0,[rbx+rsi]
				punpcklbw mm0,mm7
				pmullw mm0,mm6
				movq mm1,[rdi+rsi*2]
				paddw mm0,mm1
				movq [rdi+rsi*2],mm0

				lea rdi,buf_V
				movd mm0,[rcx+rsi]
				punpcklbw mm0,mm7
				pmullw mm0,mm6
				movq mm1,[rdi+rsi*2]
				paddw mm0,mm1
				movq [rdi+rsi*2],mm0

				lea esi,[esi+4]
				cmp esi,twidth
				jl loopB
			}
			//			int s = val[z];
			//			for(x = 0; x < width * 2; ++x) {
			//				buf[x] += pS[x] * s;
			//			}
		}
		_asm {
			pxor mm7,mm7
			lea rax,buf
			lea rbx,buf_U
			lea rcx,buf_V
			xor esi,esi
loopC:
			mov rdi,pD
			movq mm0,[rax+rsi*4]
			psrlw mm0,8
			packuswb mm0,mm7
			movd [rdi+rsi*2],mm0

			movq mm0,[rax+rsi*4+8]
			psrlw mm0,8
			packuswb mm0,mm7
			movd [rdi+rsi*2+4],mm0

			mov rdi,pD_U
			movq mm0,[rbx+rsi*2]
			psrlw mm0,8
			packuswb mm0,mm7
			movd [rdi+rsi],mm0

			mov rdi,pD_V
			movq mm0,[rcx+rsi*2]
			psrlw mm0,8
			packuswb mm0,mm7
			movd [rdi+rsi],mm0

			lea esi,[esi+4]
			cmp esi,twidth
			jl loopC
		}
	}
	USE_MMX2
}

void IT::SetFT(int base, int n, char c)
{
	FI(mflag, base + n) = c;
	m_blockInfo[base / 5].cfi = n;
	m_blockInfo[base / 5].level = '0';
}


///////////////////////////////////////////////////////////////////////////
void __stdcall IT::Decide(int n, IScriptEnvironment* /*env*/)
{

	if (m_blockInfo[n / 5].level != 'U')
		return;

	int base = (n / 5) * 5;
	int i;
	int min0 = FI(diffP0, base);
	for (i = 1; i < 5; ++i) {
		min0 = min(min0, FI(diffP0, base + i));
	}
	int mmin = AdjPara(50);
	m_iError = mmin;

	for (i = 0; i < 5; ++i) {
		int m = FI(diffP0, (base + i));
		if (m >= max(mmin, min0) * 5) {
			FI(mflag, base + i) = '.';
		} else {
			FI(mflag, base + i) = '+';
		}
	}
//	const int motion1 = 100;

	int ncf = 0;
	int cfi = -1;
	for (i = 0; i < 5; ++i) {
		if (FI(mflag, base + i) == '.')
			++ncf;
		else
			cfi = i;
	}

	int mmin2 = AdjPara(50);
	if (ncf == 0) {
		min0 = FI(diffS0, base);
		for (i = 1; i < 5; ++i) {
			min0 = min(min0, FI(diffS0, base + i));
		}
		for (i = 0; i < 5; ++i) {
			int m = FI(diffS0, base + i);
			if (m >= max(mmin2, min0) * 3) {
				FI(mflag, base + i) = '.';
			} else {
				FI(mflag, base + i) = '+';
			}
		}
		ncf = 0;
		cfi = -1;
		for (i = 0; i < 5; ++i) {
			if (FI(mflag, base + i) == '.')
				++ncf;
			else
				cfi = i;
		}
	}

	if (ncf == 4 && cfi >= 0) {
		SetFT(base, cfi, 'D');
		return;
	}
	if (ncf != 0 || 1) {
		bool flag = false;
		for (i = 0; i < 5; ++i) {
			int rr = (i + 2 + 5) % 5;
			int r = (i + 1 + 5) % 5;
			int l = (i - 1 + 5) % 5;
			if (FI(mflag, base + i) != '.' && FI(match, base + i)  == 'P') {
				if (FI(mflag, base + i) == '+') {
					FI(mflag, base + i) = '*';
					flag = true;
				}
				if (FI(mflag, base + r) == '+') {
					FI(mflag, base + r) = '*';
					flag = true;
				}
				if (FI(mflag, base + l) == '+') {
					FI(mflag, base + l) = '*';
					flag = true;
				}
			}
			if (FI(match, base + i)  == 'N') {
				if (FI(mflag, base + r) == '+') {
					FI(mflag, base + r) = '*';
					flag = true;
				}
				if (FI(mflag, base + rr) == '+') {
					FI(mflag, base + rr) = '*';
					flag = true;
				}
			}

		}

		//31228 39045

		if (flag) {
			for (i = 0; i < 5; ++i) {
				char c = FI(mflag, base + i);
				if (c == '+')
					FI(mflag, base + i) = '*';
				if (c == '*')
					FI(mflag, base + i) = '+';
			}
		}
		for (i = 0; i < 5; ++i) {
			if (FI(pos, base + i) == '2') {
				SetFT(base, i, 'd');
				return;
			}
		}
		if (base - 5 >= 0 && m_blockInfo[base / 5 - 1].level != 'U') {
			int tcfi = m_blockInfo[base / 5 - 1].cfi;
			if (m_frameInfo[base + tcfi].mflag == '+') {
				SetFT(base, tcfi, 'y');
				return;
			}
		}
		int pnpos[5], pncnt = 0;
		for (i = 0; i < 5; ++i) {
			if (toupper(FI(match, base + i)) == 'P') {
				pnpos[pncnt++] = i;
			}
		}
		if (pncnt == 2) {
			int k = pnpos[0];
			if (pnpos[0] == 0 && pnpos[1] == 4) {
				k = 4;
			}
			if (FI(mflag, base + k) != '.') {
				SetFT(base, k, 'x');
				return;
			}
		}

		pncnt = 0;
		for (i = 0; i < 5; ++i) {
			if (toupper(FI(match, base + i)) != 'N') {
				pnpos[pncnt++] = i;
			}
		}
		if (pncnt == 2) {
			int k = pnpos[0];
			if (pnpos[0] == 3 && pnpos[1] == 4) {
				k = 4;
			}
			k = (k + 2) % 5;
			if (FI(mflag, base + k) != '.') {
				SetFT(base, k, 'x');
				return;
			}
		}

		for (i = 0; i < 5; ++i) {
			if (m_frameInfo[clipFrame(base + i)].mflag == '+') {
				SetFT(base, i, 'd');
				return;
			}
		}
	}

	cfi = 0;
	int minx = FI(diffS0, base);
	for (i = 1; i < 5; ++i) {
		int m =	FI(diffS0, base + i); 
		if (m < minx) {
			cfi = i;
			minx = m;
		}
	}
	SetFT(base, cfi, 'z');
	return;
}


///////////////////////////////////////////////////////////////////////////
void IT::GetFrameSub(int n, IScriptEnvironment* env) 
{
	if (n >= m_iMaxFrames)
		return;
	if (m_frameInfo[n].ip != 'U') {
		return;
	}
	m_iCurrentFrame = n;

	m_iUseFrame = 'C';
	m_iSumC = m_iSumP = m_iSumN = m_iSumM = 720 * 480;
	m_bRefP = false;
	m_bRefN = false;
	switch (m_eRef) {
	case REF_NONE:
		break;
	case REF_ALL:
	case REF_AUTO:
		m_bRefP = true;
		m_bRefN = true;
		break;
	case REF_PREV:
		m_bRefP = true;
		break;
	case REF_NEXT:
		m_bRefN = true;
		break;
	}

	if (m_eRef != REF_NONE) {
		ChooseBest(n, env);
	}
	m_frameInfo[n].match = (unsigned char)m_iUseFrame;
	switch (toupper(m_iUseFrame)) {
	case 'C':
		m_iSumM = m_iSumC;
		m_iSumPM = m_iSumPC;
		//		m_frameInfo[n].match = 'C';
		break;
	case 'P':
		m_iSumM = m_iSumP;
		m_iSumPM = m_iSumPP;
		if (m_eRef == REF_AUTO) {
			if (m_iSumN >= m_iPThreshold && m_iSumC >= m_iPThreshold && m_iSumP < m_iPThreshold) {
				++m_iUsePrev;
			}
			if (m_iUsePrev + m_iUseNext >= 5 && m_iUsePrev > m_iUseNext * 5) {
				m_eRef = REF_PREV;
			}
		}
		//		m_frameInfo[n].match = 'P';
		break;
	case 'N':
		m_iSumM = m_iSumN;
		m_iSumPM = m_iSumPN;
		if (m_eRef == REF_AUTO) {
			if (m_iSumP >= m_iPThreshold && m_iSumC >= m_iPThreshold && m_iSumN < m_iPThreshold) {
				++m_iUseNext;
			}
			if (m_iUsePrev + m_iUseNext >= 5 && m_iUseNext > m_iUsePrev * 5) {
				m_eRef = REF_NEXT;
			}
		}
		//		m_frameInfo[n].match = 'N';
		break;
	}
	
	m_frameInfo[n].ivC = m_iSumC;
	m_frameInfo[n].ivP = m_iSumP;
	m_frameInfo[n].ivN = m_iSumN;
	m_frameInfo[n].ivM = m_iSumM;
	m_frameInfo[n].ivPC = m_iSumPC;
	m_frameInfo[n].ivPP = m_iSumPP;
	m_frameInfo[n].ivPN = m_iSumPN;
	if (m_iSumM < m_iPThreshold && m_iSumPM < m_iPThreshold * 3) {
		m_frameInfo[n].ip = 'P';
	} else {
		m_frameInfo[n].ip = 'I';
	}
	return;
}

///////////////////////////////////////////////////////////////////////////
PVideoFrame IT::MakeOutput(PVideoFrame &dst, int n, IScriptEnvironment* env)
{
	m_env = env;
	m_iCurrentFrame = n;

	m_iSumC = m_frameInfo[n].ivC;
	m_iSumP = m_frameInfo[n].ivP;
	m_iSumN = m_frameInfo[n].ivN;
	m_iSumM = m_frameInfo[n].ivM;
	m_iSumPC = m_frameInfo[n].ivPC;
	m_iSumPP = m_frameInfo[n].ivPP;
	m_iSumPN = m_frameInfo[n].ivPN;

	m_bRefP = false;
	m_bRefN = false;
	switch (m_eRef) {
	case REF_NONE:
		break;
	case REF_ALL:
	case REF_AUTO:
		m_bRefP = true;
		m_bRefN = true;
		break;
	case REF_PREV:
		m_bRefP = true;
		break;
	case REF_NEXT:
		m_bRefN = true;
		break;
	}

	m_iUseFrame = toupper(m_frameInfo[n].match);

#ifdef DEBUG_SHOW_INTERLACE
	//		ShowInterlaceArea(dst, n);
	//		PrintDebugInfo(dst, n);
	USE_MMX2
	return dst;
#endif // DEBUG_SHOW_INTERLACE

	if (m_frameInfo[n].ip == 'P')
	{
		//		if (m_iUseFrame == 'C' && !m_bDebug) {
		//			PVideoFrame &srcC = GetChildFrame(n, env);
			//			End();
		//			USE_MMX2
		//			return srcC;
		//		}
		//		dst = env->NewVideoFrame(vi);
		CopyCPNField(dst, n, env);
	} else {
		//		m_frameInfo[n].match = 'C';
		//		m_iUseFrame = 'C';
		//		m_iSumM = m_iSumC;
		//		dst = env->NewVideoFrame(vi);
		switch(m_iDiMode)
		{
		case DI_MODE_NONE:
			{
				CopyCPNField(dst, n, env);
			}
			break;
		default:
		case DI_MODE_DEINTERLACE:
			{
				if (vi.IsYV12())
				{
					Deinterlace_YV12(dst, n);
				}
				else
				{
					Deinterlace(dst, n);
				}
			}
			break;
		case DI_MODE_SIMPLE_BLUR:
			{
				if (!DrawPrevFrame(dst, n))
				{
					if (vi.IsYV12())
					{
						SimpleBlur_YV12(dst, n);
					}
					else
					{
						SimpleBlur(dst, n);
					}
				}
			}
			break;
		case DI_MODE_ONE_FIELD:
			{
				if (!DrawPrevFrame(dst, n))
				{
					if (vi.IsYV12())
					{
						DeintOneField_YV12(dst, n);
					}
					else
					{
						DeintOneField(dst, n);
					}
				}
			}
			break;
		case DI_MODE_DEINTERLACE_B:
			{
				if (!DrawPrevFrame(dst, n))
				{
					if (vi.IsYV12())
					{
						Deinterlace_YV12(dst, n, DI_MODE_DEINTERLACE_B);
					}
					else
					{
						Deinterlace(dst, n, DI_MODE_DEINTERLACE_B);
					}
				}
			}
			break;
		}
	}

	if (m_bDebug) {
		PrintDebugInfo(dst, n);
	}
	//	End();
	USE_MMX2
	return dst;
}

///////////////////////////////////////////////////////////////////////////
bool IT::DrawPrevFrame(PVideoFrame& dst, int n)
{
	bool bResult = false;

	int nPrevFrame = clipFrame(n - 1);
	int nNextFrame = clipFrame(n + 1);

	int nOldCurrentFrame = m_iCurrentFrame;
	int nOldUseFrame = m_iUseFrame;

	GetFrameSub(nPrevFrame, m_env);
	GetFrameSub(nNextFrame, m_env);

	m_iCurrentFrame = nOldCurrentFrame;

	if (m_frameInfo[nPrevFrame].ip == 'P' && m_frameInfo[nNextFrame].ip == 'P')
	{
		if (CheckSceneChange(n) == true)
		{
			bResult = true;
		}
		else
		{
//			int a = 0;
		}
	}

	if (bResult)
	{
		m_iUseFrame = m_frameInfo[nPrevFrame].match;

		CopyCPNField(dst, nPrevFrame, m_env);
	}

	m_iUseFrame = nOldUseFrame;

	return bResult;
}

void IT::DeintOneField(PVideoFrame &dst, int n)
{
	PVideoFrame &srcC = GetChildFrame(n, m_env);
	PVideoFrame *srcR;
	switch (toupper(m_iUseFrame)) {
	default:
	case 'C':
		srcR = &srcC;
		break;
	case 'P':
		srcR = &GetChildFrame(n - 1, m_env);
		break;
	case 'N':
		srcR = &GetChildFrame(n + 1, m_env);
		break;
	}

	const unsigned char *pC;
	const unsigned char *pB;
	const unsigned char *pBB;
	unsigned char *pDC;
	unsigned char *pDB;

	MakeSimpleBlurMap(m_iCurrentFrame, true);
	MakeMotionMap2Max(m_iCurrentFrame, true);

	unsigned char *pFieldMap;
	pFieldMap = new unsigned char[width * height];
	ZeroMemory(pFieldMap, width * height);
	int x, y;
	for (y = 0; y < height; y += 1)
	{
		unsigned char *pFM = pFieldMap + width * clipY(y);
		for (x = 1; x < width - 1; x++)
		{
			const unsigned char *pmSC = m_motionMap4DI + width * clipY(y);
			const unsigned char *pmSB = m_motionMap4DI + width * clipY(y + 1);
			const unsigned char *pmMC = m_motionMap4DIMax + width * clipY(y);
			const unsigned char *pmMB = m_motionMap4DIMax + width * clipY(y + 1);
			const int nTh = 12;
			const int nThLine = 1;
			if (((pmSC[x - 1] > nThLine && pmSC[x] > nThLine && pmSC[x + 1] > nThLine) ||
				(pmSB[x - 1] > nThLine && pmSB[x] > nThLine && pmSB[x + 1] > nThLine)) &&
				((pmMC[x - 1] > nTh && pmMC[x] > nTh && pmMC[x + 1] > nTh) ||
				(pmMB[x - 1] > nTh && pmMB[x] > nTh && pmMB[x + 1] > nTh)))
			{
				pFM[x - 1] = 1;
				pFM[x] = 1;
				pFM[x + 1] = 1;
			}
		}
	}

	const int nPitchSrc = srcC->GetPitch();
	const int nPitchDst = dst->GetPitch();
	const int nRowSizeDst = dst->GetRowSize();

	for(y = 0; y < height; y += 2) {
		pC = SYP(srcC, y);
		pB = SYP(*srcR, y + 1);
		pBB = SYP(srcC, y + 2);

		pDC = DYP(dst, y);
		pDB = DYP(dst, y + 1);

		m_env->BitBlt(pDC, nPitchDst, pC, nPitchSrc, nRowSizeDst, 1);

		const unsigned char *pFM = pFieldMap + width * clipY(y);
		const unsigned char *pFMB = pFieldMap + width * clipY(y + 1);
		for (x = 0; x < width; x += 2)
		{
			if ((pFM[x - 1] == 1 || pFM[x] == 1 || pFM[x + 1] == 1) ||
				(pFMB[x - 1] == 1 || pFMB[x] == 1 || pFMB[x + 1] == 1))
			{
				pDB[x * 2 + 0] = BYTE((pC[x * 2 + 0] + pBB[x * 2 + 0] + 1) >> 1);
			}
			else
			{
				pDB[x * 2 + 0] = pB[x * 2 + 0];
			}
			if ((pFM[x + 1 - 1] == 1 || pFM[x + 1] == 1 || pFM[x + 1 + 1] == 1) ||
				(pFMB[x + 1 - 1] == 1 || pFMB[x + 1] == 1 || pFMB[x + 1 + 1] == 1))
			{
				pDB[x * 2 + 2] = BYTE((pC[x * 2 + 2] + pBB[x * 2 + 2] + 1) >> 1);
			}
			else
			{
				pDB[x * 2 + 2] = pB[x * 2 + 2];
			}
			pDB[x * 2 + 1] = BYTE((pC[x * 2 + 1] + pBB[x * 2 + 1] + 1) >> 1);
			pDB[x * 2 + 3] = BYTE((pC[x * 2 + 3] + pBB[x * 2 + 3] + 1) >> 1);
		}
	}
	delete[] pFieldMap;

	return;
}

void IT::DeintOneField_YV12(PVideoFrame &dst, int n)
{
	PVideoFrame &srcC = GetChildFrame(n, m_env);
	PVideoFrame *srcR;
	switch (toupper(m_iUseFrame)) {
	default:
	case 'C':
		srcR = &srcC;
		break;
	case 'P':
		srcR = &GetChildFrame(n - 1, m_env);
		break;
	case 'N':
		srcR = &GetChildFrame(n + 1, m_env);
		break;
	}

	const unsigned char *pT;
	const unsigned char *pC;
	const unsigned char *pB;
	const unsigned char *pBB;
	const unsigned char *pC_U;
	const unsigned char *pB_U;
	const unsigned char *pBB_U;
	const unsigned char *pC_V;
	const unsigned char *pB_V;
	const unsigned char *pBB_V;
	unsigned char *pDC;
	unsigned char *pDB;
	unsigned char *pDC_U;
	unsigned char *pDC_V;
	unsigned char *pDB_U;
	unsigned char *pDB_V;

	MakeSimpleBlurMap_YV12(m_iCurrentFrame, true);
	MakeMotionMap2Max_YV12(m_iCurrentFrame, true);

	unsigned char *pFieldMap;
	pFieldMap = new unsigned char[width * height];
	ZeroMemory(pFieldMap, width * height);
	int x, y;
	for (y = 0; y < height; y += 1)
	{
		unsigned char *pFM = pFieldMap + width * clipY(y);
		for (x = 1; x < width - 1; x++)
		{
			const unsigned char *pmSC = m_motionMap4DI + width * clipY(y);
			const unsigned char *pmSB = m_motionMap4DI + width * clipY(y + 1);
			const unsigned char *pmMC = m_motionMap4DIMax + width * clipY(y);
			const unsigned char *pmMB = m_motionMap4DIMax + width * clipY(y + 1);
			const int nTh = 12;
			const int nThLine = 1;
			if (((pmSC[x - 1] > nThLine && pmSC[x] > nThLine && pmSC[x + 1] > nThLine) ||
				(pmSB[x - 1] > nThLine && pmSB[x] > nThLine && pmSB[x + 1] > nThLine)) &&
				((pmMC[x - 1] > nTh && pmMC[x] > nTh && pmMC[x + 1] > nTh) ||
				(pmMB[x - 1] > nTh && pmMB[x] > nTh && pmMB[x + 1] > nTh)))
			{
				pFM[x - 1] = 1;
				pFM[x] = 1;
				pFM[x + 1] = 1;
			}
		}
	}

	const int nPitchSrc = srcC->GetPitch();
	const int nPitchSrcU = srcC->GetPitch(PLANAR_U);
	const int nPitchDst = dst->GetPitch();
	const int nRowSizeDst = dst->GetRowSize();
	const int nPitchDstU = dst->GetPitch(PLANAR_U);
	const int nRowSizeDstU = dst->GetRowSize(PLANAR_U);

	for(y = 0; y < height; y += 2) {
		pT = SYP(*srcR, y - 1);
		pC = SYP(srcC, y);
		pB = SYP(*srcR, y + 1);
		pBB = SYP(srcC, y + 2);
		pC_U = SYP(srcC, y, PLANAR_U);
		pB_U = SYP(*srcR, y + 1, PLANAR_U);
		pBB_U = SYP(srcC, y + 4, PLANAR_U);
		pC_V = SYP(srcC, y, PLANAR_V);
		pB_V = SYP(*srcR, y + 1, PLANAR_V);
		pBB_V = SYP(srcC, y + 4, PLANAR_V);

		pDC = DYP(dst, y);
		pDB = DYP(dst, y + 1);
		pDC_U = DYP(dst, y, PLANAR_U);
		pDB_U = DYP(dst, y + 1, PLANAR_U);
		pDC_V = DYP(dst, y, PLANAR_V);
		pDB_V = DYP(dst, y + 1, PLANAR_V);

		m_env->BitBlt(pDC, nPitchDst, pC, nPitchSrc, nRowSizeDst, 1);
		if ((y >> 1) % 2)
		{
			m_env->BitBlt(pDC_U, nPitchDstU, pC_U, nPitchSrcU, nRowSizeDstU, 1);
			m_env->BitBlt(pDC_V, nPitchDstU, pC_V, nPitchSrcU, nRowSizeDstU, 1);
		}

		const unsigned char *pFM = pFieldMap + width * clipY(y);
		const unsigned char *pFMB = pFieldMap + width * clipY(y + 1);
		for (x = 0; x < width; ++x)
		{
			int x_half = x >> 1;
			if ((pFM[x - 1] == 1 || pFM[x] == 1 || pFM[x + 1] == 1) ||
				(pFMB[x - 1] == 1 || pFMB[x] == 1 || pFMB[x + 1] == 1))
			{
				pDB[x] = BYTE((pC[x] + pBB[x] + 1) >> 1);
			}
			else
			{
				pDB[x] = pB[x];
			}

			if ((y >> 1) % 2)
			{
				pDB_U[x_half] = BYTE((pC_U[x_half] + pBB_U[x_half] + 1) >> 1);
				pDB_V[x_half] = BYTE((pC_V[x_half] + pBB_V[x_half] + 1) >> 1);
			}
		}
	}
	delete[] pFieldMap;

	return;
}

///////////////////////////////////////////////////////////////////////////
extern "C" __declspec(dllexport) const char* __stdcall AvisynthPluginInit2(IScriptEnvironment* env) {
	env->AddFunction("IT", "c[fps]i[threshold]i[pthreshold]i[ref]s[blend]b[debug]b[read]s[write]s[log]s[dimode]i", IT::Create, 0);
	return "`IT' plugin";
}

#pragma warning( disable : 4514 )
#pragma warning( disable : 4505 )
