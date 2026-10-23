/* The C under deflate.goose's two hottest loops: level 1's matcher and the
   symbol coder every level writes blocks with (docs/decisions.md, "Level 1's
   matcher and the symbol coder in C"). Each is deflate.goose's algorithm
   step for step, so the bytes are the same; what C saves is the checked
   arithmetic and bounds checks of every step, which Goose keeps.

   gc_match_fast matches win from st->pos to st->end and returns when it
   gets there or when the block holds SYM_MAX symbols, for Goose to end the
   block. gc_put_syms codes a block's symbols from st->next, and then its
   end, into buf, which holds at least STAGE + 8 bytes; it stops once STAGE
   bytes are written, for Goose to append them and call again, and returns
   true when the block's end is written. Whole bytes go to buf, st->out of
   them, and fewer than 8 bits stay in st. */
#include <stdbool.h>
#include <stdint.h>
#include <string.h>

#if defined(_MSC_VER) && !defined(__clang__)
#include <intrin.h>
static inline int gc_ctz64(uint64_t x) { unsigned long i; _BitScanForward64(&i, x); return (int)i; }
static inline int gc_log2(uint32_t x) { unsigned long i; _BitScanReverse(&i, x); return (int)i; }
#else
#define gc_ctz64(x) __builtin_ctzll(x)
#define gc_log2(x) (31 - __builtin_clz(x))
#endif

#define WSIZE 32768
#define MAX_MATCH 258
#define MIN_MATCH 3
#define SYM_MAX 16384
#define FAST_NICE 32
#define HASH_BITS 16
#define HUFF_MAX 288
#define END_BLOCK 256
#define STAGE 4096

#pragma pack(push, 1)
typedef struct { const uint8_t *data; int64_t len; } gc_bytes;
typedef struct { uint32_t *data; int64_t len; } gc_u32s;
typedef struct { const uint32_t *data; int64_t len; } gc_const_u32s;
typedef struct { uint8_t *data; int64_t len; } gc_out;
/* deflate.goose's Fast and BitState, and huffman.goose's Huff. */
typedef struct { int64_t fill, end, pos, nsym, extra; uint32_t base; } gc_fast;
typedef struct { uint64_t bits; int64_t nbits, next, out; } gc_bits;
typedef struct { uint8_t len[HUFF_MAX]; uint16_t code[HUFF_MAX]; } gc_huff;
#pragma pack(pop)
_Static_assert(sizeof(gc_fast) == 44, "deflate.goose's Fast, packed");
_Static_assert(sizeof(gc_huff) == 3 * HUFF_MAX, "huffman.goose's Huff, packed");
_Static_assert(sizeof(gc_bits) == 32, "deflate.goose's BitState, packed");

static inline uint32_t load32(const uint8_t *p) {
    uint32_t v;
    memcpy(&v, p, 4);
    return v;
}

static inline uint64_t load64(const uint8_t *p) {
    uint64_t v;
    memcpy(&v, p, 8);
    return v;
}

static inline int64_t bucket(uint32_t v) { return (int64_t)((v * 0x9E3779B1u) >> (32 - HASH_BITS + 1)) * 2; }

/* deflate.goose's match_len: the bytes a and b have in common, up to most. */
static inline int64_t match_len(const uint8_t *a, const uint8_t *b, int64_t most) {
    if (most <= 0 || a[0] != b[0]) return 0;
    int64_t n = 1;
    while (n + 8 <= most) {
        uint64_t d = load64(a + n) ^ load64(b + n);
        if (d != 0) return n + (gc_ctz64(d) >> 3);
        n += 8;
    }
    for (; n < most; n++)
        if (a[n] != b[n]) return n;
    return most;
}

/* RFC 1951 §3.2.5's length symbol for a length minus 3, and the distance
   code for a distance minus 1, with their extra bits' counts: len_code and
   dist_code in deflate.goose, which take them from tables. */
static inline void len_sym(uint32_t x, uint32_t *code, uint32_t *bits) {
    if (x < 8) { *code = 257 + x; *bits = 0; return; }
    if (x == 255) { *code = 285; *bits = 0; return; }
    int n = gc_log2(x);
    *bits = (uint32_t)(n - 2);
    *code = 257 + 4 * (uint32_t)(n - 1) + ((x >> *bits) & 3);
}

static inline void dist_sym(uint32_t x, uint32_t *code, uint32_t *bits) {
    if (x < 4) { *code = x; *bits = 0; return; }
    int n = gc_log2(x);
    *bits = (uint32_t)(n - 1);
    *code = 2 * (uint32_t)n + ((x >> *bits) & 1);
}

void gc_match_fast(gc_bytes win_s, gc_u32s head_s, gc_u32s syms_s, gc_u32s lfreq_s, gc_u32s dfreq_s,
                   gc_fast *st) {
    const uint8_t *win = win_s.data;
    uint32_t *head = head_s.data, *syms = syms_s.data, *lfreq = lfreq_s.data, *dfreq = dfreq_s.data;
    const int64_t fill = st->fill, end = st->end;
    const uint32_t base = st->base;
    int64_t p = st->pos, nsym = st->nsym, extra = st->extra;
    while (p < end) {
        int64_t len = 0, dist = 0;
        if (p + 4 <= fill) {
            uint32_t v = load32(win + p);
            int64_t b = bucket(v);
            uint32_t here = base + (uint32_t)p;
            uint32_t c0 = head[b], c1 = head[b + 1];
            head[b] = here;
            head[b + 1] = c0;
            int64_t most = fill - p < MAX_MATCH ? fill - p : MAX_MATCH;
            uint64_t reach = (uint64_t)(p < WSIZE ? p : WSIZE);
            int64_t d0 = (int64_t)(uint32_t)(here - c0);
            if ((uint64_t)(d0 - 1) < reach) {
                if (load32(win + p - d0) == v) {
                    len = 4 + match_len(win + p - d0 + 4, win + p + 4, most - 4);
                    dist = d0;
                }
                int64_t d1 = (int64_t)(uint32_t)(here - c1);
                if (len < FAST_NICE && (uint64_t)(d1 - 1) < reach && load32(win + p - d1) == v &&
                    (len == 0 || load32(win + p - d1 + len - 3) == load32(win + p + len - 3))) {
                    int64_t len1 = 4 + match_len(win + p - d1 + 4, win + p + 4, most - 4);
                    if (len1 > len) {
                        len = len1;
                        dist = d1;
                    }
                }
            }
        }
        if (len >= MIN_MATCH) {
            int64_t stop = p + len < fill - 3 ? p + len : fill - 3;
            for (int64_t i = p + 1; i < stop; i++) {
                int64_t bi = bucket(load32(win + i));
                head[bi + 1] = head[bi];
                head[bi] = base + (uint32_t)i;
            }
            uint32_t x = (uint32_t)(len - MIN_MATCH), lc, lbits, dc, dbits;
            syms[nsym++] = (uint32_t)dist << 8 | x;
            len_sym(x, &lc, &lbits);
            dist_sym((uint32_t)dist - 1, &dc, &dbits);
            lfreq[lc]++;
            dfreq[dc]++;
            extra += lbits + dbits;
            p += len;
        } else {
            uint8_t c = win[p++];
            syms[nsym++] = c;
            lfreq[c]++;
        }
        if (nsym == SYM_MAX) break;
    }
    st->pos = p;
    st->nsym = nsym;
    st->extra = extra;
}

static inline void put_le64(uint8_t *b, uint64_t v) {
    for (int i = 0; i < 8; i++) b[i] = (uint8_t)(v >> (8 * i));
}

bool gc_put_syms(gc_out buf_s, gc_const_u32s syms_s, const gc_huff *lit, const gc_huff *dist, gc_bits *st) {
    uint8_t *buf = buf_s.data;
    int64_t o = 0;
    uint64_t bits = st->bits;
    int64_t nbits = st->nbits;
    while (nbits >= 8) {
        buf[o++] = (uint8_t)bits;
        bits >>= 8;
        nbits -= 8;
    }
    const uint32_t *syms = syms_s.data;
    int64_t k = st->next;
    for (; k < syms_s.len && o < STAGE; k++) {
        uint32_t s = syms[k];
        if (s < 256) {
            bits |= (uint64_t)lit->code[s] << nbits;
            nbits += lit->len[s];
        } else {
            uint32_t x = s & 0xff, lc, lbits, d = (s >> 8) - 1, dc, dbits;
            len_sym(x, &lc, &lbits);
            bits |= (uint64_t)lit->code[lc] << nbits;
            nbits += lit->len[lc];
            bits |= (uint64_t)(x & ((1u << lbits) - 1)) << nbits;
            nbits += lbits;
            dist_sym(d, &dc, &dbits);
            bits |= (uint64_t)dist->code[dc] << nbits;
            nbits += dist->len[dc];
            bits |= (uint64_t)(d & ((1u << dbits) - 1)) << nbits;
            nbits += dbits;
        }
        put_le64(buf + o, bits);
        o += nbits >> 3;
        bits >>= nbits & ~7;
        nbits &= 7;
    }
    bool done = k == syms_s.len && o < STAGE;
    if (done) {
        bits |= (uint64_t)lit->code[END_BLOCK] << nbits;
        nbits += lit->len[END_BLOCK];
        put_le64(buf + o, bits);
        o += nbits >> 3;
        bits >>= nbits & ~7;
        nbits &= 7;
    }
    st->bits = bits;
    st->nbits = nbits;
    st->next = k;
    st->out = o;
    return done;
}
