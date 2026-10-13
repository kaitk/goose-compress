// The zstd frame (RFC 8878): a header declaring the window, blocks, and the
// low 32 bits of the content's XXH64. A block is compressed (§3.1.1.3), with
// its literals as zstd_literals.goose codes them and its sequences coded with
// FSE tables chosen for the block, or raw or RLE where that's no larger.
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
// Level 3's tables, as libzstd's for inputs up to 128 KB: `head` of the first
// ZSTD_SHORT_BYTES bytes at a position, and `long` of the first 8.
let ZSTD_SHORT_BYTES = 5;
let ZSTD_LONG_LOG = 16;
let ZSTD_LONG_SIZE = 1 << ZSTD_LONG_LOG;
// Level 3's step over input with no match grows by 1 every this many bytes.
let ZSTD_DFAST_STEP = 1 << 8;
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
    // The offset of win[0], counted from the tables' last clear, which the
    // tables hold modulo 2^32. A stream starts a window past the last one's
    // end, so no entry it finds from before is in reach.
    base: i64 = ZSTD_WINDOW,
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
    // Each hash bucket's latest offset, 0 for none. An entry only suggests
    // where a match may start, so every candidate is compared. Level 3 uses
    // `long` too.
    head: u32[ZSTD_HASH_SIZE],
    long: u32[ZSTD_LONG_SIZE],
    // The block's sequences: the literal length in bits 0-19, the match
    // length from bit 20, and the distance from bit 40, which the block's
    // coding replaces with the offset value. `matched` sums the match lengths.
    nseq: i64 = 0,
    matched: i64 = 0,
    seqs: u64[ZSTD_SEQ_MAX],
    // The block's literals, copied in order as each sequence is stored.
    nlit: i64 = 0,
    lits: u8[ZSTD_BLOCK_MAX],
    // Each sequence's literal length, offset, and match length codes.
    llc: u8[ZSTD_SEQ_MAX],
    ofc: u8[ZSTD_SEQ_MAX],
    mlc: u8[ZSTD_SEQ_MAX],
    // The tables a decoder holds for each kind of code, from the last block
    // with sequences, which a block may repeat: kind k's at fse[2k + cur[k]],
    // and the other slot free for the next block's. A frame has none until
    // its first such block.
    tables: bool = false,
    cur: i64[3],
    fse: Fse[6],
    win: u8[ZSTD_WIN_SIZE],
}

fn zstd_encoder(level: i64 = ZSTD_DEFAULT_LEVEL) -> ZstdEncoder {
    assert(level >= 1 && level <= ZSTD_MAX_LEVEL);
    return ZstdEncoder { level: level, check: Xxh64 { .. }, .. };
}

// Starts e over as a new stream, as zstd_encoder(level) would make it. The
// window and the sequences are left as they are: nothing reads them before
// it writes them. The hash tables are kept, with the stream starting out of
// their entries' reach, until its offsets would pass 2^31: the stream then
// codes as a new encoder's does for its first 2 GB, as far as the tables'
// offsets go without wrapping either way.
fn reset(e: ZstdEncoder&, level: i64 = ZSTD_DEFAULT_LEVEL) {
    assert(level >= 1 && level <= ZSTD_MAX_LEVEL);
    e.level = level;
    e.started = false;
    e.finished = false;
    xxh64_reset(e.check);
    e.base += e.fill + ZSTD_WINDOW;
    if e.base > 1 << 31 {
        for &x in e.head { x = 0; }
        for &x in e.long { x = 0; }
        e.base = ZSTD_WINDOW;
    }
    e.fill = 0;
    e.pos = 0;
    e.rep0 = 1;
    e.rep1 = 4;
    e.rep2 = 8;
    e.off1 = 1;
    e.off2 = 4;
    e.nseq = 0;
    e.matched = 0;
    e.tables = false;
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
    e.base += shift;
}

// Writes win[pos..end] as a block, or as much of it as the block's sequences
// reach before they fill. It's flagged as the stream's last if `last` is and
// it reaches end.
fn next_block(e: ZstdEncoder&, out: u8[>..]&, end: i64, last: bool) {
    let start = e.pos;
    e.nseq = 0;
    e.matched = 0;
    e.nlit = 0;
    let stop = if e.level == 1 { match_zstd_fast(e, start, end) }
               else { match_zstd_dfast(e, start, end) };
    zstd_block(e, out, start, stop, last && stop == end);
    e.pos = stop;
}

// `% ZSTD_HASH_SIZE` lets the compiler drop the table's bounds check.
fn hash_zstd(v: u64) -> i64 {
    return ((((v << (64 - 8 * ZSTD_HASH_BYTES)) * 0x9E3779B97F4A7C15) >> (64 - ZSTD_HASH_LOG))
        % ZSTD_HASH_SIZE) as! i64;
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
        let here = (e.base + ip) as! u32;
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
        zstd_seq(e, anchor, p - anchor, d, len);
        ip = p + len;
        anchor = ip;
        guard e.nseq < ZSTD_SEQ_MAX else { break; }
        guard ip <= limit else { continue; }
        e.head[hash_zstd(load64(e.win, probe + 2))] = here + 2;
        e.head[hash_zstd(load64(e.win, ip - 2))] = (e.base + ip - 2) as! u32;
        // The offset before the last, at once, as a sequence with no
        // literals: a repeat offset.
        while ip <= limit && off2 <= ip && load32(e.win, ip - off2) == load32(e.win, ip) {
            let n = 4 + match_len(e.win, ip - off2 + 4, ip + 4, end - ip - 4);
            let t = off2;
            off2 = off1;
            off1 = t;
            e.head[hash_zstd(load64(e.win, ip))] = (e.base + ip) as! u32;
            zstd_seq(e, ip, 0, off1, n);
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

fn hash_short(v: u64) -> i64 {
    return ((((v << (64 - 8 * ZSTD_SHORT_BYTES)) * 0x9E3779B97F4A7C15) >> (64 - ZSTD_HASH_LOG))
        % ZSTD_HASH_SIZE) as! i64;
}

fn hash_long(v: u64) -> i64 {
    return (((v * 0x9E3779B97F4A7C15) >> (64 - ZSTD_LONG_LOG)) % ZSTD_LONG_SIZE) as! i64;
}

// Level 3, after libzstd's ZSTD_dfast: each position checks the last offset
// one position on, then the long table, then the short one, where a match
// takes the next position's long match if that's longer. A match is extended
// backward, then forward to the block's end; after it, the offset before the
// last is tried at once, as at level 1. The step grows by one position every
// ZSTD_DFAST_STEP without a match. Returns where the block ends, as
// match_zstd_fast does.
fn match_zstd_dfast(e: ZstdEncoder&, start: i64, end: i64) -> i64 {
    // A position is probed only with 8 bytes after it, which the hashes read.
    let limit = end - 8;
    var anchor = start;
    var ip = start;
    var off1 = e.off1;
    var off2 = e.off2;
    while ip + 1 <= limit {
        var step = 1;
        var next_step = ip + ZSTD_DFAST_STEP;
        var ip1 = ip + 1;
        var hl0 = hash_long(load64(e.win, ip));
        var cl0 = e.long[hl0];
        var hl1 = 0;
        // The match: where it starts, its distance, and its length, with p
        // left at -1 if the search reaches the block's end first.
        var p = -1;
        var d = 0;
        var len = 0;
        var rep = false;
        while ip1 <= limit {
            let here = (e.base + ip) as! u32;
            let hs0 = hash_short(load64(e.win, ip));
            let cs0 = e.head[hs0];
            e.long[hl0] = here;
            e.head[hs0] = here;
            if off1 <= ip + 1 && load32(e.win, ip + 1 - off1) == load32(e.win, ip + 1) {
                p = ip + 1;
                d = off1;
                len = 4 + match_len(e.win, p - d + 4, p + 4, end - p - 4);
                rep = true;
                break;
            }
            hl1 = hash_long(load64(e.win, ip1));
            let dl = (here - cl0) as i64;
            if dl >= 1 && dl < ZSTD_WINDOW && dl <= ip && load64(e.win, ip - dl) == load64(e.win, ip) {
                p = ip;
                d = dl;
                len = 8 + match_len(e.win, p - d + 8, p + 8, end - p - 8);
                break;
            }
            let cl1 = e.long[hl1];
            let ds = (here - cs0) as i64;
            if ds >= 1 && ds < ZSTD_WINDOW && ds <= ip && load32(e.win, ip - ds) == load32(e.win, ip) {
                p = ip;
                d = ds;
                len = 4 + match_len(e.win, p - d + 4, p + 4, end - p - 4);
                let d1 = ((e.base + ip1) as! u32 - cl1) as i64;
                if d1 >= 1 && d1 < ZSTD_WINDOW && d1 <= ip1 &&
                   load64(e.win, ip1 - d1) == load64(e.win, ip1) {
                    let n = 8 + match_len(e.win, ip1 - d1 + 8, ip1 + 8, end - ip1 - 8);
                    if n > len {
                        p = ip1;
                        d = d1;
                        len = n;
                    }
                }
                break;
            }
            if ip1 >= next_step {
                step++;
                next_step += ZSTD_DFAST_STEP;
            }
            ip = ip1;
            ip1 += step;
            hl0 = hl1;
            cl0 = cl1;
        }
        guard p >= 0 else { break; }
        let probe = ip;
        if !rep {
            while p > anchor && p - d > 0 && e.win[p - 1] == e.win[p - 1 - d] {
                p--;
                len++;
            }
            off2 = off1;
            off1 = d;
            // ip1 is inside the match only while the step is under the
            // shortest match.
            if step < 4 { e.long[hl1] = (e.base + ip1) as! u32; }
        }
        zstd_seq(e, anchor, p - anchor, d, len);
        ip = p + len;
        anchor = ip;
        guard e.nseq < ZSTD_SEQ_MAX else { break; }
        guard ip <= limit else { continue; }
        let v2 = load64(e.win, probe + 2);
        e.long[hash_long(v2)] = (e.base + probe + 2) as! u32;
        e.head[hash_short(v2)] = (e.base + probe + 2) as! u32;
        e.long[hash_long(load64(e.win, ip - 2))] = (e.base + ip - 2) as! u32;
        e.head[hash_short(load64(e.win, ip - 1))] = (e.base + ip - 1) as! u32;
        while ip <= limit && off2 <= ip && load32(e.win, ip - off2) == load32(e.win, ip) {
            let n = 4 + match_len(e.win, ip - off2 + 4, ip + 4, end - ip - 4);
            let t = off2;
            off2 = off1;
            off1 = t;
            let v = load64(e.win, ip);
            e.long[hash_long(v)] = (e.base + ip) as! u32;
            e.head[hash_short(v)] = (e.base + ip) as! u32;
            zstd_seq(e, ip, 0, off1, n);
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

// Stores a sequence: the literals win[from..from + lits], then a match.
fn zstd_seq(e: ZstdEncoder&, from: i64, lits: i64, dist: i64, len: i64) {
    copy_into(e.lits[e.nlit..e.nlit + lits], e.win[from..from + lits]);
    e.nlit += lits;
    e.seqs[e.nseq] = lits as! u64 | (len as! u64) << 20 | (dist as! u64) << 40;
    e.nseq++;
    e.matched += len;
}

// One block of win[start..end]: compressed where that's smaller, else raw, or
// RLE where it's one repeated byte. A compressed block may hold literals
// alone. Where a bound on the sequences' bits shows it's smaller, it's written
// at once, its header filled in after; else the bits are counted first.
fn zstd_block(e: ZstdEncoder&, out: u8[>..]&, start: i64, end: i64, last: bool) {
    let data = e.win[start..end];
    let run = is_run(data);
    if !run {
        let seqs = e.seqs[..e.nseq];
        // The literals after the last match.
        let nl = data.len - e.matched;
        copy_into(e.lits[e.nlit..nl], data[data.len - (nl - e.nlit)..]);
        let lits = e.lits[..nl];
        var l = ZstdLits { .. };
        plan_literals(lits, l);
        var cl: i64[256] = [0; 256];
        var co: i64[256] = [0; 256];
        var cm: i64[256] = [0; 256];
        let r0, r1, r2 = code_seqs(e, cl, co, cm);
        let n = e.nseq;
        let sh = if n == 0 { 1 } else if n < 128 { 2 } else if n < 0x7F00 { 3 } else { 4 };
        var size = l.size + sh;
        var bound = size;
        // Each kind's mode and description, and the slot of its table.
        var mode: i64[3] = [0; 3];
        var slot: i64[3] = [0; 3];
        var desc: Bits[3] = [Bits { .. }; 3];
        if n > 0 {
            // The codes a coder starts in, the last sequence's.
            let first = [e.llc[n - 1], e.ofc[n - 1], e.mlc[n - 1]];
            var bits = 1;
            for k in 3 {
                let kc = if k == ZSTD_LL { cl[..FSE_SYMS] } else if k == ZSTD_OF { co[..FSE_SYMS] }
                         else { cm[..FSE_SYMS] };
                mode[k] = plan_table(e, k, kc, first[k], desc[k]);
                slot[k] = 2 * k + (if mode[k] == FSE_REPEAT { e.cur[k] } else { 1 - e.cur[k] });
                size += desc[k].o;
                bits += seq_bound(e.fse[slot[k]], k, kc);
            }
            bound = size + (bits + 7) / 8;
            if bound >= data.len {
                let tl .= e.fse[slot[ZSTD_LL]];
                let to .= e.fse[slot[ZSTD_OF]];
                let tm .= e.fse[slot[ZSTD_ML]];
                size += (seq_bits(e, tl, to, tm) + 1 + 7) / 8;
            }
        }
        if bound < data.len || size < data.len {
            let at = out.len;
            put_le24(out, 0);
            put_literals(out, lits, l);
            if n < 128 {
                out.push(n as! u8);
            } else if n < 0x7F00 {
                out.append([(n >> 8 | 0x80) as! u8, n as! u8]);
            } else {
                out.append([0xFF, (n - 0x7F00) as! u8, ((n - 0x7F00) >> 8) as! u8]);
            }
            if n > 0 {
                out.push((mode[ZSTD_LL] << 6 | mode[ZSTD_OF] << 4 | mode[ZSTD_ML] << 2) as! u8);
                for k in 3 {
                    out.append(desc[k].buf[..desc[k].o]);
                    e.cur[k] = slot[k] - 2 * k;
                }
                e.tables = true;
                put_seqs(e, out, e.fse[slot[ZSTD_LL]], e.fse[slot[ZSTD_OF]],
                         e.fse[slot[ZSTD_ML]]);
            }
            let h = (out.len - at - 3) << 3 | ZSTD_COMPRESSED << 1 | (if last { 1 } else { 0 });
            out[at] = h as! u8;
            out[at + 1] = (h >> 8) as! u8;
            out[at + 2] = (h >> 16) as! u8;
            e.rep0 = r0;
            e.rep1 = r1;
            e.rep2 = r2;
            return;
        }
    }
    zstd_stored(out, data, run, last);
}

// The most bits kind k's codes, of these counts, take in table t: each code's
// extra bits, and the most bits a state of its writes. The first sequence's
// state, written whole, is at most t.log of them.
fn seq_bound(t: Fse&, k: i64, count: const i64[:]) -> i64 {
    let most = (2 << t.log) - 1;
    var bits = t.log;
    for c, s in count {
        guard c > 0 else { continue; }
        let extra = if k == ZSTD_LL { LL_BITS[s] } else if k == ZSTD_ML { ML_BITS[s] } else { s };
        bits += c * (((most + t.dnb[s]) >> 16) + extra);
    }
    return bits;
}

fn is_run(data: const u8[:]) -> bool {
    for b in data { guard b == data[0] else { return false; } }
    return data.len > 1;
}

// Replaces each sequence's distance with its offset value, as a decoder
// tracks the repeat offsets from the last compressed block (§3.1.1.5), and
// returns the repeat offsets after the block. Sets each sequence's codes, and
// counts them in cl, co, and cm, which a u8 code indexes without a bounds check.
fn code_seqs(e: ZstdEncoder&, cl: i64[256]&, co: i64[256]&, cm: i64[256]&) -> i64, i64, i64 {
    var r0 = e.rep0;
    var r1 = e.rep1;
    var r2 = e.rep2;
    for &s, i in e.seqs[..e.nseq] {
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
        let lc = ll_code(lits as i64) as! u8;
        let oc = log2_zstd(v) as! u8;
        let mc = ml_code(((s >> 20) & 0xFFFFF) as i64 - 3) as! u8;
        e.llc[i % ZSTD_SEQ_MAX] = lc;
        e.ofc[i % ZSTD_SEQ_MAX] = oc;
        e.mlc[i % ZSTD_SEQ_MAX] = mc;
        cl[lc]++;
        co[oc]++;
        cm[mc]++;
    }
    return r0, r1, r2;
}

// The kinds of a sequence's codes, in the order a block gives their modes
// (§3.1.1.3.2.1): literal lengths, offsets, and match lengths. Each has a
// predefined table, and a built one takes an accuracy of at most SEQ_LOG.
let ZSTD_LL = 0;
let ZSTD_OF = 1;
let ZSTD_ML = 2;
let SEQ_LOG = [9, 8, 9];

// The modes a block codes each kind in (§3.1.1.3.2.1.1).
let FSE_PREDEFINED = 0;
let FSE_RLE = 1;
let FSE_COMPRESSED = 2;
let FSE_REPEAT = 3;

// Chooses the table of kind k for the block's codes, of these counts, the
// last sequence's being `first`: the predefined one, the last block's again,
// an RLE table where there's one code, or one built from the counts,
// whichever fse_cost says takes the fewest bits, its description included.
// Builds it in the kind's free slot unless it's repeated, writes its
// description to desc, and returns its mode.
fn plan_table(e: ZstdEncoder&, k: i64, count: const i64[:], first: i64, desc: Bits&) -> i64 {
    let pre .= ZSTD_PREDEF[k];
    var mode = FSE_PREDEFINED;
    var best = fse_cost(pre.norm[..pre.nsym], pre.log, count, first);
    // The predefined table codes offsets below 2^29, past any window here.
    assert(best >= 0);
    if e.tables {
        let t .= e.fse[2 * k + e.cur[k]];
        let c = fse_cost(t.norm[..t.nsym], t.log, count, first);
        if c >= 0 && c < best {
            mode = FSE_REPEAT;
            best = c;
        }
    }
    var top = 0;
    var kinds = 0;
    var total = 0;
    for c, s in count {
        if c > 0 {
            top = s;
            kinds++;
            total += c;
        }
    }
    var norm: i64[FSE_SYMS] = [0; FSE_SYMS];
    var log = 0;
    if kinds == 1 {
        // One byte, the code.
        if 8 << 8 < best {
            mode = FSE_RLE;
            norm[top] = 1;
        }
    } else {
        // libzstd's FSE_optimalTableLog: fewer states for fewer codes, but
        // enough for each code to take one.
        let least = min(log2(total) + 1, log2(top) + 2);
        log = max(max(min(SEQ_LOG[k], log2(total - 1) - 2), least), 5);
        // Large blocks, as libzstd's ZSTD_useLowProbCount.
        fse_normalize(count[..top + 1], total, log, norm[..top + 1], total >= 2048);
        var b = Bits { .. };
        put_fse_header(b, norm[..top + 1], log);
        let c = (b.o << 11) + fse_cost(norm[..top + 1], log, count, first);
        if c < best {
            mode = FSE_COMPRESSED;
            desc = b;
        }
    }
    guard mode != FSE_REPEAT else { return mode; }
    let t .= e.fse[2 * k + 1 - e.cur[k]];
    if mode == FSE_PREDEFINED {
        t = pre;
    } else {
        fse_build(t, norm[..top + 1], log);
        if mode == FSE_RLE { bits_put(desc, top, 8); }
    }
    return mode;
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
let ZSTD_PREDEF = [fse_table(LL_NORM, 6), fse_table(OF_NORM, 5), fse_table(ML_NORM, 6)];

// Codes symbol s before state v of t: the bits it writes, v's low ones, and
// the state it moves to.
fn fse_step(t: Fse&, v: i64, s: i64) -> i64, i64 {
    let n = (v + t.dnb[s]) >> 16;
    return n, t.next[(v >> n) + t.dfs[s]];
}

// The bits put_seqs writes with tables tl, to, and tm, the closing 1 bit
// aside.
fn seq_bits(e: ZstdEncoder&, tl: Fse&, to: Fse&, tm: Fse&) -> i64 {
    var i = e.nseq - 1;
    var sl = fse_first(tl, e.llc[i]);
    var so = fse_first(to, e.ofc[i]);
    var sm = fse_first(tm, e.mlc[i]);
    var n = tl.log + to.log + tm.log;
    loop {
        n += LL_BITS[e.llc[i]] + ML_BITS[e.mlc[i]] + e.ofc[i];
        guard i > 0 else { break; }
        i--;
        let no, vo = fse_step(to, so, e.ofc[i]);
        let nm, vm = fse_step(tm, sm, e.mlc[i]);
        let nl, vl = fse_step(tl, sl, e.llc[i]);
        n += no + nm + nl;
        so = vo;
        sm = vm;
        sl = vl;
    }
    return n;
}

// Sequence i's extra bits: its literal length's, match length's, and
// offset's, and how many of each.
fn seq_extra(e: ZstdEncoder&, i: i64) -> u64, i64, u64, i64, u64, i64 {
    let s = e.seqs[i];
    let lc = e.llc[i] as i64;
    let mc = e.mlc[i] as i64;
    let oc = e.ofc[i] as i64;
    return (s & 0xFFFFF) - LL_BASE[lc] as! u64, LL_BITS[lc],
           ((s >> 20) & 0xFFFFF) - ML_BASE[mc] as! u64, ML_BITS[mc],
           (s >> 40) - (1 << oc) as! u64, oc;
}

// The sequences' bitstream (§3.1.1.3.2.1.2), which a decoder reads from its
// end: so it's written from the last sequence to the first. Each sequence
// writes the states its decoder moves on by, offset's first, then its extra
// bits, the literal length's first, and the first sequence's states close it,
// the literal length's last, then a 1 bit. A sequence's bits are written to
// a buffer in two parts, the states and the literal length's extra bits, then
// the rest, each under 57 bits, and the whole bytes kept.
fn put_seqs(e: ZstdEncoder&, out: u8[>..]&, tl: Fse&, to: Fse&, tm: Fse&) {
    // A sequence writes up to 12 bytes before the buffer is checked.
    var buf: u8[STAGE + 16] = [0; STAGE + 16];
    var o = 0;
    var i = e.nseq - 1;
    var sl = fse_first(tl, e.llc[i]);
    var so = fse_first(to, e.ofc[i]);
    var sm = fse_first(tm, e.mlc[i]);
    let lx, ln, mx, mn, ox, on = seq_extra(e, i);
    var bits = lx | mx << ln | ox << (ln + mn);
    var nbits = ln + mn + on;
    put_le64(buf[o..o + 8], bits);
    o += nbits >> 3;
    bits >>= nbits & ~7;
    nbits &= 7;
    while i > 0 {
        i--;
        let no, vo = fse_step(to, so, e.ofc[i]);
        bits |= ((so & ((1 << no) - 1)) as! u64) << nbits;
        nbits += no;
        so = vo;
        let nm, vm = fse_step(tm, sm, e.mlc[i]);
        bits |= ((sm & ((1 << nm) - 1)) as! u64) << nbits;
        nbits += nm;
        sm = vm;
        let nl, vl = fse_step(tl, sl, e.llc[i]);
        bits |= ((sl & ((1 << nl) - 1)) as! u64) << nbits;
        nbits += nl;
        sl = vl;
        let lx1, ln1, mx1, mn1, ox1, on1 = seq_extra(e, i);
        bits |= lx1 << nbits;
        nbits += ln1;
        put_le64(buf[o..o + 8], bits);
        o += nbits >> 3;
        bits >>= nbits & ~7;
        nbits &= 7;
        bits |= mx1 << nbits;
        nbits += mn1;
        bits |= ox1 << nbits;
        nbits += on1;
        put_le64(buf[o..o + 8], bits);
        o += nbits >> 3;
        bits >>= nbits & ~7;
        nbits &= 7;
        if o >= STAGE {
            out.append(buf[..o]);
            o = 0;
        }
    }
    bits |= ((sm & ((1 << tm.log) - 1)) as! u64) << nbits;
    nbits += tm.log;
    bits |= ((so & ((1 << to.log) - 1)) as! u64) << nbits;
    nbits += to.log;
    bits |= ((sl & ((1 << tl.log) - 1)) as! u64) << nbits;
    nbits += tl.log;
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
