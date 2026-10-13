// Compresses a file with libdeflate, zlib-ng, or libzstd, the C libraries
// goose-compress is measured against, the way bench/bench.goose does with the
// package: one-shot, the whole file in memory, RUNS times. libdeflate and
// zlib-ng write gzip unless FORMAT says zlib or raw; libzstd writes zstd, with
// the content checksum on, and libzstd-wN limits its window to 2^N bytes.
//
//   ref libdeflate|zlib-ng LEVEL FILE RUNS [gzip|zlib|raw]
//   ref libzstd|libzstd-wN LEVEL FILE RUNS [zstd]
//
// Prints the library, level, input and output sizes, and the median and best
// rate in MB/s (10^6 bytes of input per second), one line, space-separated.
#define _CRT_SECURE_NO_WARNINGS // fopen
#include <libdeflate.h>
#include <zlib-ng.h>
#include <zstd.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#ifdef _WIN32
#include <windows.h>
#endif

static double now(void) {
#ifdef _WIN32
    LARGE_INTEGER t, f;
    QueryPerformanceCounter(&t);
    QueryPerformanceFrequency(&f);
    return (double)t.QuadPart / f.QuadPart;
#else
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec * 1e-9;
#endif
}

static int by_value(const void *a, const void *b) {
    double x = *(const double *)a, y = *(const double *)b;
    return (x > y) - (x < y);
}

// One stream through zlib-ng's native API, as zlib's deflate with its default
// memory level and strategy; window bits 31 make gzip, 15 zlib, and -15 raw.
static size_t zng_once(int level, int bits, const unsigned char *in, size_t n,
                           unsigned char *out, size_t cap) {
    zng_stream s;
    memset(&s, 0, sizeof s);
    if (zng_deflateInit2(&s, level, Z_DEFLATED, bits, 8, Z_DEFAULT_STRATEGY) != Z_OK) {
        return 0;
    }
    s.next_in = in;
    s.avail_in = n;
    s.next_out = out;
    s.avail_out = cap;
    int r = zng_deflate(&s, Z_FINISH);
    size_t got = s.total_out;
    zng_deflateEnd(&s);
    return r == Z_STREAM_END ? got : 0;
}

int main(int argc, char **argv) {
    if (argc != 5 && argc != 6) {
        fprintf(stderr, "usage: ref libdeflate|zlib-ng LEVEL FILE RUNS [gzip|zlib|raw]\n"
                        "       ref libzstd|libzstd-wN LEVEL FILE RUNS [zstd]\n");
        return 2;
    }
    const char *lib = argv[1];
    int level = atoi(argv[2]);
    int runs = atoi(argv[4]);
    int deflate = strcmp(lib, "libdeflate") == 0;
    int wlog = strncmp(lib, "libzstd-w", 9) == 0 ? atoi(lib + 9) : 0;
    int zstd = strcmp(lib, "libzstd") == 0 || wlog > 0;
    if (!deflate && !zstd && strcmp(lib, "zlib-ng") != 0) {
        fprintf(stderr, "unknown library %s\n", lib);
        return 2;
    }
    const char *format = argc == 6 ? argv[5] : zstd ? "zstd" : "gzip";
    int bits = strcmp(format, "gzip") == 0   ? 31
               : strcmp(format, "zlib") == 0 ? 15
               : strcmp(format, "raw") == 0  ? -15
                                             : 0;
    if (zstd ? strcmp(format, "zstd") != 0 : bits == 0) {
        fprintf(stderr, "%s can't write %s\n", lib, format);
        return 2;
    }
    FILE *f = fopen(argv[3], "rb");
    if (!f) {
        perror(argv[3]);
        return 1;
    }
    fseek(f, 0, SEEK_END);
    size_t n = (size_t)ftell(f);
    fseek(f, 0, SEEK_SET);
    unsigned char *in = malloc(n ? n : 1);
    if (fread(in, 1, n, f) != n) {
        perror(argv[3]);
        return 1;
    }
    fclose(f);
    size_t cap = (zstd ? ZSTD_compressBound(n) : n + n / 8) + 1024;
    unsigned char *out = malloc(cap);
    struct libdeflate_compressor *c = deflate ? libdeflate_alloc_compressor(level) : NULL;
    if (deflate && !c) {
        fprintf(stderr, "libdeflate has no level %d\n", level);
        return 2;
    }
    ZSTD_CCtx *z = zstd ? ZSTD_createCCtx() : NULL;
    if (zstd && (ZSTD_isError(ZSTD_CCtx_setParameter(z, ZSTD_c_compressionLevel, level)) ||
                 ZSTD_isError(ZSTD_CCtx_setParameter(z, ZSTD_c_checksumFlag, 1)) ||
                 (wlog && ZSTD_isError(ZSTD_CCtx_setParameter(z, ZSTD_c_windowLog, wlog))))) {
        fprintf(stderr, "%s has no level %d\n", lib, level);
        return 2;
    }
    double *rate = malloc(sizeof(double) * runs);
    size_t size = 0;
    for (int i = 0; i < runs; i++) {
        double t = now();
        if (zstd) {
            size = ZSTD_compress2(z, out, cap, in, n);
            if (ZSTD_isError(size)) {
                size = 0;
            }
        } else if (!deflate) {
            size = zng_once(level, bits, in, n, out, cap);
        } else if (bits == 31) {
            size = libdeflate_gzip_compress(c, in, n, out, cap);
        } else if (bits == 15) {
            size = libdeflate_zlib_compress(c, in, n, out, cap);
        } else {
            size = libdeflate_deflate_compress(c, in, n, out, cap);
        }
        t = now() - t;
        if (size == 0) {
            fprintf(stderr, "%s failed at level %d\n", lib, level);
            return 1;
        }
        rate[i] = n / t / 1e6;
    }
    qsort(rate, runs, sizeof(double), by_value);
    printf("%s %d %zu %zu %.1f %.1f\n", lib, level, n, size, rate[runs / 2],
           rate[runs - 1]);
    return 0;
}
