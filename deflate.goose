// The DEFLATE stream at levels 1 and up: LZ77 with one hash probe a position at
// level 1 and hash chains above it, and each block coded with a dynamic Huffman code built from its symbols, with
// the fixed code (RFC 1951 §3.2.6), or stored, whichever is shortest.
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
let HASH_BITS = 15;
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
// lazy2). Level 1 probes one candidate and keeps no chains.
let DEPTH = [0, 1, 6, 12, 16, 16, 35, 100, 300, 600];
let NICE = [0, MAX_MATCH, 10, 14, 30, 30, 65, 130, MAX_MATCH, MAX_MATCH];
let LAZY = [0, 0, 0, 0, 0, 1, 1, 1, 2, 2];

// The state of a stream at levels 1 and up, inside Encoder.
struct Lz {
    level: i64,
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
    // From level 2, the hash chains: for each stream offset modulo WSIZE, the
    // distance back to the one before it in its bucket, or NO_PREV for none
    // in reach. An entry is good until the offset WSIZE later takes its slot, so
    // a search follows it only from less than WSIZE back.
    prev: u16[WSIZE],
    // A lazy level's match found at pos while it looked ahead, or a length
    // of 0.
    ahead_len: i64,
    ahead_dist: i64,
    warm: u32,
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
    if z.level == 1 {
        match_fast(z, out, end);
    } else {
        match_chains(z, out, end);
    }
}

// Level 1: one probe a position, the longest match taken whole.
fn match_fast(z: Lz&, out: u8[>..]&, end: i64) {
    while z.pos < end {
        let p = z.pos;
        var len = 0;
        var dist = 0;
        if p + 4 <= z.fill {
            let v = load32(z.win, p);
            let h = hash4(v);
            let cand = z.head[h];
            let here = z.base + p as! u32;
            z.head[h] = here;
            let d: i64 = here - cand;
            // The 4 bytes hashed, compared at once, turn away most candidates.
            if d >= 1 && d <= WSIZE && d <= p && load32(z.win, p - d) == v {
                len = 4 + match_len(z.win, p - d + 4, p + 4, min(MAX_MATCH, z.fill - p) - 4);
                dist = d;
            }
        }
        if len >= MIN_MATCH {
            add_sym(z, out, ((dist as! u32) << 8) | (len - MIN_MATCH) as! u32, len);
            for i in p + 1..min(p + len, z.fill - 3) {
                z.head[hash4(load32(z.win, i))] = z.base + i as! u32;
            }
        } else {
            add_sym(z, out, z.win[p], 1);
        }
    }
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
            add_sym(z, out, z.win[p], 1);
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
                add_sym(z, out, z.win[p], 1);
                continue;
            }
            if lazy > 1 {
                let len2, dist2 = search(z, p + 2, len, depth >> 2, nice);
                done = 2;
                if better(len2, dist2, len, dist, 6) {
                    z.ahead_len = len2;
                    z.ahead_dist = dist2;
                    add_sym(z, out, z.win[p], 1);
                    add_sym(z, out, z.win[p + 1], 1);
                    continue;
                }
            }
        }
        add_sym(z, out, ((dist as! u32) << 8) | (len - MIN_MATCH) as! u32, len);
        for i in p + 1 + done..min(p + len, z.fill - 3) { insert(z, i); }
    }
}

// Whether a match of len at dist beats one of cur at cur_dist enough to spend
// literals on it: by libdeflate's measure, 4 for each byte longer and 1 for
// each power of two nearer, past the threshold.
fn better(len: i64, dist: i64, cur: i64, cur_dist: i64, threshold: i64) -> bool {
    return len >= cur && 4 * (len - cur) + clz(dist as! u64) - clz(cur_dist as! u64) > threshold;
}

// Inserts position i into its hash chain, and returns the distance to the
// bucket's entry before it.
fn insert(z: Lz&, i: i64) -> i64 {
    let h = hash4(load32(z.win, i));
    let here = z.base + i as! u32;
    let d: i64 = here - z.head[h];
    z.head[h] = here;
    z.prev[(here & (WSIZE - 1)) as i64] =
        (if (d - 1) as! u64 < WSIZE { d } else { NO_PREV }) as! u16;
    return d;
}

// A chain entry for no earlier position in reach: farther than any search
// goes.
let NO_PREV = 65535;

// Inserts p, then returns the longest match at p longer than `floor`, with its
// distance, or a length of 0. It compares at most `depth` candidates, newest
// first, and stops at a match of `nice`.
fn search(z: Lz&, p: i64, floor: i64, depth: i64, nice: i64) -> i64, i64 {
    guard p + 4 <= z.fill else { return 0, 0; }
    var d = insert(z, p);
    if p + 5 <= z.fill { z.warm = z.head[hash4(load32(z.win, p + 1))]; }
    let most = min(MAX_MATCH, z.fill - p);
    let enough = min(nice, most);
    let v = load32(z.win, p);
    var best = floor;
    var best_dist = 0;
    guard best < enough else { return 0, 0; }
    // A distance is in reach from 1 to `reach`, one unsigned compare. A chain
    // that ends steps out of reach: by NO_PREV, or, from WSIZE back, by the
    // step p's own insert left in the slot it shares.
    let reach = min(WSIZE, p) as! u64;
    var left = depth;
    while (d - 1) as! u64 < reach && left > 0 {
        let c = p - d;
        // The byte that would make the match longer than the best, then the 4
        // hashed, turn away most candidates.
        if z.win[c + best] == z.win[p + best] && load32(z.win, c) == v {
            let len = 4 + match_len(z.win, c + 4, p + 4, most - 4);
            if len > best {
                best = len;
                best_dist = d;
                guard best < enough else { break; }
            }
        }
        d += z.prev[((z.base + c as! u32) & (WSIZE - 1)) as i64];
        left--;
    }
    guard best_dist > 0 else { return 0, 0; }
    return best, best_dist;
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

fn hash4(v: u32) -> i64 {
    return (v * 0x9E3779B1) >> (32 - HASH_BITS);
}

fn load32(s: const u8[:], i: i64) -> u32 {
    let c = s[i..i + 4];
    return c[0] | (c[1] as u32) << 8 | (c[2] as u32) << 16 | (c[3] as u32) << 24;
}

fn match_len(win: const u8[:], a: i64, b: i64, most: i64) -> i64 {
    var n = 0;
    while n < most && win[a + n] == win[b + n] { n++; }
    return n;
}

// Writes the open block in whichever of the three forms takes the fewest bits:
// with a dynamic code, with the fixed code, or stored. Ties go to the stored
// block, then to the fixed code, as zlib breaks them. Then starts the next
// block.
fn end_block(z: Lz&, out: u8[>..]&, last: bool) {
    let syms = z.syms[..z.nsym];
    var lfreq: u32[LIT_CODES] = [0; LIT_CODES];
    var dfreq: u32[DIST_CODES] = [0; DIST_CODES];
    // The lengths' and distances' extra bits, which every code spends alike.
    var extra = 0;
    for s in syms {
        if s < 256 {
            lfreq[s]++;
        } else {
            let lc, lbits, lextra = len_code(s & 0xff);
            let dc, dbits, dextra = dist_code(s >> 8);
            lfreq[lc]++;
            dfreq[dc]++;
            extra += lbits + dbits;
        }
    }
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
