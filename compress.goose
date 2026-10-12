// The package's entry: gzip, zlib, and raw DEFLATE encoders, bytes in and bytes
// out. The checksums are in checksum.goose.
namespace compress;

import std;
import .checksum;

// The container around the DEFLATE stream: gzip (RFC 1952), zlib (RFC 1950), or
// none (RFC 1951 alone, HTTP's "deflate" being zlib's).
let GZIP = 0;
let ZLIB = 1;
let RAW = 2;

// The most a stored block holds: its length is 16 bits (RFC 1951 §3.2.4).
let STORED_MAX = 65535;

// A stream being compressed. Input is held until a block fills, so the blocks a
// stream gives don't depend on how its input was split across writes.
struct Encoder {
    format: i64 = GZIP,
    started: bool = false,
    finished: bool = false,
    // CRC-32 for gzip, Adler-32 for zlib.
    check: u32 = 0,
    // The input's length modulo 2^32: gzip's ISIZE.
    size: u32 = 0,
    pending: u8[..65535] = [],
}

fn encoder(format: i64 = GZIP) -> Encoder {
    assert(format == GZIP || format == ZLIB || format == RAW);
    return Encoder { format: format, check: if format == ZLIB { 1 } else { 0 }, .. };
}

// Compresses `data` whole and appends the stream to `out`.
fn compress(data: const u8[:], out: u8[>..]&, format: i64 = GZIP) {
    var e = encoder(format);
    absorb(e, data);
    header(e, out);
    var at = 0;
    while data.len - at > STORED_MAX {
        stored(out, data[at..at + STORED_MAX], false);
        at += STORED_MAX;
    }
    stored(out, data[at..], true);
    trailer(e, out);
}

// Compresses `data` into the stream, appending whole blocks to `out` and holding
// the rest.
fn write(e: Encoder&, data: const u8[:], out: u8[>..]&) {
    assert(!e.finished);
    absorb(e, data);
    header(e, out);
    var at = 0;
    if e.pending.len > 0 {
        let take = min(STORED_MAX - e.pending.len, data.len);
        e.pending.append(data[..take]);
        at = take;
        guard e.pending.len == STORED_MAX else { return; }
        stored(out, e.pending, false);
        e.pending.clear();
    }
    while data.len - at >= STORED_MAX {
        stored(out, data[at..at + STORED_MAX], false);
        at += STORED_MAX;
    }
    e.pending.append(data[at..]);
}

// Ends the output so far on a byte boundary, so a reader can decompress all the
// input written so far: the held input, then an empty stored block, as zlib's
// Z_SYNC_FLUSH. The stream continues after it.
fn flush(e: Encoder&, out: u8[>..]&) {
    assert(!e.finished);
    header(e, out);
    if e.pending.len > 0 {
        stored(out, e.pending, false);
        e.pending.clear();
    }
    stored(out, "", false);
}

// Ends the stream: the held input as the final block, then the trailer.
fn finish(e: Encoder&, out: u8[>..]&) {
    assert(!e.finished);
    header(e, out);
    stored(out, e.pending, true);
    e.pending.clear();
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
        // ID1, ID2, CM 8 (deflate), no flags, no time, XFL 0, OS 255 (unknown).
        out.append([0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 255]);
    } else if e.format == ZLIB {
        // CM 8, a 32 KB window; FLEVEL 0 (fastest), and the check bits that make
        // the pair a multiple of 31.
        out.append([0x78, 0x01]);
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

// A stored block: a 3-bit header padded to the byte, then LEN, its complement
// NLEN, and the bytes. Every block this encoder writes ends on a byte boundary,
// so each header starts one.
fn stored(out: u8[>..]&, data: const u8[:], last: bool) {
    assert(data.len <= STORED_MAX);
    out.push(if last { 1 } else { 0 });
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
