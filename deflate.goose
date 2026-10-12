// The DEFLATE stream at levels 1 and up: LZ77 with one hash probe per position,
// and each block coded with the fixed Huffman tables (RFC 1951 §3.2.6) or
// stored, whichever is shorter.
namespace compress;

import std;

// Matches reach back at most WSIZE bytes and run at most MAX_MATCH.
let WSIZE = 32768;
let MIN_MATCH = 3;
let MAX_MATCH = 258;
// A position is matched only once this many bytes follow it, or at a flush, so
// a match and the hashes inserted inside it never depend on how much input a
// write happened to bring: MAX_MATCH, and 4 bytes hashed at its last position.
let LOOKAHEAD = MAX_MATCH + 4;
// 32 KB of history, 32 KB of input, and the lookahead. When the window fills,
// it slides down by WSIZE, which keeps a full WSIZE behind the next position.
let WIN_SIZE = 2 * WSIZE + LOOKAHEAD;
let HASH_BITS = 15;
let HASH_SIZE = 1 << HASH_BITS;
// A block ends when it holds this many symbols, as zlib's at its default
// memory level.
let SYM_MAX = 16384;

// The state of a stream at levels 1 and up, inside Encoder.
struct Lz {
    // Bits not yet appended to the output, the oldest in the low bits.
    bits: u64,
    nbits: i64,
    // The stream offset of win[0], modulo 2^32.
    base: u32,
    // win[..fill] holds input; pos is the next position to match, and the
    // current block covers win[block_start..pos].
    fill: i64,
    pos: i64,
    block_start: i64,
    // Each hash bucket's latest stream offset. An entry only suggests where a
    // match may start: it may be stale, or from 2^32 bytes back, so every
    // candidate is compared byte by byte.
    head: u32[HASH_SIZE],
    // The block's symbols: a literal byte as itself, a match as its distance
    // above bit 8 and its length minus 3 below.
    nsym: i64,
    syms: u32[SYM_MAX],
    win: u8[WIN_SIZE],
}

fn lz_write(z: Lz&, data: const u8[:], out: u8[>..]&) {
    var at = 0;
    while at < data.len {
        let take = min(WIN_SIZE - z.fill, data.len - at);
        copy_into(z.win[z.fill..z.fill + take], data[at..at + take]);
        z.fill += take;
        at += take;
        lz_match(z, out, false);
        if z.fill == WIN_SIZE { slide(z, out); }
    }
}

// Ends the output so far on a byte boundary: the open block, then an empty
// stored block.
fn lz_flush(z: Lz&, out: u8[>..]&) {
    lz_match(z, out, true);
    if z.pos > z.block_start { end_block(z, out, false); }
    put_bits(z, out, 0, 3);
    align(z, out);
    out.append([0, 0, 0xff, 0xff]);
}

// Ends the stream with the open block as the final one, padded to the byte.
fn lz_finish(z: Lz&, out: u8[>..]&) {
    lz_match(z, out, true);
    end_block(z, out, true);
    align(z, out);
}

// Matches what the window holds: up to LOOKAHEAD bytes before its end, or to
// its end at a flush.
fn lz_match(z: Lz&, out: u8[>..]&, flushing: bool) {
    let end = if flushing { z.fill } else { z.fill - LOOKAHEAD + 1 };
    while z.pos < end {
        let p = z.pos;
        var len = 0;
        var dist = 0;
        if p + 4 <= z.fill {
            let h = hash4(z.win, p);
            let cand = z.head[h];
            let here = z.base + p as! u32;
            z.head[h] = here;
            let d: i64 = here - cand;
            if d >= 1 && d <= WSIZE && d <= p {
                len = match_len(z.win, p - d, p, min(MAX_MATCH, z.fill - p));
                dist = d;
            }
        }
        if len >= MIN_MATCH {
            add_sym(z, out, ((dist as! u32) << 8) | (len - MIN_MATCH) as! u32, len);
            for i in p + 1..min(p + len, z.fill - 3) {
                z.head[hash4(z.win, i)] = z.base + i as! u32;
            }
        } else {
            add_sym(z, out, z.win[p], 1);
        }
    }
}

fn add_sym(z: Lz&, out: u8[>..]&, sym: u32, advance: i64) {
    z.syms[z.nsym] = sym;
    z.nsym++;
    z.pos += advance;
    if z.nsym == SYM_MAX { end_block(z, out, false); }
}

// Drops the oldest WSIZE bytes. The window is full, so the matching stopped
// fewer than LOOKAHEAD bytes from its end, past 2 * WSIZE. The open block ends
// first if it starts in the bytes dropped, so a stored block can still be
// chosen for it.
fn slide(z: Lz&, out: u8[>..]&) {
    if z.block_start < WSIZE { end_block(z, out, false); }
    let keep = z.fill - WSIZE;
    copy_into(z.win[..keep], z.win[WSIZE..z.fill]);
    z.fill = keep;
    z.pos -= WSIZE;
    z.block_start -= WSIZE;
    z.base += WSIZE;
}

fn hash4(win: const u8[:], i: i64) -> i64 {
    let v = win[i] | (win[i + 1] as u32) << 8 | (win[i + 2] as u32) << 16 |
            (win[i + 3] as u32) << 24;
    return (v * 0x9E3779B1) >> (32 - HASH_BITS);
}

fn match_len(win: const u8[:], a: i64, b: i64, most: i64) -> i64 {
    var n = 0;
    while n < most && win[a + n] == win[b + n] { n++; }
    return n;
}

// Writes the block's symbols with the fixed tables, or the block's bytes
// stored, whichever takes fewer bits, and starts the next block.
fn end_block(z: Lz&, out: u8[>..]&, last: bool) {
    let syms = z.syms[..z.nsym];
    var fixed = 3 + 7;
    for s in syms {
        if s < 256 {
            fixed += FIXED_LIT_LEN[s];
        } else {
            let lc, lbits, lextra = len_code(s & 0xff);
            let dc, dbits, dextra = dist_code(s >> 8);
            fixed += FIXED_LIT_LEN[lc] + lbits + 5 + dbits;
        }
    }
    let data = z.win[z.block_start..z.pos];
    let chunks = max(1, (data.len + STORED_MAX - 1) / STORED_MAX);
    // Each stored block's header pads to the byte; only the first starts
    // off one.
    let stored_bits = 8 * data.len + chunks * (3 + 32) + (8 - (z.nbits + 3) % 8) % 8 +
                      (chunks - 1) * 5;
    if stored_bits < fixed {
        var at = 0;
        for c in chunks {
            let end = min(at + STORED_MAX, data.len);
            put_bits(z, out, if last && c == chunks - 1 { 1 } else { 0 }, 3);
            align(z, out);
            stored_body(out, data[at..end]);
            at = end;
        }
    } else {
        put_bits(z, out, if last { 3 } else { 2 }, 3);
        for s in syms {
            if s < 256 {
                put_bits(z, out, FIXED_LIT_CODE[s], FIXED_LIT_LEN[s]);
            } else {
                let lc, lbits, lextra = len_code(s & 0xff);
                put_bits(z, out, FIXED_LIT_CODE[lc], FIXED_LIT_LEN[lc]);
                put_bits(z, out, lextra, lbits);
                let dc, dbits, dextra = dist_code(s >> 8);
                put_bits(z, out, reverse_bits(dc as! u32, 5), 5);
                put_bits(z, out, dextra, dbits);
            }
        }
        put_bits(z, out, FIXED_LIT_CODE[256], FIXED_LIT_LEN[256]);
    }
    z.nsym = 0;
    z.block_start = z.pos;
}

// The length symbol (257-285) for a match length minus 3, with its extra bits'
// count and value (RFC 1951 §3.2.5).
fn len_code(x: u32) -> i64, i64, u32 {
    if x == 255 { return 285, 0, 0; }
    if x < 8 { return 257 + x as i64, 0, 0; }
    let n = 63 - clz(x);
    let extra = n - 2;
    return 257 + 4 * (n - 1) + ((x >> extra) & 3), extra, x & ((1 << extra) - 1);
}

// The distance code (0-29) for a distance, with its extra bits' count and
// value.
fn dist_code(d: u32) -> i64, i64, u32 {
    let x = d - 1;
    if x < 4 { return x, 0, 0; }
    let n = 63 - clz(x);
    let extra = n - 1;
    return 2 * n + ((x >> extra) & 1), extra, x & ((1 << extra) - 1);
}

// The fixed literal/length code of each symbol, bit-reversed, since DEFLATE
// packs Huffman codes from their most significant bit (RFC 1951 §3.1.1).
let FIXED_LIT_LEN = fixed_lit_lens();
let FIXED_LIT_CODE = fixed_lit_codes();

fn fixed_lit_lens() -> i64[288] {
    var t: i64[288] = [0; 288];
    for s in 288 {
        t[s] = if s < 144 { 8 } else if s < 256 { 9 } else if s < 280 { 7 } else { 8 };
    }
    return t;
}

fn fixed_lit_codes() -> u32[288] {
    var t: u32[288] = [0; 288];
    for s in 288 {
        let code = if s < 144 { 0x30 + s } else if s < 256 { 0x190 + s - 144 }
                   else if s < 280 { s - 256 } else { 0xC0 + s - 280 };
        t[s] = reverse_bits(code as! u32, FIXED_LIT_LEN[s]);
    }
    return t;
}

fn reverse_bits(code: u32, n: i64) -> u32 {
    var r: u32 = 0;
    for i in n { r |= ((code >> i) & 1) << (n - 1 - i); }
    return r;
}

fn put_bits(z: Lz&, out: u8[>..]&, v: u32, n: i64) {
    z.bits |= (v as u64) << z.nbits;
    z.nbits += n;
    while z.nbits >= 8 {
        out.push(z.bits as! u8);
        z.bits >>= 8;
        z.nbits -= 8;
    }
}

// Pads the bits to the byte with zeros.
fn align(z: Lz&, out: u8[>..]&) {
    if z.nbits > 0 { out.push(z.bits as! u8); }
    z.bits = 0;
    z.nbits = 0;
}
