/* The C under checksum.goose's crc32: CRC-32 folded with the CPU's carryless
   multiply, x86-64's PCLMULQDQ and ARMv8's PMULL, which Goose can't express
   yet (docs/decisions.md, "CRC-32 on the CPU's carryless multiply, in C for
   now"). The folding and its constants follow Intel's "Fast CRC Computation
   for Generic Polynomials Using PCLMULQDQ Instruction", as zlib-ng's and
   Chromium's zlib do; the arm64 code takes the same steps, instruction for
   instruction.

   gc_crc32_clmul takes the CRC register, not inverted, and at least 64 bytes,
   a multiple of 16, and returns the register after them. gc_crc_instructions
   says whether to call it: false on another architecture, on a CPU without
   PCLMULQDQ and SSE4.1 or without PMULL, or where GOOSE_COMPRESS_PORTABLE asks
   for Goose's own CRC. The function that uses the instructions carries a
   target attribute, so no build needs -march. */
#if defined(_MSC_VER)
#define _CRT_SECURE_NO_WARNINGS /* getenv */
#endif

#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#if defined(__aarch64__) || defined(_M_ARM64)
#define GC_ARM 1
#include <arm_neon.h>
#if defined(_MSC_VER) && !defined(__clang__)
#define GC_TARGET
#elif defined(__clang__)
#define GC_TARGET __attribute__((target("aes")))
#else
#define GC_TARGET __attribute__((target("+aes")))
#endif
#if defined(__linux__)
#include <sys/auxv.h>
#ifndef HWCAP_PMULL
#define HWCAP_PMULL (1 << 4)
#endif
#elif defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#endif

#elif defined(__x86_64__) || defined(_M_X64)
#define GC_X86 1
#include <immintrin.h>
#if defined(_MSC_VER) && !defined(__clang__)
#include <intrin.h>
#define GC_TARGET
#else
#include <cpuid.h>
#define GC_TARGET __attribute__((target("pclmul,sse4.1")))
#endif
#endif

/* A Goose slice, { data, len }, passed by value. */
#pragma pack(push, 1)
typedef struct { const uint8_t *data; int64_t len; } gc_bytes;
#pragma pack(pop)
_Static_assert(sizeof(gc_bytes) == sizeof(void *) + 8, "a Goose slice is { data, len }, packed");

/* The check runs once; threads that race to it compute the same answer. */
#if defined(_MSC_VER) && !defined(__clang__)
/* Interlocked, not a plain volatile, which ARM64's /volatile:iso doesn't order. */
#include <intrin.h>
static volatile long cached; /* 0: not checked yet, 1: no, 2: yes */
#define LOAD(p) _InterlockedCompareExchange((p), 0, 0)
#define STORE(p, v) _InterlockedExchange((p), (v))
#else
static int32_t cached;
#define LOAD(p) __atomic_load_n(p, __ATOMIC_RELAXED)
#define STORE(p, v) __atomic_store_n(p, v, __ATOMIC_RELAXED)
#endif

static bool cpu_has_clmul(void) {
#if defined(GC_ARM) && defined(__APPLE__)
    return true; /* every Apple Silicon CPU has PMULL */
#elif defined(GC_ARM) && defined(__linux__)
    return (getauxval(AT_HWCAP) & HWCAP_PMULL) != 0;
#elif defined(GC_ARM) && defined(_WIN32)
    return IsProcessorFeaturePresent(PF_ARM_V8_CRYPTO_INSTRUCTIONS_AVAILABLE) != 0;
#elif defined(GC_X86)
#if defined(_MSC_VER) && !defined(__clang__)
    int r[4];
    __cpuid(r, 1);
    unsigned int c = (unsigned int)r[2];
#else
    unsigned int a, b, c, d;
    if (!__get_cpuid(1, &a, &b, &c, &d)) return false;
#endif
    return (c & (1u << 1)) && (c & (1u << 19)); /* PCLMULQDQ, SSE4.1 */
#else
    return false;
#endif
}

bool gc_crc_instructions(void) {
    int32_t v = LOAD(&cached);
    if (v == 0) {
        const char *off = getenv("GOOSE_COMPRESS_PORTABLE");
        bool portable = off && *off && strcmp(off, "0") != 0;
        v = !portable && cpu_has_clmul() ? 2 : 1;
        STORE(&cached, v);
    }
    return v == 2;
}

#if defined(GC_ARM) || defined(GC_X86)
/* x^(512+64) and x^512, x^(128+64) and x^128, x^64 modulo P, and P with its
   Barrett constant, bit-reflected, as Intel's paper derives them. */
static const uint64_t K1K2[2] = {0x0154442bd4, 0x01c6e41596};
static const uint64_t K3K4[2] = {0x01751997d0, 0x00ccaa009e};
static const uint64_t K5K0[2] = {0x0163cd6124, 0x0000000000};
static const uint64_t POLY[2] = {0x01db710641, 0x01f7011641};
#endif

#if defined(GC_ARM)

/* The x86-64 code below, step for step: clmul(a, b) multiplies a's and b's
   low 64 bits, clmul_hi their high 64 bits, and shr_bytes is _mm_srli_si128. */
GC_TARGET static inline uint64x2_t clmul(uint64x2_t a, uint64x2_t b) {
    return vreinterpretq_u64_p128(vmull_p64(vgetq_lane_u64(a, 0), vgetq_lane_u64(b, 0)));
}

GC_TARGET static inline uint64x2_t clmul_hi(uint64x2_t a, uint64x2_t b) {
    return vreinterpretq_u64_p128(vmull_high_p64(vreinterpretq_p64_u64(a), vreinterpretq_p64_u64(b)));
}

static inline uint64x2_t load(const uint8_t *p) { return vreinterpretq_u64_u8(vld1q_u8(p)); }

#define shr_bytes(x, n) vreinterpretq_u64_u8(vextq_u8(vreinterpretq_u8_u64(x), vdupq_n_u8(0), (n)))

GC_TARGET static inline uint64x2_t fold(uint64x2_t x, uint64x2_t k, uint64x2_t next) {
    return veorq_u64(veorq_u64(clmul_hi(x, k), clmul(x, k)), next);
}

GC_TARGET uint32_t gc_crc32_clmul(uint32_t crc, gc_bytes in) {
    const uint8_t *p = in.data;
    int64_t len = in.len;
    uint64x2_t k = vld1q_u64(K1K2);
    uint64x2_t x1 = veorq_u64(load(p), vcombine_u64(vcreate_u64(crc), vdup_n_u64(0)));
    uint64x2_t x2 = load(p + 16), x3 = load(p + 32), x4 = load(p + 48);
    p += 64;
    len -= 64;
    while (len >= 64) {
        x1 = fold(x1, k, load(p));
        x2 = fold(x2, k, load(p + 16));
        x3 = fold(x3, k, load(p + 32));
        x4 = fold(x4, k, load(p + 48));
        p += 64;
        len -= 64;
    }
    k = vld1q_u64(K3K4);
    x1 = fold(x1, k, x2);
    x1 = fold(x1, k, x3);
    x1 = fold(x1, k, x4);
    while (len >= 16) {
        x1 = fold(x1, k, load(p));
        p += 16;
        len -= 16;
    }

    /* 128 bits to 64, then Barrett's reduction to 32. */
    uint64x2_t mask = vdupq_n_u64(0xffffffff);
    uint64x2_t x = veorq_u64(shr_bytes(x1, 8), clmul(x1, vdupq_laneq_u64(k, 1)));
    k = vld1q_u64(K5K0);
    x = veorq_u64(clmul(vandq_u64(x, mask), k), shr_bytes(x, 4));
    k = vld1q_u64(POLY);
    uint64x2_t t = vandq_u64(clmul(vandq_u64(x, mask), vdupq_laneq_u64(k, 1)), mask);
    x = veorq_u64(x, clmul(t, k));
    return vgetq_lane_u32(vreinterpretq_u32_u64(x), 1);
}

#elif defined(GC_X86)

static inline __m128i load(const uint8_t *p) { return _mm_loadu_si128((const __m128i *)p); }

GC_TARGET static inline __m128i fold(__m128i x, __m128i k, __m128i next) {
    __m128i lo = _mm_clmulepi64_si128(x, k, 0x00);
    __m128i hi = _mm_clmulepi64_si128(x, k, 0x11);
    return _mm_xor_si128(_mm_xor_si128(hi, lo), next);
}

GC_TARGET uint32_t gc_crc32_clmul(uint32_t crc, gc_bytes in) {
    const uint8_t *p = in.data;
    int64_t len = in.len;
    __m128i k = load((const uint8_t *)K1K2);
    __m128i x1 = _mm_xor_si128(load(p), _mm_cvtsi32_si128((int)crc));
    __m128i x2 = load(p + 16), x3 = load(p + 32), x4 = load(p + 48);
    p += 64;
    len -= 64;
    while (len >= 64) {
        x1 = fold(x1, k, load(p));
        x2 = fold(x2, k, load(p + 16));
        x3 = fold(x3, k, load(p + 32));
        x4 = fold(x4, k, load(p + 48));
        p += 64;
        len -= 64;
    }
    k = load((const uint8_t *)K3K4);
    x1 = fold(x1, k, x2);
    x1 = fold(x1, k, x3);
    x1 = fold(x1, k, x4);
    while (len >= 16) {
        x1 = fold(x1, k, load(p));
        p += 16;
        len -= 16;
    }

    /* 128 bits to 64, then Barrett's reduction to 32. */
    __m128i mask = _mm_setr_epi32(~0, 0, ~0, 0);
    __m128i x = _mm_xor_si128(_mm_srli_si128(x1, 8), _mm_clmulepi64_si128(x1, k, 0x10));
    k = _mm_loadl_epi64((const __m128i *)K5K0);
    x = _mm_xor_si128(_mm_clmulepi64_si128(_mm_and_si128(x, mask), k, 0x00), _mm_srli_si128(x, 4));
    k = load((const uint8_t *)POLY);
    __m128i t = _mm_and_si128(_mm_clmulepi64_si128(_mm_and_si128(x, mask), k, 0x10), mask);
    x = _mm_xor_si128(x, _mm_clmulepi64_si128(t, k, 0x00));
    return (uint32_t)_mm_extract_epi32(x, 1);
}

#else

uint32_t gc_crc32_clmul(uint32_t crc, gc_bytes in) {
    (void)in;
    return crc; /* never called: gc_crc_instructions is false */
}

#endif
