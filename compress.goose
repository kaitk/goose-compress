// The package's entry: gzip, zlib, and raw DEFLATE encoders, bytes in and bytes
// out. The DEFLATE stream at levels 1 and up is in deflate.goose, the checksums
// in checksum.goose.
namespace compress;

import std;
import .checksum;
import .deflate;

// The container around the DEFLATE stream: gzip (RFC 1952), zlib (RFC 1950), or
// none (RFC 1951 alone, HTTP's "deflate" being zlib's).
let GZIP = 0;
let ZLIB = 1;
let RAW = 2;

// Level 0 stores; 1 to 9 compress. Every level from 1 matches the same way for
// now.
let DEFAULT_LEVEL = 6;

// The most a stored block holds: its length is 16 bits (RFC 1951 §3.2.4).
let STORED_MAX = 65535;

// A stream being compressed. Its blocks depend only on its input and where it
// was flushed, not on how the input was split across writes.
struct Encoder {
    format: i64 = GZIP,
    level: i64 = DEFAULT_LEVEL,
    started: bool = false,
    finished: bool = false,
    // CRC-32 for gzip, Adler-32 for zlib.
    check: u32 = 0,
    // The input's length modulo 2^32: gzip's ISIZE.
    size: u32 = 0,
    // At level 0, z.win[..z.fill] holds the input not yet stored.
    z: Lz,
}

fn encoder(format: i64 = GZIP, level: i64 = DEFAULT_LEVEL) -> Encoder {
    assert(format == GZIP || format == ZLIB || format == RAW);
    assert(level >= 0 && level <= 9);
    return Encoder { format: format, level: level,
                     check: if format == ZLIB { 1 } else { 0 }, .. };
}

// Compresses `data` whole and appends the stream to `out`.
fn compress(data: const u8[:], out: u8[>..]&, format: i64 = GZIP,
            level: i64 = DEFAULT_LEVEL) {
    var e = encoder(format, level);
    write(e, data, out);
    finish(e, out);
}

// Compresses `data` into the stream, appending whole blocks to `out` and holding
// the rest.
fn write(e: Encoder&, data: const u8[:], out: u8[>..]&) {
    assert(!e.finished);
    absorb(e, data);
    header(e, out);
    if e.level > 0 {
        lz_write(e.z, data, out);
        return;
    }
    let z .= e.z;
    var at = 0;
    if z.fill > 0 {
        let take = min(STORED_MAX - z.fill, data.len);
        copy_into(z.win[z.fill..z.fill + take], data[..take]);
        z.fill += take;
        at = take;
        guard z.fill == STORED_MAX else { return; }
        stored(out, z.win[..STORED_MAX], false);
        z.fill = 0;
    }
    while data.len - at >= STORED_MAX {
        stored(out, data[at..at + STORED_MAX], false);
        at += STORED_MAX;
    }
    copy_into(z.win[..data.len - at], data[at..]);
    z.fill = data.len - at;
}

// Ends the output so far on a byte boundary, so a reader can decompress all the
// input written so far: the held input, then an empty stored block, as zlib's
// Z_SYNC_FLUSH. The stream continues after it.
fn flush(e: Encoder&, out: u8[>..]&) {
    assert(!e.finished);
    header(e, out);
    if e.level > 0 {
        lz_flush(e.z, out);
        return;
    }
    if e.z.fill > 0 {
        stored(out, e.z.win[..e.z.fill], false);
        e.z.fill = 0;
    }
    stored(out, "", false);
}

// Ends the stream: the held input as the final block, then the trailer.
fn finish(e: Encoder&, out: u8[>..]&) {
    assert(!e.finished);
    header(e, out);
    if e.level > 0 {
        lz_finish(e.z, out);
    } else {
        stored(out, e.z.win[..e.z.fill], true);
        e.z.fill = 0;
    }
    trailer(e, out);
    e.finished = true;
}

fn absorb(e: Encoder&, data: const u8[:]) {
    if e.format == GZIP {
        e.check = crc32(e.check, data);
    } else if e.format == ZLIB {
        e.check = adler32(e.check, data);
    }
    e.size += data.len as! u32;
}

fn header(e: Encoder&, out: u8[>..]&) {
    guard !e.started else { return; }
    e.started = true;
    if e.format == GZIP {
        // ID1, ID2, CM 8 (deflate), no flags, no time, XFL (2 for the
        // strongest level, 4 for the fastest), OS 255 (unknown).
        let xfl: u8 = if e.level == 9 { 2 } else if e.level == 1 { 4 } else { 0 };
        out.append([0x1f, 0x8b, 8, 0, 0, 0, 0, 0, xfl, 255]);
    } else if e.format == ZLIB {
        // CM 8, a 32 KB window; FLEVEL as zlib sets it for the level, and the
        // check bits that make the pair a multiple of 31.
        let flg: u8 = if e.level < 2 { 0x01 } else if e.level < 6 { 0x5e }
                      else if e.level == 6 { 0x9c } else { 0xda };
        out.append([0x78, flg]);
    }
}

fn trailer(e: Encoder&, out: u8[>..]&) {
    if e.format == GZIP {
        put_le32(out, e.check);
        put_le32(out, e.size);
    } else if e.format == ZLIB {
        put_be32(out, e.check);
    }
}

// A stored block at level 0: a 3-bit header padded to the byte, then the body.
// Every block at level 0 ends on a byte boundary, so each header starts one.
fn stored(out: u8[>..]&, data: const u8[:], last: bool) {
    out.push(if last { 1 } else { 0 });
    stored_body(out, data);
}

// LEN, its complement NLEN, and the bytes.
fn stored_body(out: u8[>..]&, data: const u8[:]) {
    assert(data.len <= STORED_MAX);
    let n = data.len as! u16;
    put_le16(out, n);
    put_le16(out, ~n);
    out.append(data);
}

fn put_le16(out: u8[>..]&, v: u16) {
    out.push(v as! u8);
    out.push((v >> 8) as! u8);
}

fn put_le32(out: u8[>..]&, v: u32) {
    for i in 4 { out.push((v >> (8 * i)) as! u8); }
}

fn put_be32(out: u8[>..]&, v: u32) {
    for i in 4 { out.push((v >> (24 - 8 * i)) as! u8); }
}
