// zstd's FSE tables (RFC 8878 §4.1): built from a distribution, distributions
// normalized from counts, and the table description a block sends.
namespace compress;

import std;
import .deflate;

// An FSE table, for coding: for each state, the bits a decoder reads to move
// on from it and the baseline they're added to; for each symbol s and state t
// a decoder moves on to, the state of s it moves from, at enc[s * 64 + t].
struct Fse {
    log: i64,
    nb: u8[64],
    base: u16[64],
    enc: u16[53 * 64],
}

// The same for the 12 weights of a Huffman code, small enough to build for
// each block.
struct FseWeights {
    log: i64,
    nb: u8[64],
    base: u16[64],
    enc: u16[12 * 64],
}

fn fse_table(norm: const i64[:], log: i64) -> Fse {
    var f = Fse { .. };
    fse_build(&f, norm, log);
    return f;
}

// Builds the decoding table of a distribution into f, a reference to an Fse
// or an FseWeights, as §4.1.1 does, and from it the coding one. An untyped
// parameter takes a copy of a struct, so callers pass &f.
fn fse_build(f, norm: const i64[:], log: i64) {
    let size = 1 << log;
    f.log = log;
    var sym: i64[64] = [0; 64];
    // "Less than 1" symbols take a state each from the end, the rest are
    // spread over the others.
    var high = size - 1;
    for p, s in norm {
        if p == -1 {
            sym[high] = s;
            high--;
        }
    }
    let step = (size >> 1) + (size >> 3) + 3;
    var at = 0;
    for p, s in norm {
        for i in max(p, 0) {
            sym[at] = s;
            at = (at + step) & (size - 1);
            while at > high { at = (at + step) & (size - 1); }
        }
    }
    var next: i64[53] = [0; 53];
    for p, s in norm { next[s] = if p == -1 { 1 } else { p }; }
    for u in size {
        let s = sym[u];
        let x = next[s];
        next[s]++;
        let nb = log - LOG2[x];
        let base = (x << nb) - size;
        f.nb[u] = nb as! u8;
        f.base[u] = base as! u16;
        for t in base..base + (1 << nb) { f.enc[s * 64 + t] = u as! u16; }
    }
}

// Sets norm to a distribution of 2^log for the counts, which sum to total:
// each counted symbol gets at least 1, and the rest goes where it saves the
// most bits, a symbol's share of them being about its count over its
// probability.
fn fse_normalize(count: const i64[:], total: i64, log: i64, norm: i64[:]) {
    let size = 1 << log;
    var sum = 0;
    for c, s in count {
        norm[s] = if c == 0 { 0 } else { max(1, c * size / total) };
        sum += norm[s];
    }
    while sum < size {
        var best = -1;
        for c, s in count {
            if c > 0 && (best < 0 || c * norm[best] > count[best] * norm[s]) { best = s; }
        }
        norm[best]++;
        sum++;
    }
    while sum > size {
        var best = -1;
        for c, s in count {
            if norm[s] > 1 &&
               (best < 0 || c * (norm[best] - 1) < count[best] * (norm[s] - 1)) {
                best = s;
            }
        }
        norm[best]--;
        sum--;
    }
}

// A distribution's description (§4.1.1): the accuracy log, then each
// symbol's probability plus 1, in fewer bits as the probability left
// shrinks, with runs of zeros as 2-bit repeat counts. It ends on a byte.
fn put_fse_header(b: Bits&, norm: const i64[:], log: i64) {
    bits_put(b, log - 5, 4);
    var left = (1 << log) + 1;
    var threshold = 1 << log;
    var nbits = log + 1;
    var s = 0;
    var zero = false;
    while left > 1 {
        if zero {
            var start = s;
            while norm[s] == 0 { s++; }
            while s >= start + 3 {
                start += 3;
                bits_put(b, 3, 2);
            }
            bits_put(b, s - start, 2);
        }
        let p = norm[s];
        s++;
        // Values below `low` take a bit fewer; those from threshold up are
        // moved past the ones that do.
        let low = 2 * threshold - 1 - left;
        left -= abs(p);
        var v = p + 1;
        if v >= threshold { v += low; }
        bits_put(b, v, if v < low { nbits - 1 } else { nbits });
        zero = v == 1;
        while left < threshold {
            nbits--;
            threshold >>= 1;
        }
    }
    bits_end(b);
}

// A bit writer for headers and other short streams, least significant bit
// first.
struct Bits {
    o: i64 = 0,
    acc: u64 = 0,
    n: i64 = 0,
    buf: u8[256],
}

fn bits_put(b: Bits&, v: i64, n: i64) {
    b.acc |= (v as! u64) << b.n;
    b.n += n;
    while b.n >= 8 {
        b.buf[b.o] = b.acc as! u8;
        b.o++;
        b.acc >>= 8;
        b.n -= 8;
    }
}

// Pads the bits to a byte.
fn bits_end(b: Bits&) {
    if b.n > 0 {
        b.buf[b.o] = b.acc as! u8;
        b.o++;
    }
    b.acc = 0;
    b.n = 0;
}
