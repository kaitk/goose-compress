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

fn adler32(adler: u32, data: const u8[:]) -> u32 {
    var a = adler & 0xFFFF;
    var b = adler >> 16;
    var at = 0;
    while at < data.len {
        let end = min(at + ADLER_RUN, data.len);
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
