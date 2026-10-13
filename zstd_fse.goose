// zstd's FSE tables (RFC 8878 §4.1): built from a distribution, distributions
// normalized from counts, and the table description a block sends.
namespace compress;

import std;
import math;
import .deflate;

// The most symbols a table codes, match lengths' 53, and the largest table,
// 2^9 states.
let FSE_SYMS = 53;
let FSE_STATES = 512;

// An FSE table for coding, in libzstd's form (FSE_buildCTable). A coder's
// state is size + t, where t is the state a decoder is in after the symbols
// coded so far. To code symbol s before them, it writes the low
// (state + dnb[s]) >> 16 bits of the state, n, and moves to
// next[(state >> n) + dfs[s]]: size plus the state that decodes s and reads
// those bits. A table of accuracy 0 codes one symbol in no bits, as an RLE
// mode does.
struct Fse {
    log: i64 = 0,
    // The distribution, of nsym symbols; -1 is a probability "less than 1".
    nsym: i64 = 0,
    norm: i64[FSE_SYMS],
    dnb: i32[FSE_SYMS],
    dfs: i32[FSE_SYMS],
    next: u16[FSE_STATES],
}

fn fse_table(norm: const i64[:], log: i64) -> Fse {
    var f = Fse { .. };
    fse_build(f, norm, log);
    return f;
}

// Builds f from a distribution of 2^log, spreading its symbols over the
// states as a decoder does (§4.1.1).
fn fse_build(f: Fse&, norm: const i64[:], log: i64) {
    let size = 1 << log;
    f.log = log;
    f.nsym = norm.len;
    var sym: u8[FSE_STATES] = [0; FSE_STATES];
    // Where each symbol's states start in next, in the order a decoder
    // numbers them.
    var at: i64[FSE_SYMS + 1] = [0; FSE_SYMS + 1];
    // "Less than 1" symbols take a state each from the end, the rest are
    // spread over the others.
    var high = size - 1;
    for p, s in norm {
        f.norm[s] = p;
        if p == -1 {
            sym[high] = s as! u8;
            high--;
        }
        at[s + 1] = at[s] + abs(p);
    }
    let step = (size >> 1) + (size >> 3) + 3;
    var u = 0;
    for p, s in norm {
        for i in max(p, 0) {
            sym[u] = s as! u8;
            u = (u + step) & (size - 1);
            while u > high { u = (u + step) & (size - 1); }
        }
    }
    // A symbol of probability p reads log - k or log - k + 1 bits, where 2^k
    // is the highest power of two below p, the fewer from the states below
    // p << (log - k).
    for p, s in norm {
        if p == -1 || p == 1 {
            f.dnb[s] = ((log << 16) - size) as! i32;
            f.dfs[s] = (at[s] - 1) as! i32;
        } else if p > 1 {
            let most = log - log2(p - 1);
            f.dnb[s] = ((most << 16) - (p << most)) as! i32;
            f.dfs[s] = (at[s] - p) as! i32;
        }
    }
    for t in size {
        let s = sym[t];
        f.next[at[s]] = (size + t) as! u16;
        at[s]++;
    }
}

// A coder's first state for symbol s, which a stream ends with whole, so any
// of s's would do: the one that codes s before a decoder's state 0.
fn fse_first(f: Fse&, s: i64) -> i64 {
    let v = 1 << f.log;
    return f.next[(v >> ((v + f.dnb[s]) >> 16)) + f.dfs[s]];
}

// Sets norm to a distribution of 2^log for the counts, which sum to total:
// each counted symbol gets at least 1, and the rest goes where it saves the
// most bits, a symbol's share of them being about its count over its
// probability. With `low`, a symbol whose share is at most 1 is "less than
// 1", -1, as libzstd's FSE_normalizeCount makes them for large blocks.
fn fse_normalize(count: const i64[:], total: i64, log: i64, norm: i64[:], low: bool = false) {
    let size = 1 << log;
    var sum = 0;
    for c, s in count {
        norm[s] = if c == 0 { 0 } else if low && c * size <= total { -1 }
                  else { max(1, (2 * c * size + total) / (2 * total)) };
        sum += abs(norm[s]);
    }
    while sum < size {
        var best = -1;
        for c, s in count {
            if norm[s] > 0 && (best < 0 || c * norm[best] > count[best] * norm[s]) { best = s; }
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

// 256 log2(x), rounded, for probabilities up to the largest table's.
let FSE_COST = fse_cost_tab();

fn fse_cost_tab() -> i64[FSE_STATES + 1] {
    var t: i64[FSE_STATES + 1] = [0; FSE_STATES + 1];
    for x in 1..FSE_STATES + 1 { t[x] = (::log2(x as f64) * 256.0 + 0.5) as i64; }
    return t;
}

// About how many bits, in 1/256ths, a distribution of 2^log codes the counts
// in, the last state included: a symbol of probability p takes log2(2^log / p),
// but for one of `first`, which a coder starts in a state of. -1 where it has
// no probability for a counted symbol.
fn fse_cost(norm: const i64[:], log: i64, count: const i64[:], first: i64) -> i64 {
    var bits = log << 8;
    for c, s in count {
        guard c > 0 else { continue; }
        guard s < norm.len && norm[s] != 0 else { return -1; }
        bits += c * ((log << 8) - FSE_COST[abs(norm[s])]);
    }
    return bits - ((log << 8) - FSE_COST[abs(norm[first])]);
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
