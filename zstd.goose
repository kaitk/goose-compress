// The zstd frame (RFC 8878): a header declaring the window, blocks, and the
// low 32 bits of the content's XXH64. A block is compressed (§3.1.1.3), with
// its literals as zstd_literals.goose codes them and its sequences coded with
// the predefined FSE tables, or raw or RLE where that's no larger.
namespace compress;

import std;
import .checksum;
import .deflate;
import .zstd_fse;
import .zstd_literals;

// zstd's levels, 1 to 22, as its own. Each runs the nearest level built so far.
let ZSTD_DEFAULT_LEVEL = 3;
let ZSTD_MAX_LEVEL = 22;
// The largest block (RFC 8878 §3.1.1.2.4).
let ZSTD_BLOCK_MAX = 1 << 17;
let ZSTD_RAW = 0;
let ZSTD_RLE = 1;
let ZSTD_COMPRESSED = 2;
// The window the frame declares: matches reach back fewer than this many
// bytes (§3.1.1.4).
let ZSTD_WINDOW_LOG = 17;
let ZSTD_WINDOW = 1 << ZSTD_WINDOW_LOG;
// The window, a block, and room to slide by at least this much more each
// time, so a slide doesn't copy the window for every few bytes a flush ends.
let ZSTD_SLIDE = ZSTD_BLOCK_MAX / 4;
let ZSTD_WIN_SIZE = ZSTD_WINDOW + ZSTD_BLOCK_MAX + ZSTD_SLIDE;
// Level 1's hash table, of the first ZSTD_HASH_BYTES bytes at a position.
let ZSTD_HASH_LOG = 15;
let ZSTD_HASH_SIZE = 1 << ZSTD_HASH_LOG;
let ZSTD_HASH_BYTES = 6;
// How fast level 1 steps over input where it finds no match: 1 more position
// a probe for each 2^ZSTD_SKIP_LOG it has gone without one.
let ZSTD_SKIP_LOG = 7;
// A block ends when it holds this many sequences.
let ZSTD_SEQ_MAX = 1 << 14;

// A zstd stream. Its blocks depend only on its input and where it was flushed,
// not on how the input was split across writes: a block is matched once it
// is whole, at ZSTD_BLOCK_MAX bytes or at a flush.
struct ZstdEncoder {
    level: i64 = ZSTD_DEFAULT_LEVEL,
    started: bool = false,
    finished: bool = false,
    check: Xxh64,
    // The stream offset of win[0], modulo 2^32.
    base: u32 = 0,
    // win[..fill] holds input; the next block starts at pos.
    fill: i64 = 0,
    pos: i64 = 0,
    // The repeat offsets a decoder holds after the last compressed block
    // (§3.1.1.5), and the two offsets the matcher tries first, its last ones.
    rep0: i64 = 1,
    rep1: i64 = 4,
    rep2: i64 = 8,
    off1: i64 = 1,
    off2: i64 = 4,
    // Each hash bucket's latest stream offset. An entry only suggests where a
    // match may start, so every candidate is compared.
    head: u32[ZSTD_HASH_SIZE],
    // The block's sequences: the literal length in bits 0-19, the match
    // length from bit 20, and the distance from bit 40, which the block's
    // coding replaces with the offset value. `matched` sums the match lengths.
    nseq: i64 = 0,
    matched: i64 = 0,
    seqs: u64[ZSTD_SEQ_MAX],
    win: u8[ZSTD_WIN_SIZE],
}

fn zstd_encoder(level: i64 = ZSTD_DEFAULT_LEVEL) -> ZstdEncoder {
    assert(level >= 1 && level <= ZSTD_MAX_LEVEL);
    return ZstdEncoder { level: level, check: Xxh64 { .. }, .. };
}

// Starts e over as a new stream, as zstd_encoder(level) would make it. The
// window and the sequences are left as they are: nothing reads them before
// it writes them.
fn reset(e: ZstdEncoder&, level: i64 = ZSTD_DEFAULT_LEVEL) {
    assert(level >= 1 && level <= ZSTD_MAX_LEVEL);
    e.level = level;
    e.started = false;
    e.finished = false;
    xxh64_reset(e.check);
    e.base = 0;
    e.fill = 0;
    e.pos = 0;
    e.rep0 = 1;
    e.rep1 = 4;
    e.rep2 = 8;
    e.off1 = 1;
    e.off2 = 4;
    for &x in e.head { x = 0; }
    e.nseq = 0;
    e.matched = 0;
}

// A full block is held until more input comes, so the last block can carry
// the last-block flag.
fn write(e: ZstdEncoder&, data: const u8[:], out: u8[>..]&) {
    assert(!e.finished);
    zstd_header(e, out);
    xxh64_update(e.check, data);
    var at = 0;
    while at < data.len {
        if e.fill == ZSTD_WIN_SIZE { zstd_slide(e); }
        let take = min(ZSTD_WIN_SIZE - e.fill, data.len - at);
        copy_into(e.win[e.fill..e.fill + take], data[at..at + take]);
        e.fill += take;
        at += take;
        while e.fill - e.pos > ZSTD_BLOCK_MAX {
            next_block(e, out, e.pos + ZSTD_BLOCK_MAX, false);
        }
    }
}

// Ends the output so far on a block, so a reader can decompress all the input
// written so far. zstd blocks end on a byte boundary, so nothing else is
// needed. The stream continues after it.
fn flush(e: ZstdEncoder&, out: u8[>..]&) {
    assert(!e.finished);
    zstd_header(e, out);
    while e.pos < e.fill { next_block(e, out, e.fill, false); }
}

// Ends the stream: the held input, its last block flagged, then the checksum.
// With no input held, the last block is empty.
fn finish(e: ZstdEncoder&, out: u8[>..]&) {
    assert(!e.finished);
    zstd_header(e, out);
    next_block(e, out, e.fill, true);
    while e.pos < e.fill { next_block(e, out, e.fill, true); }
    put_le32(out, xxh64_digest(e.check) as! u32);
    e.finished = true;
}

fn zstd_header(e: ZstdEncoder&, out: u8[>..]&) {
    guard !e.started else { return; }
    e.started = true;
    // The magic number; a descriptor with only the checksum flag, so no
    // content size or dictionary and a window descriptor follows; the window
    // as 2^(10 + exponent).
    out.append([0x28, 0xB5, 0x2F, 0xFD, 0x04, (ZSTD_WINDOW_LOG - 10) << 3]);
}

// Drops the input more than a window before the next block. The window is
// full and holds less than a block past pos, so pos is past the window and
// the slide frees at least ZSTD_SLIDE bytes.
fn zstd_slide(e: ZstdEncoder&) {
    let shift = e.pos - ZSTD_WINDOW;
    assert(shift >= ZSTD_SLIDE);
    let keep = e.fill - shift;
    copy_into(e.win[..keep], e.win[shift..e.fill]);
    e.fill = keep;
    e.pos -= shift;
    e.base += shift as! u32;
}

// Writes win[pos..end] as a block, or as much of it as the block's sequences
// reach before they fill. It's flagged as the stream's last if `last` is and
// it reaches end.
fn next_block(e: ZstdEncoder&, out: u8[>..]&, end: i64, last: bool) {
    let start = e.pos;
    e.nseq = 0;
    e.matched = 0;
    let stop = match_zstd_fast(e, start, end);
    zstd_block(e, out, start, stop, last && stop == end);
    e.pos = stop;
}

fn hash_zstd(v: u64) -> i64 {
    return (((v << (64 - 8 * ZSTD_HASH_BYTES)) * 0x9E3779B97F4A7C15) >> (64 - ZSTD_HASH_LOG))
        as! i64;
}

// Level 1, after libzstd's ZSTD_fast: probes two positions a step, one hash
// table entry each, and before them the last offset two positions on. A match
// is extended backward, then forward to the block's end. The step grows the
// longer it goes without a match. Returns where the block ends: at `end`, or
// sooner if its sequences fill.
fn match_zstd_fast(e: ZstdEncoder&, start: i64, end: i64) -> i64 {
    // A position is probed only with 8 bytes after it, which the hash reads.
    let limit = end - 8;
    var anchor = start;
    var ip = start;
    var off1 = e.off1;
    var off2 = e.off2;
    while ip + 1 < limit {
        let probe = ip;
        let here = e.base + ip as! u32;
        let h0 = hash_zstd(load64(e.win, ip));
        let h1 = hash_zstd(load64(e.win, ip + 1));
        let c0 = e.head[h0];
        let c1 = e.head[h1];
        e.head[h0] = here;
        e.head[h1] = here + 1;
        var p = ip + 2;
        var d = off1;
        if d <= p && load32(e.win, p - d) == load32(e.win, p) {
            // One byte back at most, as libzstd's.
            if p - 1 - d >= 0 && e.win[p - 1] == e.win[p - 1 - d] { p--; }
        } else {
            p = ip;
            d = here - c0;
            if !(d >= 1 && d < ZSTD_WINDOW && d <= p && load32(e.win, p - d) == load32(e.win, p)) {
                p = ip + 1;
                d = here + 1 - c1;
                if !(d >= 1 && d < ZSTD_WINDOW && d <= p &&
                     load32(e.win, p - d) == load32(e.win, p)) {
                    ip += ((ip - anchor) >> ZSTD_SKIP_LOG) + 2;
                    continue;
                }
            }
            while p > anchor && p - d > 0 && e.win[p - 1] == e.win[p - 1 - d] { p--; }
            off2 = off1;
            off1 = d;
        }
        let len = 4 + match_len(e.win, p - d + 4, p + 4, end - p - 4);
        zstd_seq(e, p - anchor, d, len);
        ip = p + len;
        anchor = ip;
        guard e.nseq < ZSTD_SEQ_MAX else { break; }
        guard ip <= limit else { continue; }
        e.head[hash_zstd(load64(e.win, probe + 2))] = here + 2;
        e.head[hash_zstd(load64(e.win, ip - 2))] = e.base + (ip - 2) as! u32;
        // The offset before the last, at once, as a sequence with no
        // literals: a repeat offset.
        while ip <= limit && off2 <= ip && load32(e.win, ip - off2) == load32(e.win, ip) {
            let n = 4 + match_len(e.win, ip - off2 + 4, ip + 4, end - ip - 4);
            let t = off2;
            off2 = off1;
            off1 = t;
            e.head[hash_zstd(load64(e.win, ip))] = e.base + ip as! u32;
            zstd_seq(e, 0, off1, n);
            ip += n;
            anchor = ip;
            guard e.nseq < ZSTD_SEQ_MAX else { break; }
        }
        guard e.nseq < ZSTD_SEQ_MAX else { break; }
    }
    e.off1 = off1;
    e.off2 = off2;
    return if e.nseq == ZSTD_SEQ_MAX { anchor } else { end };
}

fn zstd_seq(e: ZstdEncoder&, lits: i64, dist: i64, len: i64) {
    e.seqs[e.nseq] = lits as! u64 | (len as! u64) << 20 | (dist as! u64) << 40;
    e.nseq++;
    e.matched += len;
}

// One block of win[start..end]: compressed where that's smaller, else raw, or
// RLE where it's one repeated byte. A compressed block may hold literals
// alone.
fn zstd_block(e: ZstdEncoder&, out: u8[>..]&, start: i64, end: i64, last: bool) {
    let data = e.win[start..end];
    let run = is_run(data);
    if !run {
        let seqs = e.seqs[..e.nseq];
        var l = ZstdLits { .. };
        plan_literals(seqs, data, data.len - e.matched, l);
        let r0, r1, r2 = offset_values(e);
        let n = e.nseq;
        let sh = if n == 0 { 1 } else if n < 128 { 2 } else if n < 0x7F00 { 3 } else { 4 };
        let size = l.size + sh + (if n > 0 { (seq_bits(e) + 1 + 7) / 8 } else { 0 });
        if size < data.len {
            put_le24(out, size << 3 | ZSTD_COMPRESSED << 1 | (if last { 1 } else { 0 }));
            put_literals(seqs, out, data, l);
            if n < 128 {
                out.push(n as! u8);
            } else if n < 0x7F00 {
                out.append([(n >> 8 | 0x80) as! u8, n as! u8]);
            } else {
                out.append([0xFF, (n - 0x7F00) as! u8, ((n - 0x7F00) >> 8) as! u8]);
            }
            if n > 0 {
                // Symbol_Compression_Modes: the predefined tables for all three.
                out.push(0);
                put_seqs(e, out);
            }
            e.rep0 = r0;
            e.rep1 = r1;
            e.rep2 = r2;
            return;
        }
    }
    zstd_stored(out, data, run, last);
}

fn is_run(data: const u8[:]) -> bool {
    for b in data { guard b == data[0] else { return false; } }
    return data.len > 1;
}

// Replaces each sequence's distance with its offset value, as a decoder
// tracks the repeat offsets from the last compressed block (§3.1.1.5), and
// returns the repeat offsets after the block.
fn offset_values(e: ZstdEncoder&) -> i64, i64, i64 {
    var r0 = e.rep0;
    var r1 = e.rep1;
    var r2 = e.rep2;
    for &s in e.seqs[..e.nseq] {
        let lits = s & 0xFFFFF;
        let d = (s >> 40) as i64;
        var v = d + 3;
        if lits > 0 && d == r0 {
            v = 1;
        } else if d == r1 {
            // With no literals, the repeat offsets shift by one: 1 is the
            // second, 2 the third, and 3 the first less 1.
            v = if lits > 0 { 2 } else { 1 };
            r1 = r0;
            r0 = d;
        } else if d == r2 {
            v = if lits > 0 { 3 } else { 2 };
            r2 = r1;
            r1 = r0;
            r0 = d;
        } else {
            if lits == 0 && d == r0 - 1 { v = 3; }
            r2 = r1;
            r1 = r0;
            r0 = d;
        }
        s = (s & 0xFFFFFFFFFF) | (v as! u64) << 40;
    }
    return r0, r1, r2;
}

// Literal lengths and match lengths as codes with extra bits (§3.1.1.3.2.1.1):
// each code's baseline and extra bits' count.
let LL_BASE = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 18, 20, 22, 24,
               28, 32, 40, 48, 64, 128, 256, 512, 1024, 2048, 4096, 8192, 16384, 32768,
               65536];
let LL_BITS = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 3, 3, 4,
               6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16];
let ML_BASE = [3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23,
               24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 37, 39, 41, 43, 47, 51, 59,
               67, 83, 99, 131, 259, 515, 1027, 2051, 4099, 8195, 16387, 32771, 65539];
let ML_BITS = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
               0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 3, 3, 4, 4, 5, 7, 8, 9, 10, 11, 12,
               13, 14, 15, 16];
// The codes of the short lengths, from the tables above; longer ones take a
// code a power of two.
let LL_CODE = length_codes(LL_BASE, 0, 64);
let ML_CODE = length_codes(ML_BASE, 3, 128);

fn length_codes(base: const i64[:], min: i64, n: i64) -> u8[128] {
    var t: u8[128] = [0; 128];
    var c = 0;
    for i in n {
        while c + 1 < base.len && base[c + 1] <= min + i { c++; }
        t[i] = c as! u8;
    }
    return t;
}

fn ll_code(lits: i64) -> i64 {
    return if lits < 64 { LL_CODE[lits] } else { log2_zstd(lits) + 19 };
}

// The code of a match length less 3.
fn ml_code(x: i64) -> i64 {
    return if x < 128 { ML_CODE[x] } else { log2_zstd(x) + 36 };
}

// The base-2 logarithm, rounded down, of x below 2^24.
fn log2_zstd(x: i64) -> i64 {
    return if x >= 1 << 16 { 16 + LOG2[(x >> 16) & 255] }
           else if x >= 256 { 8 + LOG2[(x >> 8) & 255] }
           else { LOG2[x & 255] };
}

// The predefined distributions (§3.1.1.3.2.2), where -1 is a probability
// "less than 1".
let LL_NORM = [4, 3, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 1, 1, 2, 2, 2, 2, 2, 2, 2, 2, 2,
               3, 2, 1, 1, 1, 1, 1, -1, -1, -1, -1];
let ML_NORM = [1, 4, 3, 2, 2, 2, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
               1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, -1, -1, -1,
               -1, -1, -1, -1];
let OF_NORM = [1, 1, 1, 1, 1, 1, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, -1,
               -1, -1, -1, -1];
let LL_FSE = fse_table(LL_NORM, 6);
let ML_FSE = fse_table(ML_NORM, 6);
let OF_FSE = fse_table(OF_NORM, 5);

// One sequence's codes and extra bits: the literal length's, the match
// length's, and the offset's.
fn seq_codes(s: u64) -> i64, i64, i64, i64, i64, i64 {
    let lits = (s & 0xFFFFF) as i64;
    let x = (((s >> 20) & 0xFFFFF) as i64) - 3;
    let v = (s >> 40) as i64;
    let lc = ll_code(lits);
    let mc = ml_code(x);
    let oc = log2_zstd(v);
    return lc, lits - LL_BASE[lc], mc, x + 3 - ML_BASE[mc], oc, v - (1 << oc);
}

// The bits put_seqs writes, the closing 1 bit aside.
fn seq_bits(e: ZstdEncoder&) -> i64 {
    var i = e.nseq - 1;
    let lc, lx, mc, mx, oc, ox = seq_codes(e.seqs[i]);
    var sl = LL_FSE.enc[lc * 64];
    var sm = ML_FSE.enc[mc * 64];
    var so = OF_FSE.enc[oc * 64];
    var n = 6 + 6 + 5 + LL_BITS[lc] + ML_BITS[mc] + oc;
    while i > 0 {
        i--;
        let lc1, lx1, mc1, mx1, oc1, ox1 = seq_codes(e.seqs[i]);
        so = OF_FSE.enc[oc1 * 64 + so];
        sm = ML_FSE.enc[mc1 * 64 + sm];
        sl = LL_FSE.enc[lc1 * 64 + sl];
        n += OF_FSE.nb[so] + ML_FSE.nb[sm] + LL_FSE.nb[sl] + LL_BITS[lc1] + ML_BITS[mc1] + oc1;
    }
    return n;
}

// The sequences' bitstream (§3.1.1.3.2.1.2), which a decoder reads from its
// end: so it's written from the last sequence to the first. Each sequence
// writes the states its decoder moves on by, offset's first, then its extra
// bits, the literal length's first, and the first sequence's states close it,
// the literal length's last, then a 1 bit. A sequence's bits are written to
// a buffer in two parts, each under 57 bits, and the whole bytes kept.
fn put_seqs(e: ZstdEncoder&, out: u8[>..]&) {
    // A sequence writes up to 14 bytes before the buffer is checked.
    var buf: u8[STAGE + 16] = [0; STAGE + 16];
    var o = 0;
    var bits: u64 = 0;
    var nbits = 0;
    var i = e.nseq - 1;
    let lc, lx, mc, mx, oc, ox = seq_codes(e.seqs[i]);
    var sl = LL_FSE.enc[lc * 64];
    var sm = ML_FSE.enc[mc * 64];
    var so = OF_FSE.enc[oc * 64];
    bits = lx as! u64;
    nbits = LL_BITS[lc];
    bits |= (mx as! u64) << nbits;
    nbits += ML_BITS[mc];
    bits |= (ox as! u64) << nbits;
    nbits += oc;
    put_le64(buf[o..o + 8], bits);
    o += nbits >> 3;
    bits >>= nbits & ~7;
    nbits &= 7;
    while i > 0 {
        i--;
        let lc1, lx1, mc1, mx1, oc1, ox1 = seq_codes(e.seqs[i]);
        let to = OF_FSE.enc[oc1 * 64 + so];
        bits |= ((so - OF_FSE.base[to]) as u64) << nbits;
        nbits += OF_FSE.nb[to];
        so = to;
        let tm = ML_FSE.enc[mc1 * 64 + sm];
        bits |= ((sm - ML_FSE.base[tm]) as u64) << nbits;
        nbits += ML_FSE.nb[tm];
        sm = tm;
        let tl = LL_FSE.enc[lc1 * 64 + sl];
        bits |= ((sl - LL_FSE.base[tl]) as u64) << nbits;
        nbits += LL_FSE.nb[tl];
        sl = tl;
        bits |= (lx1 as! u64) << nbits;
        nbits += LL_BITS[lc1];
        bits |= (mx1 as! u64) << nbits;
        nbits += ML_BITS[mc1];
        put_le64(buf[o..o + 8], bits);
        o += nbits >> 3;
        bits >>= nbits & ~7;
        nbits &= 7;
        bits |= (ox1 as! u64) << nbits;
        nbits += oc1;
        put_le64(buf[o..o + 8], bits);
        o += nbits >> 3;
        bits >>= nbits & ~7;
        nbits &= 7;
        if o >= STAGE {
            out.append(buf[..o]);
            o = 0;
        }
    }
    bits |= (sm as u64) << nbits;
    nbits += 6;
    bits |= (so as u64) << nbits;
    nbits += 5;
    bits |= (sl as u64) << nbits;
    nbits += 6;
    bits |= (1 as u64) << nbits;
    nbits++;
    put_le64(buf[o..o + 8], bits);
    o += (nbits + 7) >> 3;
    out.append(buf[..o]);
}

// A block of data, not compressed: one repeated byte as an RLE block, the
// rest raw.
fn zstd_stored(out: u8[>..]&, data: const u8[:], run: bool, last: bool) {
    assert(data.len <= ZSTD_BLOCK_MAX);
    let kind = if run { ZSTD_RLE } else { ZSTD_RAW };
    put_le24(out, data.len << 3 | kind << 1 | (if last { 1 } else { 0 }));
    if kind == ZSTD_RLE {
        out.push(data[0]);
    } else {
        out.append(data);
    }
}

fn put_le24(out: u8[>..]&, v: i64) {
    out.append([v as! u8, (v >> 8) as! u8, (v >> 16) as! u8]);
}
