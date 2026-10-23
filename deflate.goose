// The DEFLATE stream at levels 1 and up: LZ77 with 2-entry hash buckets at level
// 1 and hash chains above it, and each block coded with a dynamic Huffman code
// built from its symbols, with the fixed code (RFC 1951 §3.2.6), or stored,
// whichever is shortest.
namespace compress;

import std;
import .huffman;

// Matches reach back at most WSIZE bytes and run at most MAX_MATCH.
let WSIZE = 32768;
let MIN_MATCH = 3;
let MAX_MATCH = 258;
// A position is matched only once this many bytes follow it, or at a flush, so
// a match and the hashes inserted inside it never depend on how much input a
// write happened to bring: the 2 positions a lazy level looks ahead, MAX_MATCH,
// and 4 bytes hashed at a match's last position.
let LOOKAHEAD = 2 + MAX_MATCH + 4;
// 32 KB of history, 32 KB of input, and the lookahead. When the window fills,
// it slides down by WSIZE, which keeps a full WSIZE behind the next position.
let WIN_SIZE = 2 * WSIZE + LOOKAHEAD;
let HASH_BITS = 16;
let HASH_SIZE = 1 << HASH_BITS;
// A block ends when it holds this many symbols, as zlib's at its default
// memory level.
let SYM_MAX = 16384;
// The literal/length symbols a block can use, the end of block included, and
// the distance symbols.
let LIT_CODES = 286;
let DIST_CODES = 30;
let END_BLOCK = 256;

// How each level from 1 matches, after libdeflate's levels: how many
// candidates a search compares at most, the length that ends a search, and how
// many positions after a match it looks for a better one (0 greedy, 1 lazy, 2
// lazy2). Level 1 keeps no chains (match_fast).
let DEPTH = [0, 1, 6, 12, 16, 16, 35, 100, 300, 600];
let NICE = [0, MAX_MATCH, 10, 14, 30, 30, 65, 130, MAX_MATCH, MAX_MATCH];
let LAZY = [0, 0, 0, 0, 0, 1, 1, 1, 2, 2];

// The state of a stream at levels 1 and up, inside Encoder.
struct Lz {
    level: i64,
    // Bits not yet appended to the output, the oldest in the low bits.
    bits: u64,
    nbits: i64,
    // The stream offset of win[0], modulo 2^32. Offsets start at WSIZE, so an
    // empty table entry is never in reach (lz_reset).
    base: u32 = WSIZE,
    // win[..fill] holds input; pos is the next position to match, and the
    // current block covers win[block_start..pos].
    fill: i64,
    pos: i64,
    block_start: i64,
    // Each hash bucket's latest stream offset, or at level 1 the 2 latest. An
    // entry only suggests where a match may start: it may be stale, or from
    // 2^32 bytes back, so every candidate is compared byte by byte.
    head: u32[HASH_SIZE],
    // From level 2, the hash chains: for each stream offset modulo WSIZE, the
    // low 16 bits of the one before it in its bucket, or of the offset WSIZE
    // back for none in reach. A search reads links only from offsets up to
    // WSIZE back, whose slots no later offset has taken, so the link lies
    // within 2 * WSIZE and its 16 bits place it.
    prev: u16[WSIZE],
    // A lazy level's match found at pos while it looked ahead, or a length
    // of 0.
    ahead_len: i64,
    ahead_dist: i64,
    warm: u32,
    // The hash a search computed for the position after its own, and that
    // position's stream offset, or 0 for none: the next search takes it.
    next_h: i64,
    next_off: u32,
    // The block's symbols: a literal byte as itself, a match as its distance
    // above bit 8 and its length minus 3 below.
    nsym: i64,
    syms: u32[SYM_MAX],
    // The block's symbol counts, kept as symbols are added, and the bits its
    // lengths' and distances' extra bits take, which every code spends alike.
    lfreq: u32[LIT_CODES],
    dfreq: u32[DIST_CODES],
    extra: i64,
    win: u8[WIN_SIZE],
}

// Starts z over as a new stream at level, which codes as it would in
// `Lz { level: level, .. }` for its first 2^31 bytes. The tables keep their
// entries: the new stream's offsets start a window past the last one's end, so
// no entry from before is in reach, as a new Lz's empty ones aren't. They're
// cleared once offsets would pass 2^31, before old ones could wrap round into
// reach. win and syms keep their bytes, since nothing reads them past fill and
// nsym.
fn lz_reset(z: Lz&, level: i64) {
    z.level = level;
    z.bits = 0;
    z.nbits = 0;
    z.base += (z.fill + WSIZE) as! u32;
    if z.base > 1 << 31 {
        for &x in z.head { x = 0; }
        for &x in z.prev { x = 0; }
        z.base = WSIZE;
    }
    z.fill = 0;
    z.pos = 0;
    z.block_start = 0;
    z.ahead_len = 0;
    z.ahead_dist = 0;
    z.warm = 0;
    z.next_h = 0;
    z.next_off = 0;
    z.nsym = 0;
    for &x in z.lfreq { x = 0; }
    for &x in z.dfreq { x = 0; }
    z.extra = 0;
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
    if z.level == 1 {
        match_fast(z, out, end);
    } else {
        match_chains(z, out, end);
    }
}

// Level 1, after libdeflate's `ht_matchfinder`: head holds 2^15 buckets of the
// 2 latest offsets, newest first. The newer candidate is extended whole; the
// older is tried too unless that gave FAST_NICE, and the longer match is taken.
fn match_fast(z: Lz&, out: u8[>..]&, end: i64) {
    // The position, fill, and base in locals, which the loop keeps in
    // registers; z.pos is stored before anything that may end the block.
    let fill = z.fill;
    let base = z.base;
    var p = z.pos;
    while p < end {
        var len = 0;
        var dist = 0;
        if p + 4 <= fill {
            let v = load32(z.win, p);
            let b = bucket(v);
            let here = base + p as! u32;
            let c0 = z.head[b];
            let c1 = z.head[b + 1];
            z.head[b] = here;
            z.head[b + 1] = c0;
            let most = min(MAX_MATCH, fill - p);
            let reach = min(WSIZE, p) as! u64;
            let d0: i64 = here - c0;
            // The older candidate is out of reach whenever the newer one is.
            if (d0 - 1) as! u64 < reach {
                // The 4 bytes hashed, compared at once, turn away most candidates.
                if load32(z.win, p - d0) == v {
                    len = 4 + match_len(z.win, p - d0 + 4, p + 4, most - 4);
                    dist = d0;
                }
                let d1: i64 = here - c1;
                if len < FAST_NICE && (d1 - 1) as! u64 < reach && load32(z.win, p - d1) == v &&
                   (len == 0 || load32(z.win, p - d1 + len - 3) == load32(z.win, p + len - 3)) {
                    let len1 = 4 + match_len(z.win, p - d1 + 4, p + 4, most - 4);
                    if len1 > len {
                        len = len1;
                        dist = d1;
                    }
                }
            }
        }
        if len >= MIN_MATCH {
            for i in p + 1..min(p + len, fill - 3) {
                let bi = bucket(load32(z.win, i));
                z.head[bi + 1] = z.head[bi];
                z.head[bi] = base + i as! u32;
            }
            z.pos = p;
            add_match(z, out, dist, len);
            p += len;
        } else {
            // add_lit, with the position in its local.
            let c = z.win[p];
            z.syms[z.nsym] = c;
            z.lfreq[c]++;
            z.nsym++;
            p++;
            if z.nsym == SYM_MAX {
                z.pos = p;
                end_block(z, out, false);
            }
        }
    }
    z.pos = p;
}

// Level 1's match length that leaves a bucket's older candidate untried, as
// libdeflate's.
let FAST_NICE = 32;

// The first of the 2 entries of a level 1 bucket in head.
fn bucket(v: u32) -> i64 {
    return ((v * 0x9E3779B1) >> (32 - HASH_BITS + 1)) * 2;
}

// Levels 2 to 9: searches along the hash chains, and at a lazy level takes a
// literal where the match one or two positions on is better. Every position
// is inserted into the chains once, as it is searched or skipped inside a
// match.
fn match_chains(z: Lz&, out: u8[>..]&, end: i64) {
    let depth = DEPTH[z.level];
    let nice = NICE[z.level];
    let lazy = LAZY[z.level];
    while z.pos < end {
        let p = z.pos;
        var len = z.ahead_len;
        var dist = z.ahead_dist;
        z.ahead_len = 0;
        if len == 0 {
            let len0, dist0 = search(z, p, MIN_MATCH, depth, nice);
            len = len0;
            dist = dist0;
        }
        if len < 4 {
            add_lit(z, out, z.win[p]);
            continue;
        }
        // The positions after p already inserted.
        var done = 0;
        if lazy > 0 && len < nice {
            let len1, dist1 = search(z, p + 1, len, depth >> 1, nice);
            done = 1;
            if better(len1, dist1, len, dist, 2) {
                z.ahead_len = len1;
                z.ahead_dist = dist1;
                add_lit(z, out, z.win[p]);
                continue;
            }
            if lazy > 1 {
                let len2, dist2 = search(z, p + 2, len, depth >> 2, nice);
                done = 2;
                if better(len2, dist2, len, dist, 6) {
                    z.ahead_len = len2;
                    z.ahead_dist = dist2;
                    add_lit(z, out, z.win[p]);
                    add_lit(z, out, z.win[p + 1]);
                    continue;
                }
            }
        }
        add_match(z, out, dist, len);
        for i in p + 1 + done..min(p + len, z.fill - 3) { insert(z, i); }
    }
}

// Whether a match of len at dist beats one of cur at cur_dist enough to spend
// literals on it: by libdeflate's measure, 4 for each byte longer and 1 for
// each power of two nearer, past the threshold.
fn better(len: i64, dist: i64, cur: i64, cur_dist: i64, threshold: i64) -> bool {
    return len >= cur && 4 * (len - cur) + log2(cur_dist) - log2(dist) > threshold;
}

// The base-2 logarithm of a distance, rounded down, from a table: std's clz is
// a loop on x86-64 (see LEN_TAB).
fn log2(d: i64) -> i64 {
    return if d >= 256 { 8 + LOG2[(d >> 8) & 255] } else { LOG2[d & 255] };
}

let LOG2 = log2_tab();

fn log2_tab() -> i64[256] {
    var t: i64[256] = [0; 256];
    for i in 2..256 { t[i] = t[i >> 1] + 1; }
    return t;
}

// Inserts position i into its hash chain.
fn insert(z: Lz&, i: i64) {
    let here = z.base + i as! u32;
    let h = hash4(load32(z.win, i));
    link(z, here, z.head[h]);
    z.head[h] = here;
}

// Sets the chain link of stream offset here to old, the entry before it in
// its bucket.
fn link(z: Lz&, here: u32, old: u32) {
    z.prev[(here & (WSIZE - 1)) as i64] =
        (if here - old - 1 < WSIZE { old } else { here - WSIZE }) as! u16;
}

// Inserts p, then returns the longest match at p longer than `floor`, with its
// distance, or a length of 0. It compares at most `depth` candidates, newest
// first, and stops at a match of `nice`. As libdeflate's hc_matchfinder, it
// is inlined at each call.
inline fn search(z: Lz&, p: i64, floor: i64, depth: i64, nice: i64) -> i64, i64 {
    guard p + 4 <= z.fill else { return 0, 0; }
    let here = z.base + p as! u32;
    let h = if here == z.next_off { z.next_h } else { hash4(load32(z.win, p)) };
    let old = z.head[h];
    z.head[h] = here;
    if p + 5 <= z.fill {
        let h1 = hash4(load32(z.win, p + 1));
        z.warm = z.head[h1];
        z.next_h = h1;
        z.next_off = here + 1;
    }
    let len, dist = walk(z, p, here, old, floor, depth, nice);
    // Until now p's slot held the link of the offset WSIZE back, a candidate.
    link(z, here, old);
    return len, dist;
}

// search's walk along p's chain, from old, the entry before p in its bucket.
// A chain step is a load and a mask: the offset read is the next link's
// index.
inline fn walk(z: Lz&, p: i64, here: u32, old: u32, floor: i64, depth: i64,
               nice: i64) -> i64, i64 {
    let most = min(MAX_MATCH, z.fill - p);
    let enough = min(nice, most);
    let v = load32(z.win, p);
    var best = floor;
    var best_dist = 0;
    guard best < enough else { return 0, 0; }
    // A distance is in reach from 1 to `reach`, one unsigned compare.
    let reach = min(WSIZE, p) as! u64;
    var node = old;
    var d: i64 = here - old;
    var left = depth;
    // Until one matches, a candidate needs only the 4 bytes hashed.
    if best < 4 {
        while (d - 1) as! u64 < reach && left > 0 && load32(z.win, p - d) != v {
            node = z.prev[(node & (WSIZE - 1)) as i64];
            d = (here - node) & 0xFFFF;
            left--;
        }
        guard (d - 1) as! u64 < reach && left > 0 else { return 0, 0; }
        best = 4 + match_len(z.win, p - d + 4, p + 4, most - 4);
        best_dist = d;
        guard best < enough else { return best, best_dist; }
        node = z.prev[(node & (WSIZE - 1)) as i64];
        d = (here - node) & 0xFFFF;
        left--;
    }
    while (d - 1) as! u64 < reach && left > 0 {
        let c = p - d;
        // The 4 bytes that end where a longer match would, then the 4 hashed,
        // turn away most candidates.
        if load32(z.win, c + best - 3) == load32(z.win, p + best - 3) &&
           load32(z.win, c) == v {
            let len = 4 + match_len(z.win, c + 4, p + 4, most - 4);
            if len > best {
                best = len;
                best_dist = d;
                guard best < enough else { break; }
            }
        }
        node = z.prev[(node & (WSIZE - 1)) as i64];
        d = (here - node) & 0xFFFF;
        left--;
    }
    guard best_dist > 0 else { return 0, 0; }
    return best, best_dist;
}

fn add_lit(z: Lz&, out: u8[>..]&, b: u8) {
    z.syms[z.nsym] = b;
    z.lfreq[b]++;
    z.nsym++;
    z.pos++;
    if z.nsym == SYM_MAX { end_block(z, out, false); }
}

fn add_match(z: Lz&, out: u8[>..]&, dist: i64, len: i64) {
    let x = (len - MIN_MATCH) as! u32;
    let d = dist as! u32;
    z.syms[z.nsym] = d << 8 | x;
    let lc, lbits, lextra = len_code(x);
    let dc, dbits, dextra = dist_code(d);
    z.lfreq[lc]++;
    z.dfreq[dc]++;
    z.extra += lbits + dbits;
    z.nsym++;
    z.pos += len;
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

fn hash4(v: u32) -> i64 {
    return (v * 0x9E3779B1) >> (32 - HASH_BITS);
}

fn load32(s: const u8[:], i: i64) -> u32 {
    let c = s[i..i + 4];
    return c[0] | (c[1] as u32) << 8 | (c[2] as u32) << 16 | (c[3] as u32) << 24;
}

// Slicing both runs first checks their bounds once, not at each byte. It
// compares 8 bytes at a time, and finds the first that differs by a de Bruijn
// multiply: std's ctz is a loop on x86-64. Inlined: as a call it costs the
// matchers more than the 8-byte compare gains.
inline fn match_len(win: const u8[:], a: i64, b: i64, most: i64) -> i64 {
    let x = win[a..a + most];
    let y = win[b..b + most];
    assert(x.len == y.len);
    // Many matches end at the first byte, on `x-ray` most: one compare before
    // the 8-byte loop saves them the multiply.
    guard x.len > 0 && x[0] == y[0] else { return 0; }
    var n = 1;
    while n + 8 <= x.len {
        // Two 4-byte loads, not load64's one 8-byte load and not std's ctz below:
        // either costs the chain search 3 to 6 percent on `x-ray` at levels 6
        // and 9, where zstd_match_len gains from both.
        let d = (load32(x, n) | (load32(x, n + 4) as u64) << 32) ^
                (load32(y, n) | (load32(y, n + 4) as u64) << 32);
        // `% 64` lets the compiler drop the table's bounds check.
        if d != 0 { return n + (CTZ64[(((d & (0 - d)) * 0x03F79D71B4CB0A89) >> 58) % 64] >> 3); }
        n += 8;
    }
    for i in n..x.len {
        if x[i] != y[i] { return i; }
    }
    return x.len;
}

// The index of a u64's lowest set bit, by the top 6 bits of that bit times the
// de Bruijn constant in match_len.
let CTZ64 = ctz64_tab();

fn ctz64_tab() -> i64[64] {
    var t: i64[64] = [0; 64];
    for k in 64 { t[((1 as u64 << k) * 0x03F79D71B4CB0A89) >> 58] = k; }
    return t;
}

// Writes the open block in whichever of the three forms takes the fewest bits:
// with a dynamic code, with the fixed code, or stored. Ties go to the stored
// block, then to the fixed code, as zlib breaks them. Then starts the next
// block.
fn end_block(z: Lz&, out: u8[>..]&, last: bool) {
    let syms = z.syms[..z.nsym];
    let lfreq .= z.lfreq;
    let dfreq .= z.dfreq;
    let extra = z.extra;
    lfreq[END_BLOCK] = 1;

    var lit = Huff { .. };
    var dist = Huff { .. };
    huff_build(lfreq, lit, 15);
    huff_build(dfreq, dist, 15);
    var hd = Header { .. };
    let dynamic = 3 + plan_header(lit, dist, hd) + code_bits(lfreq, lit) +
                  code_bits(dfreq, dist) + extra;
    let fixed = 3 + code_bits(lfreq, FIXED_LIT) + code_bits(dfreq, FIXED_DIST) + extra;

    let data = z.win[z.block_start..z.pos];
    let chunks = max(1, (data.len + STORED_MAX - 1) / STORED_MAX);
    // Each stored block's header pads to the byte; only the first starts off
    // one.
    let stored = 8 * data.len + chunks * (3 + 32) + (8 - (z.nbits + 3) % 8) % 8 +
                 (chunks - 1) * 5;
    let final_bit: u32 = if last { 1 } else { 0 };
    if stored <= min(fixed, dynamic) {
        var at = 0;
        for c in chunks {
            let end = min(at + STORED_MAX, data.len);
            put_bits(z, out, if c == chunks - 1 { final_bit } else { 0 }, 3);
            align(z, out);
            stored_body(out, data[at..end]);
            at = end;
        }
    } else if fixed <= dynamic {
        put_bits(z, out, final_bit | 1 << 1, 3);
        put_syms(z, out, syms, FIXED_LIT, FIXED_DIST);
    } else {
        put_bits(z, out, final_bit | 2 << 1, 3);
        put_header(z, out, hd);
        put_syms(z, out, syms, lit, dist);
    }
    z.nsym = 0;
    for &x in z.lfreq { x = 0; }
    for &x in z.dfreq { x = 0; }
    z.extra = 0;
    z.block_start = z.pos;
}

// The bits the symbols of freq take in code h.
fn code_bits(freq: const u32[:], h: Huff&) -> i64 {
    var n = 0;
    for f, s in freq { n += f * h.len[s] as i64; }
    return n;
}

// Codes the symbols and the end of the block. A symbol takes at most 48 bits,
// so with the fewer than 8 bits left over from the one before, it fits a u64:
// each is stored as 8 bytes into a buffer, and the whole bytes kept. The
// buffer is appended to out as it fills, since shrinking out would bar
// callers from holding slices of it.
fn put_syms(z: Lz&, out: u8[>..]&, syms: const u32[:], lit: Huff&, dist: Huff&) {
    var buf: u8[STAGE + 8] = [0; STAGE + 8];
    var o = 0;
    var bits = z.bits;
    var nbits = z.nbits;
    while nbits >= 8 {
        buf[o] = bits as! u8;
        o++;
        bits >>= 8;
        nbits -= 8;
    }
    for s in syms {
        if s < 256 {
            bits |= (lit.code[s] as u64) << nbits;
            nbits += lit.len[s];
        } else {
            let lc, lbits, lextra = len_code(s & 0xff);
            bits |= (lit.code[lc] as u64) << nbits;
            nbits += lit.len[lc];
            bits |= (lextra as u64) << nbits;
            nbits += lbits;
            let dc, dbits, dextra = dist_code(s >> 8);
            bits |= (dist.code[dc] as u64) << nbits;
            nbits += dist.len[dc];
            bits |= (dextra as u64) << nbits;
            nbits += dbits;
        }
        put_le64(buf[o..o + 8], bits);
        o += nbits >> 3;
        bits >>= nbits & ~7;
        nbits &= 7;
        if o >= STAGE {
            out.append(buf[..o]);
            o = 0;
        }
    }
    bits |= (lit.code[END_BLOCK] as u64) << nbits;
    nbits += lit.len[END_BLOCK];
    put_le64(buf[o..o + 8], bits);
    o += nbits >> 3;
    out.append(buf[..o]);
    z.bits = bits >> (nbits & ~7);
    z.nbits = nbits & 7;
}

// put_syms's buffer: it appends once it holds this many bytes.
let STAGE = 4096;

fn put_le64(b: u8[:], v: u64) {
    b[0] = v as! u8;
    b[1] = (v >> 8) as! u8;
    b[2] = (v >> 16) as! u8;
    b[3] = (v >> 24) as! u8;
    b[4] = (v >> 32) as! u8;
    b[5] = (v >> 40) as! u8;
    b[6] = (v >> 48) as! u8;
    b[7] = (v >> 56) as! u8;
}

// The header of a dynamic block (RFC 1951 §3.2.7): how many literal/length and
// distance lengths it sends, then the code-length code, then both codes'
// lengths as one sequence, coded with the code-length code.
struct Header {
    hlit: i64,
    hdist: i64,
    hclen: i64,
    // The code-length symbols, each with its repeat count's extra bits above
    // bit 8: 16 repeats the last length 3-6 times, 17 a zero 3-10 times, and 18
    // a zero 11-138 times.
    n: i64,
    rle: u32[LIT_CODES + DIST_CODES],
    cl: Huff,
}

// The order the code-length code's lengths are sent in, and the extra bits of
// its symbols 16, 17, and 18.
let CL_ORDER = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15];
let CL_EXTRA = [2, 3, 7];

// Plans the header for codes lit and dist into hd, and returns its length in
// bits.
fn plan_header(lit: Huff&, dist: Huff&, hd: Header&) -> i64 {
    // Trailing zero lengths aren't sent, down to the 257 literal/length codes
    // and the 1 distance code each header holds.
    hd.hlit = LIT_CODES;
    while lit.len[hd.hlit - 1] == 0 { hd.hlit--; }
    hd.hdist = DIST_CODES;
    while hd.hdist > 1 && dist.len[hd.hdist - 1] == 0 { hd.hdist--; }
    var lens: u8[LIT_CODES + DIST_CODES] = [0; LIT_CODES + DIST_CODES];
    copy_into(lens[..hd.hlit], lit.len[..hd.hlit]);
    copy_into(lens[hd.hlit..hd.hlit + hd.hdist], dist.len[..hd.hdist]);
    let all = lens[..hd.hlit + hd.hdist];

    // Runs may cross from the literal/length lengths into the distance ones.
    hd.n = 0;
    var i = 0;
    while i < all.len {
        let l = all[i];
        var run = 1;
        while i + run < all.len && all[i + run] == l { run++; }
        i += run;
        if l == 0 {
            while run >= 11 {
                let k = min(run, 138);
                rle_push(hd, 18, k - 11);
                run -= k;
            }
            if run >= 3 {
                rle_push(hd, 17, run - 3);
                run = 0;
            }
        } else {
            rle_push(hd, l, 0);
            run--;
            while run >= 3 {
                let k = min(run, 6);
                rle_push(hd, 16, k - 3);
                run -= k;
            }
        }
        for j in run { rle_push(hd, l, 0); }
    }

    var freq: u32[19] = [0; 19];
    for e in hd.rle[..hd.n] { freq[e & 0xff]++; }
    huff_build(freq, hd.cl, 7);
    hd.hclen = 19;
    while hd.hclen > 4 && hd.cl.len[CL_ORDER[hd.hclen - 1]] == 0 { hd.hclen--; }
    var bits = 5 + 5 + 4 + 3 * hd.hclen + code_bits(freq, hd.cl);
    for x, k in CL_EXTRA { bits += freq[16 + k] * x; }
    return bits;
}

fn rle_push(hd: Header&, sym: u32, extra: i64) {
    hd.rle[hd.n] = sym | (extra as! u32) << 8;
    hd.n++;
}

fn put_header(z: Lz&, out: u8[>..]&, hd: Header&) {
    put_bits(z, out, (hd.hlit - 257) as! u32, 5);
    put_bits(z, out, (hd.hdist - 1) as! u32, 5);
    put_bits(z, out, (hd.hclen - 4) as! u32, 4);
    for i in hd.hclen { put_bits(z, out, hd.cl.len[CL_ORDER[i]], 3); }
    for e in hd.rle[..hd.n] {
        let s = e & 0xff;
        put_bits(z, out, hd.cl.code[s], hd.cl.len[s]);
        if s >= 16 { put_bits(z, out, e >> 8, CL_EXTRA[s - 16]); }
    }
}

// The length symbol (257-285) for a match length minus 3, with its extra bits'
// count and value (RFC 1951 §3.2.5).
fn len_code(x: u32) -> i64, i64, u32 {
    let e = LEN_TAB[x];
    return e & 0x1FF, (e >> 9) & 15, x - (e >> 13);
}

// The distance code (0-29) for a distance, with its extra bits' count and
// value.
fn dist_code(d: u32) -> i64, i64, u32 {
    let x = d - 1;
    let e = if x < 256 { DIST_TAB[x & 255] } else { DIST_TAB[256 + ((x >> 7) & 255)] };
    return e & 31, (e >> 5) & 15, x - (e >> 9);
}

// len_code and dist_code as tables. An entry holds the code, the extra bits' count from bit 9 (bit 5 for a
// distance), and the value the extra bits count from, from bit 13 (bit 9).
// Distances past 256 share a code 128 at a time, so they're looked up by d >> 7.
let LEN_TAB = len_tab();
let DIST_TAB = dist_tab();

fn len_tab() -> u32[256] {
    var t: u32[256] = [0; 256];
    for i in 256 {
        let x = i as! u32;
        var code = 257 + i;
        var extra = 0;
        if x == 255 {
            code = 285;
        } else if x >= 8 {
            let n = 63 - clz(x);
            extra = n - 2;
            code = 257 + 4 * (n - 1) + ((x >> extra) & 3);
        }
        t[i] = code as! u32 | (extra as! u32) << 9 | (x >> extra << extra) << 13;
    }
    return t;
}

fn dist_tab() -> u32[512] {
    var t: u32[512] = [0; 512];
    for i in 512 {
        let x = (if i < 256 { i } else { (i - 256) << 7 }) as! u32;
        var code = x as i64;
        var extra = 0;
        if x >= 4 {
            let n = 63 - clz(x);
            extra = n - 1;
            code = 2 * n + ((x >> extra) & 1);
        }
        if x < WSIZE {
            t[i] = code as! u32 | (extra as! u32) << 5 | (x >> extra << extra) << 9;
        }
    }
    return t;
}

// The fixed codes (RFC 1951 §3.2.6), which are canonical codes of these
// lengths.
let FIXED_LIT = fixed_lit();
let FIXED_DIST = fixed_dist();

fn fixed_lit() -> Huff {
    var h = Huff { .. };
    for s in HUFF_MAX {
        h.len[s] = if s < 144 { 8 } else if s < 256 { 9 } else if s < 280 { 7 } else { 8 };
    }
    huff_codes(h);
    return h;
}

fn fixed_dist() -> Huff {
    var h = Huff { .. };
    for s in 32 { h.len[s] = 5; }
    huff_codes(h);
    return h;
}

// Holds fewer than 32 bits between calls, and appends them 32 at a time; n is
// at most 32.
fn put_bits(z: Lz&, out: u8[>..]&, v: u32, n: i64) {
    z.bits |= (v as u64) << z.nbits;
    z.nbits += n;
    if z.nbits >= 32 {
        let b = z.bits;
        out.append([b as! u8, (b >> 8) as! u8, (b >> 16) as! u8, (b >> 24) as! u8]);
        z.bits >>= 32;
        z.nbits -= 32;
    }
}

// Appends the bits held, padded to the byte with zeros.
fn align(z: Lz&, out: u8[>..]&) {
    while z.nbits > 0 {
        out.push(z.bits as! u8);
        z.bits >>= 8;
        z.nbits -= 8;
    }
    z.bits = 0;
    z.nbits = 0;
}
