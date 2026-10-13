// CRC-32 (gzip's, ISO 3309) and Adler-32 (zlib's), each continuing from the value
// a previous call returned. Start CRC-32 at 0 and Adler-32 at 1.
namespace compress;

import std;

// Slice-by-16: table k, at 256 k, gives the CRC of a byte followed by k zero
// bytes, so 16 bytes take 16 independent lookups.
let CRC_TABLE = crc_table();

fn crc_table() -> u32[4096] {
    var t: u32[4096] = [0; 4096];
    for n in 256 {
        var c = n as! u32;
        for k in 8 {
            c = if c & 1 == 1 { 0xEDB88320 ^ (c >> 1) } else { c >> 1 };
        }
        t[n] = c;
    }
    for i in 256..4096 { t[i] = (t[i - 256] >> 8) ^ t[t[i - 256] & 0xFF]; }
    return t;
}

fn crc32(crc: u32, data: const u8[:]) -> u32 {
    let t .= CRC_TABLE;
    var c = ~crc;
    var i = 0;
    while i + 16 <= data.len {
        let b = data[i..i + 16];
        let lo = c ^ (b[0] | (b[1] as u32) << 8 | (b[2] as u32) << 16 | (b[3] as u32) << 24);
        c = t[3840 + (lo & 0xFF) as i64] ^ t[3584 + ((lo >> 8) & 0xFF) as i64] ^
            t[3328 + ((lo >> 16) & 0xFF) as i64] ^ t[3072 + (lo >> 24) as i64] ^
            t[2816 + b[4] as i64] ^ t[2560 + b[5] as i64] ^ t[2304 + b[6] as i64] ^
            t[2048 + b[7] as i64] ^ t[1792 + b[8] as i64] ^ t[1536 + b[9] as i64] ^
            t[1280 + b[10] as i64] ^ t[1024 + b[11] as i64] ^
            t[768 + b[12] as i64] ^ t[512 + b[13] as i64] ^ t[256 + b[14] as i64] ^ t[b[15]];
        i += 16;
    }
    for b in data[i..] { c = t[(c ^ b) & 0xFF] ^ (c >> 8); }
    return ~c;
}

// The largest n for which 255 n (n + 1) / 2 + (n + 1) (65521 - 1) fits in 32
// bits, so both sums wait n bytes between reductions (zlib's NMAX).
let ADLER_RUN = 5552;
let ADLER_MOD: u32 = 65521;

// A run is taken 32 bytes at a time in 32 lanes, so the C compiler vectorizes
// it: lane j sums byte j of each block (s1) and, before each block, what it held
// (s2). After k blocks, a gained the sum of s1 and b gained 32 k a, 32 times the
// sum of s2, and each s1[j] weighted by 32 - j.
simd fn adler32(adler: u32, data: const u8[:]) -> u32 {
    var a = adler & 0xFFFF;
    var b = adler >> 16;
    var at = 0;
    while at < data.len {
        let end = min(at + ADLER_RUN, data.len);
        let blocks = (end - at) / 32;
        if blocks > 0 {
            var s1: u32[32] = [0; 32];
            var s2: u32[32] = [0; 32];
            for k in blocks {
                let p = at + 32 * k;
                // j & 31 proves the lanes in bounds; the slice holds 32 bytes.
                for x, j in data[p..p + 32] {
                    s2[j & 31] += s1[j & 31];
                    s1[j & 31] += x;
                }
            }
            var sum1: u64 = 0;
            var sum2: u64 = 0;
            for j in 32 {
                sum1 += s1[j];
                sum2 += 32 * s2[j] as u64 + (32 - j) as! u64 * s1[j];
            }
            b = ((b + 32 * blocks as! u64 * a + sum2) % ADLER_MOD) as! u32;
            a = ((a + sum1) % ADLER_MOD) as! u32;
            at += 32 * blocks;
        }
        for x in data[at..end] {
            a += x;
            b += a;
        }
        a %= ADLER_MOD;
        b %= ADLER_MOD;
        at = end;
    }
    return (b << 16) | a;
}

// XXH64 with seed 0, as zstd's content checksum (RFC 8878 §3.1.1), kept across
// calls: 32-byte stripes in four lanes, and the bytes of a partial stripe held.
let XXH_P1: u64 = 0x9E3779B185EBCA87;
let XXH_P2: u64 = 0xC2B2AE3D27D4EB4F;
let XXH_P3: u64 = 0x165667B19E3779F9;
let XXH_P4: u64 = 0x85EBCA77C2B2AE63;
let XXH_P5: u64 = 0x27D4EB2F165667C5;

struct Xxh64 {
    v1: u64 = XXH_P1 + XXH_P2,
    v2: u64 = XXH_P2,
    v3: u64 = 0,
    v4: u64 = 0 - XXH_P1,
    total: u64 = 0,
    nbuf: i64 = 0,
    buf: u8[32],
}

fn xxh64_reset(x: Xxh64&) {
    x.v1 = XXH_P1 + XXH_P2;
    x.v2 = XXH_P2;
    x.v3 = 0;
    x.v4 = 0 - XXH_P1;
    x.total = 0;
    x.nbuf = 0;
}

fn xxh64_update(x: Xxh64&, data: const u8[:]) {
    x.total += data.len as! u64;
    var at = 0;
    if x.nbuf > 0 {
        at = min(32 - x.nbuf, data.len);
        copy_into(x.buf[x.nbuf..x.nbuf + at], data[..at]);
        x.nbuf += at;
        guard x.nbuf == 32 else { return; }
        let b = x.buf;
        xxh64_stripes(x, b);
        x.nbuf = 0;
    }
    let whole = (data.len - at) & ~31;
    xxh64_stripes(x, data[at..at + whole]);
    at += whole;
    copy_into(x.buf[..data.len - at], data[at..]);
    x.nbuf = data.len - at;
}

// Takes data, a whole number of stripes, into the four lanes.
fn xxh64_stripes(x: Xxh64&, data: const u8[:]) {
    var v1 = x.v1;
    var v2 = x.v2;
    var v3 = x.v3;
    var v4 = x.v4;
    var i = 0;
    while i + 32 <= data.len {
        let s = data[i..i + 32];
        v1 = xxh64_round(v1, load64(s, 0));
        v2 = xxh64_round(v2, load64(s, 8));
        v3 = xxh64_round(v3, load64(s, 16));
        v4 = xxh64_round(v4, load64(s, 24));
        i += 32;
    }
    x.v1 = v1;
    x.v2 = v2;
    x.v3 = v3;
    x.v4 = v4;
}

fn xxh64_digest(x: const Xxh64&) -> u64 {
    var h = if x.total >= 32 {
        var m = rotl64(x.v1, 1) + rotl64(x.v2, 7) + rotl64(x.v3, 12) + rotl64(x.v4, 18);
        for v in [x.v1, x.v2, x.v3, x.v4] {
            m = (m ^ xxh64_round(0, v)) * XXH_P1 + XXH_P4;
        }
        m
    } else {
        x.v3 + XXH_P5
    };
    h += x.total;
    let rest = x.buf[..x.nbuf];
    var i = 0;
    while i + 8 <= rest.len {
        h ^= xxh64_round(0, load64(rest, i));
        h = rotl64(h, 27) * XXH_P1 + XXH_P4;
        i += 8;
    }
    if i + 4 <= rest.len {
        h ^= load32(rest, i) * XXH_P1;
        h = rotl64(h, 23) * XXH_P2 + XXH_P3;
        i += 4;
    }
    for b in rest[i..] {
        h ^= b * XXH_P5;
        h = rotl64(h, 11) * XXH_P1;
    }
    h ^= h >> 33;
    h *= XXH_P2;
    h ^= h >> 29;
    h *= XXH_P3;
    h ^= h >> 32;
    return h;
}

// XXH64 of data whole, with seed 0.
fn xxh64(data: const u8[:]) -> u64 {
    var x = Xxh64 { .. };
    xxh64_update(x, data);
    return xxh64_digest(x);
}

fn xxh64_round(acc: u64, v: u64) -> u64 {
    return rotl64(acc + v * XXH_P2, 31) * XXH_P1;
}

fn rotl64(v: u64, r: u64) -> u64 {
    return v << r | v >> (64 - r);
}

fn load64(s: const u8[:], i: i64) -> u64 {
    return load32(s, i) | (load32(s, i + 4) as u64) << 32;
}
