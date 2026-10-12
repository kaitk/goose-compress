// CRC-32 (gzip's, ISO 3309) and Adler-32 (zlib's), each continuing from the value
// a previous call returned. Start CRC-32 at 0 and Adler-32 at 1.
namespace compress;

import std;

let CRC_TABLE = crc_table();

fn crc_table() -> u32[256] {
    var t: u32[256] = [0; 256];
    for n in 256 {
        var c = n as! u32;
        for k in 8 {
            c = if c & 1 == 1 { 0xEDB88320 ^ (c >> 1) } else { c >> 1 };
        }
        t[n] = c;
    }
    return t;
}

fn crc32(crc: u32, data: const u8[:]) -> u32 {
    var c = ~crc;
    for b in data { c = CRC_TABLE[(c ^ b) & 0xFF] ^ (c >> 8); }
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
