// Huffman codes for DEFLATE's dynamic blocks: code lengths limited to a number
// of bits, built from symbol frequencies, and the canonical codes they define
// (RFC 1951 §3.2.2). zstd's literals take the lengths alone.
namespace compress;

import std;

// The largest alphabet DEFLATE codes: 286 literal/length symbols, with the two
// the fixed code also assigns.
let HUFF_MAX = 288;

// A Huffman code: each symbol's length, 0 for a symbol without a code, and its
// code bit-reversed, since DEFLATE packs Huffman codes from their most
// significant bit (RFC 1951 §3.1.1).
struct Huff {
    len: u8[HUFF_MAX],
    code: u16[HUFF_MAX],
}

// Sets h to a code for the symbols of freq, with no length over `limit`, and
// no code for a symbol of frequency 0. At least two symbols get a code, so the
// code is complete, as zlib's inflate requires of every code but a lone 1-bit
// one.
//
// The lengths are optimal for the frequencies until one would pass the limit:
// Moffat and Katajainen's in-place algorithm over the frequencies in
// ascending order. Past the limit, each length over it is cut to it, and
// leaves are moved down one level at a time, as zlib does, until the code is
// complete again. The lengths then go out in order, longest to the least
// frequent symbol.
fn huff_build(freq: const u32[:], h: Huff&, limit: i64) {
    huff_lengths(freq, h, limit);
    huff_codes(h);
}

// Sets h.len as huff_build does, and leaves h.code alone.
fn huff_lengths(freq: const u32[:], h: Huff&, limit: i64) {
    assert(freq.len <= HUFF_MAX && limit <= 15);
    for i in HUFF_MAX { h.len[i] = 0; }
    // Each used symbol as its frequency above bit 9 and the symbol below, so
    // the order is total and the code depends on nothing but freq.
    var keys: u64[HUFF_MAX] = [0; HUFF_MAX];
    var n = 0;
    for f, s in freq {
        if f > 0 {
            keys[n] = (f as u64) << 9 | s as! u64;
            n++;
        }
    }
    if n < 2 {
        let s = if n == 1 { (keys[0] & 511) as! i64 } else { 0 };
        h.len[s] = 1;
        h.len[if s == 0 { 1 } else { 0 }] = 1;
        return;
    }
    sort(keys[..n]);

    // a[..n] holds the frequencies, then each internal node's parent, then
    // each internal node's depth.
    var a: i64[HUFF_MAX] = [0; HUFF_MAX];
    for i in n { a[i] = (keys[i] >> 9) as! i64; }
    a[0] += a[1];
    var root = 0;
    var leaf = 2;
    for next in 1..n - 1 {
        if leaf >= n || a[root] < a[leaf] {
            a[next] = a[root];
            a[root] = next;
            root++;
        } else {
            a[next] = a[leaf];
            leaf++;
        }
        if leaf >= n || (root < next && a[root] < a[leaf]) {
            a[next] += a[root];
            a[root] = next;
            root++;
        } else {
            a[next] += a[leaf];
            leaf++;
        }
    }
    a[n - 2] = 0;
    var i = n - 3;
    while i >= 0 {
        a[i] = a[a[i]] + 1;
        i--;
    }

    // The number of leaves at each depth, those past the limit counted at it.
    var count: i64[16] = [0; 16];
    var avail = 1;
    var depth = 0;
    root = n - 2;
    while avail > 0 {
        var used = 0;
        while root >= 0 && a[root] == depth {
            used++;
            root--;
        }
        count[min(depth, limit)] += avail - used;
        avail = 2 * used;
        depth++;
    }

    // The Kraft sum in units of 2^-limit is 2^limit for a complete code. Each
    // step takes the deepest leaf above the limit down a level, puts a leaf
    // from the limit beside it, and lowers the sum by one.
    var kraft = 0;
    for l in 1..limit + 1 { kraft += count[l] << (limit - l); }
    while kraft > 1 << limit {
        var l = limit - 1;
        while count[l] == 0 { l--; }
        count[l]--;
        count[l + 1] += 2;
        count[limit]--;
        kraft--;
    }

    var k = 0;
    var l = limit;
    while l > 0 {
        for j in count[l] {
            h.len[(keys[k] & 511) as! i64] = l as! u8;
            k++;
        }
        l--;
    }
}

// Sets each symbol's code from the lengths: the canonical code, in which codes
// of one length are consecutive in symbol order and shorter codes come first.
fn huff_codes(h: Huff&) {
    var count: u32[16] = [0; 16];
    for n in h.len { count[n]++; }
    count[0] = 0;
    var next: u32[16] = [0; 16];
    var code: u32 = 0;
    for b in 1..16 {
        code = (code + count[b - 1]) << 1;
        next[b] = code;
    }
    for n, s in h.len {
        if n > 0 {
            h.code[s] = reverse_bits(next[n], n) as! u16;
            next[n]++;
        }
    }
}

fn reverse_bits(code: u32, n: i64) -> u32 {
    var r: u32 = 0;
    for i in n { r |= ((code >> i) & 1) << (n - 1 - i); }
    return r;
}
