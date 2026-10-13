// A zstd block's literals section (RFC 8878 §3.1.1.3.1): the bytes its
// sequences don't match, raw, as one repeated byte, or Huffman coded with a
// code built from the block, whichever is shortest.
namespace compress;

import std;
import .deflate;
import .huffman;
import .zstd_fse;

// The longest Huffman code zstd decodes (§4.2.1).
let ZSTD_HUFF_BITS = 11;

// A block's literals, planned before they're written, since the block header
// holds the block's size. The Huffman streams are planned to the byte.
struct ZstdLits {
    // The Literals_Block_Type: ZSTD_RAW, ZSTD_RLE, or ZSTD_COMPRESSED, whose
    // values the block types share.
    kind: i64 = 0,
    // The literals, the section's bytes, and its header's.
    n: i64 = 0,
    size: i64 = 0,
    lh: i64 = 0,
    rle: u8 = 0,
    // Huffman coded: each byte's code, and the bytes after the header.
    len: u8[256],
    code: u16[256],
    csize: i64 = 0,
    // The code's description, its weights direct or FSE coded (§4.2.1.1).
    ndesc: i64 = 0,
    desc: u8[128],
    // The literals go in one stream below 256 of them, else four, each a
    // quarter of them but the last. Each stream's bytes.
    nstreams: i64 = 1,
    bytes: i64[4],
}

// Plans the block's literals, `lits`, into l.
fn plan_literals(lits: const u8[:], l: ZstdLits&) {
    let n = lits.len;
    l.n = n;
    l.kind = ZSTD_RAW;
    l.lh = if n < 32 { 1 } else if n < 4096 { 2 } else { 3 };
    l.size = l.lh + n;
    guard n > 1 else { return; }
    l.nstreams = if n < 256 { 1 } else { 4 };
    let seg = if l.nstreams == 1 { n } else { (n + 3) / 4 };

    // Each stream's byte counts, at hist[256 * k]. Bytes are counted 4 at a
    // time in 4 tables, so a run of one byte doesn't make each count wait for
    // the one before.
    var hist: u32[1024] = [0; 1024];
    var freq: u32[256] = [0; 256];
    var c0: u32[256] = [0; 256];
    var c1: u32[256] = [0; 256];
    var c2: u32[256] = [0; 256];
    var c3: u32[256] = [0; 256];
    for k in l.nstreams {
        let run = lits[k * seg..min((k + 1) * seg, n)];
        var q = 0;
        while q + 4 <= run.len {
            c0[run[q]]++;
            c1[run[q + 1]]++;
            c2[run[q + 2]]++;
            c3[run[q + 3]]++;
            q += 4;
        }
        for b in run[q..] { c0[b]++; }
        for x, b in c0 {
            let c = x + c1[b] + c2[b] + c3[b];
            hist[(k << 8) + b] = c;
            freq[b] += c;
        }
        for &x in c0 { x = 0; }
        for &x in c1 { x = 0; }
        for &x in c2 { x = 0; }
        for &x in c3 { x = 0; }
    }

    var kinds = 0;
    var top = 0;
    var most: u32 = 0;
    for f, s in freq {
        if f > 0 {
            kinds++;
            top = s;
            most = max(most, f);
        }
    }
    if kinds == 1 {
        l.kind = ZSTD_RLE;
        l.rle = top as! u8;
        l.size = l.lh + 1;
        return;
    }
    // libzstd's guess that literals this even won't code smaller
    // (HUF_compress_internal), which saves building the code.
    guard most > (n >> 7) + 4 else { return; }

    var h = Huff { .. };
    huff_lengths(freq, h, ZSTD_HUFF_BITS);
    let syms = top + 1;
    var maxbits = 0;
    var count: i64[16] = [0; 16];
    for s in syms {
        l.len[s] = h.len[s];
        count[h.len[s]]++;
        maxbits = max(maxbits, h.len[s]);
    }
    // zstd's canonical code: codes of one length are consecutive in symbol
    // order, and longer codes come first, from 0.
    var next: i64[16] = [0; 16];
    var b = maxbits;
    while b > 1 {
        next[b - 1] = (next[b] + count[b]) >> 1;
        b--;
    }
    for s in syms {
        let n = l.len[s];
        l.code[s] = next[n] as! u16;
        next[n]++;
    }
    guard plan_huff_desc(l, top, maxbits) else { return; }

    var csize = l.ndesc + (if l.nstreams == 4 { 6 } else { 0 });
    for i in l.nstreams {
        var nb = 0;
        for f, s in hist[(i << 8)..(i << 8) + syms] { nb += f * l.len[s] as i64; }
        // The closing 1 bit, then the byte's padding.
        l.bytes[i] = (nb + 8) >> 3;
        csize += l.bytes[i];
    }
    let big = max(n, csize);
    let lh = if l.nstreams == 1 || big < 1024 { 3 } else if big < 16384 { 4 } else { 5 };
    if lh + csize < l.size {
        l.kind = ZSTD_COMPRESSED;
        l.lh = lh;
        l.csize = csize;
        l.size = lh + csize;
    }
}

// Describes the code in l.len as weights (§4.2.1.1), where a length of b bits
// of a code of at most maxbits is weight maxbits + 1 - b. The last symbol's
// weight, top's, is left for the decoder to work out. The weights are sent 4
// bits each for up to 128 of them, or FSE coded where that's shorter; false
// where neither fits.
fn plan_huff_desc(l: ZstdLits&, top: i64, maxbits: i64) -> bool {
    var w: u8[255] = [0; 255];
    for s in top {
        if l.len[s] > 0 { w[s] = (maxbits + 1 - l.len[s]) as! u8; }
    }
    let ws = w[..top];
    l.ndesc = if top <= 128 { 1 + (top + 1) / 2 } else { 0 };
    var b = Bits { .. };
    let fse = put_weights_fse(ws, b) && b.o < 128 && (l.ndesc == 0 || 1 + b.o < l.ndesc);
    if fse {
        l.desc[0] = b.o as! u8;
        copy_into(l.desc[1..1 + b.o], b.buf[..b.o]);
        l.ndesc = 1 + b.o;
    }
    guard l.ndesc > 0 else { return false; }
    if !fse {
        l.desc[0] = (127 + top) as! u8;
        for i in (top + 1) / 2 {
            let lo = if 2 * i + 1 < top { ws[2 * i + 1] } else { 0 };
            l.desc[1 + i] = ws[2 * i] << 4 | lo;
        }
    }
    return true;
}

// FSE codes the weights into b: a distribution of 2^5, the accuracy libzstd's
// FSE_optimalTableLog gives any count of weights, then a bitstream two states
// share, the even weights' and the odd ones', read from its end. False where
// FSE can't code them: with fewer than two weights, or one value.
fn put_weights_fse(w: const u8[:], b: Bits&) -> bool {
    let log = 5;
    let n = w.len;
    guard n >= 2 else { return false; }
    var count: i64[12] = [0; 12];
    for x in w { count[x]++; }
    var kinds = 0;
    for c in count { if c > 0 { kinds++; } }
    guard kinds >= 2 else { return false; }
    var norm: i64[12] = [0; 12];
    fse_normalize(count, n, log, norm);
    var syms = 12;
    while norm[syms - 1] == 0 { syms--; }
    put_fse_header(b, norm[..syms], log);
    var f = Fse { .. };
    fse_build(f, norm[..syms], log);
    // A decoder knows it has every weight when moving on from the state the
    // second to last leaves it in reads past the stream, so that state must
    // read a bit. The one that codes it before a decoder's last state reads
    // the most.
    let size = 1 << log;
    var st: i64[2] = [0; 2];
    st[(n - 1) & 1] = fse_first(f, w[n - 1]);
    let last = 2 * size - 1;
    let w2 = w[n - 2] as i64;
    st[(n - 2) & 1] = f.next[(last >> ((last + f.dnb[w2]) >> 16)) + f.dfs[w2]];
    var i = n - 3;
    while i >= 0 {
        let c = i & 1;
        let s = w[i] as i64;
        let v = st[c];
        let nb = (v + f.dnb[s]) >> 16;
        bits_put(b, v & ((1 << nb) - 1), nb);
        st[c] = f.next[(v >> nb) + f.dfs[s]];
        i--;
    }
    bits_put(b, st[1] - size, log);
    bits_put(b, st[0] - size, log);
    bits_put(b, 1, 1);
    bits_end(b);
    return true;
}

// Writes the literals l planned.
fn put_literals(out: u8[>..]&, lits: const u8[:], l: ZstdLits&) {
    if l.kind == ZSTD_COMPRESSED {
        put_huff_literals(out, lits, l);
        return;
    }
    let n = l.n;
    if l.lh == 1 {
        out.push((n << 3 | l.kind) as! u8);
    } else if l.lh == 2 {
        let h = n << 4 | 1 << 2 | l.kind;
        out.append([h as! u8, (h >> 8) as! u8]);
    } else {
        put_le24(out, n << 4 | 3 << 2 | l.kind);
    }
    if l.kind == ZSTD_RLE {
        out.push(l.rle);
        return;
    }
    out.append(lits);
}

// The header, whose sizes take 10, 14, or 18 bits each as it's 3, 4, or 5
// bytes; the code's description; with four streams, the sizes of the first
// three; then the streams.
fn put_huff_literals(out: u8[>..]&, lits: const u8[:], l: ZstdLits&) {
    let bits = if l.lh == 3 { 10 } else if l.lh == 4 { 14 } else { 18 };
    let format = if l.lh > 3 { l.lh - 2 } else if l.nstreams == 4 { 1 } else { 0 };
    let h = ZSTD_COMPRESSED | format << 2 | l.n << 4 | l.csize << (4 + bits);
    for i in l.lh { out.push((h >> (8 * i)) as! u8); }
    out.append(l.desc[..l.ndesc]);
    if l.nstreams == 4 {
        for i in 3 { put_le16(out, l.bytes[i] as! u16); }
    }
    let seg = if l.nstreams == 1 { l.n } else { (l.n + 3) / 4 };
    for i in l.nstreams {
        put_huff_stream(out, lits[i * seg..min((i + 1) * seg, l.n)], l, i);
    }
}

// Stream i, of `run`, which a decoder reads from its end: so it's written
// from the last literal to the first, then a 1 bit.
fn put_huff_stream(out: u8[>..]&, run: const u8[:], l: ZstdLits&, i: i64) {
    var buf: u8[STAGE + 16] = [0; STAGE + 16];
    var o = 0;
    var sent = 0;
    var bits: u64 = 0;
    var nbits = 0;
    // Four codes take at most 44 bits, so with the fewer than 8 left over
    // they fit a u64, whose shifts stop short of 64.
    var q = run.len;
    while q > 0 {
        put_le64(buf[o..o + 8], bits);
        o += nbits >> 3;
        bits >>= nbits & ~7;
        nbits &= 7;
        if o >= STAGE {
            out.append(buf[..o]);
            sent += o;
            o = 0;
        }
        for t in min(q, 4) {
            q--;
            let b = run[q];
            bits |= (l.code[b] as u64) << nbits;
            nbits += l.len[b];
        }
    }
    put_le64(buf[o..o + 8], bits);
    o += nbits >> 3;
    bits >>= nbits & ~7;
    nbits &= 7;
    bits |= (1 as u64) << nbits;
    nbits++;
    put_le64(buf[o..o + 8], bits);
    o += (nbits + 7) >> 3;
    out.append(buf[..o]);
    assert(sent + o == l.bytes[i]);
}
