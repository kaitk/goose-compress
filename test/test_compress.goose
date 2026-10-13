// Unit tests for the checksums and the encoder: known checksum values, the
// Huffman code builder, the exact bytes of small streams at level 0, of small
// fixed and dynamic Huffman streams at level 1, and of what the levels match
// differently, and that a stream's bytes don't depend on how its input was
// split across writes; for zstd, XXH64 and the exact bytes of small frames.
// scripts/test-unit.sh runs them through TinyCC; scripts/roundtrip.py checks
// the output against gzip, zstd, and Python's zlib and compression.zstd.
import std;
import compress from "../";

fn same(got: const u8[:], want: const i64[:]) -> bool {
    guard got.len == want.len else { return false; }
    for b, i in got { guard b == want[i] else { return false; } }
    return true;
}

fn raw(data: const u8[:], level: i64) -> u8[>..] {
    var out: u8[>..] = [];
    compress::compress(data, out, compress::RAW, level);
    return out;
}

fn test_checksums() {
    assert(compress::crc32(0, "") == 0);
    assert(compress::crc32(0, "123456789") == 0xCBF43926);
    assert(compress::crc32(compress::crc32(0, "1234"), "56789") == 0xCBF43926);
    assert(compress::adler32(1, "") == 1);
    assert(compress::adler32(1, "Wikipedia") == 0x11E60398);
    assert(compress::adler32(compress::adler32(1, "Wiki"), "pedia") == 0x11E60398);
    // Past one run between reductions, at the largest sums, as Python's
    // zlib.adler32 gives it.
    var ff: u8[>..] = [];
    ff.push_n(255, 100000);
    assert(compress::adler32(1, ff) == 0x149A302C);
    // 16 bytes at a time, and the bytes left over, as zlib.crc32 gives it.
    assert(compress::crc32(0, ff) == 0x68C6CEC4);
    var bytes: u8[>..] = [];
    for i in 10240 { bytes.push(i as! u8); }
    assert(compress::crc32(0, bytes) == 0xBBCE3B9D);
    for cut in [1, 15, 16, 17, 5000] {
        assert(compress::crc32(compress::crc32(0, bytes[..cut]), bytes[cut..]) == 0xBBCE3B9D);
    }
    // 32-byte blocks across runs, and the bytes left over, as zlib.adler32 gives it.
    assert(compress::adler32(1, bytes) == 0xF475ED1E);
    for cut in [1, 31, 32, 33, 5552, 5553, 5600] {
        assert(compress::adler32(compress::adler32(1, bytes[..cut]), bytes[cut..]) == 0xF475ED1E);
    }
}

fn test_empty() {
    var gz: u8[>..] = [];
    compress::compress("", gz, compress::GZIP, 0);
    assert(same(gz, [0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 255, 1, 0, 0, 0xff, 0xff,
                     0, 0, 0, 0, 0, 0, 0, 0]));
    var z: u8[>..] = [];
    compress::compress("", z, compress::ZLIB, 0);
    assert(same(z, [0x78, 0x01, 1, 0, 0, 0xff, 0xff, 0, 0, 0, 1]));
    assert((0x78 * 256 + 0x01) % 31 == 0);
    assert(same(raw("", 0), [1, 0, 0, 0xff, 0xff]));
}

fn test_one_byte() {
    var z: u8[>..] = [];
    compress::compress("a", z, compress::ZLIB, 0);
    // Adler-32 of "a" is 0x00620062.
    assert(same(z, [0x78, 0x01, 1, 1, 0, 0xfe, 0xff, 'a', 0, 0x62, 0, 0x62]));
}

// zlib's header for each level, and gzip's XFL.
fn test_headers() {
    for flg, level in [0x01, 0x01, 0x5e, 0x5e, 0x5e, 0x5e, 0x9c, 0xda, 0xda, 0xda] {
        var z: u8[>..] = [];
        compress::compress("", z, compress::ZLIB, level);
        assert(z[0] == 0x78 && z[1] == flg);
        assert((0x78 * 256 + z[1] as i64) % 31 == 0);
    }
    var gz: u8[>..] = [];
    compress::compress("", gz);
    assert(gz[8] == 0);
    gz.clear();
    compress::compress("", gz, compress::GZIP, 1);
    assert(gz[8] == 4);
    gz.clear();
    compress::compress("", gz, compress::GZIP, 9);
    assert(gz[8] == 2);
}

// Small fixed-Huffman streams, which Python's zlib decompresses to their input.
// The first two are zlib's own at level 1 with Z_FIXED. zlib never matches
// the stream's first byte, its hash table's empty mark, so it spends a literal
// more than these on each of the rest.
fn test_fixed() {
    assert(same(raw("", 1), [0x03, 0x00]));
    assert(same(raw("a", 1), [0x4b, 0x04, 0x00]));
    // A literal, then a match of 9 at distance 1.
    assert(same(raw("aaaaaaaaaa", 1), [0x4b, 0x84, 0x03, 0x00]));
    // Three literals, then a match of 6 at distance 3.
    assert(same(raw("abcabcabc", 1), [0x4b, 0x4c, 0x4a, 0x86, 0x20, 0x00]));
    // Seven literals, then a match of 12 at distance 7.
    assert(same(raw("hello, hello, hello", 1),
                [0xcb, 0x48, 0xcd, 0xc9, 0xc9, 0xd7, 0x51, 0x40, 0xa6, 0x00]));
    assert(raw("hello, hello, hello", 9) == raw("hello, hello, hello", 1));
}

// What the levels do differently, in fixed-Huffman streams Python's zlib
// decompresses to their input.
fn test_levels() {
    // Level 1 probes the hash bucket's newest entry: the last "abcdefgh" is a
    // match of 4 at distance 9 and one of 4 at 18. Level 2 follows the chain
    // to a match of 8 at 18.
    let chain = "abcdefgh1abcdXYZW2abcdefgh";
    assert(same(raw(chain, 1), [
        0x4b, 0x4c, 0x4a, 0x4e, 0x49, 0x4d, 0x4b, 0xcf, 0x30, 0x04, 0x31, 0x22, 0x22,
        0xa3, 0xc2, 0x8d, 0x40, 0x0c, 0x90, 0x08, 0x00]));
    let deep = [
        0x4b, 0x4c, 0x4a, 0x4e, 0x49, 0x4d, 0x4b, 0xcf, 0x30, 0x04, 0x31, 0x22, 0x22,
        0xa3, 0xc2, 0x8d, 0x60, 0x22, 0x00];
    for level in 2..10 { assert(same(raw(chain, level), deep)); }

    // At the last "abcdefgh", greedy levels take "abcd" at distance 13, then
    // "efgh" at 9. From level 5, a match of 7 one byte on is better: a
    // literal "a", then "bcdefgh" at 9.
    let lazy = "abcdXbcdefghYabcdefgh";
    let greedy = [
        0x4b, 0x4c, 0x4a, 0x4e, 0x89, 0x48, 0x4a, 0x4e, 0x49, 0x4d, 0x4b, 0xcf, 0x88,
        0x04, 0x71, 0x40, 0x0c, 0x00];
    let lazier = [
        0x4b, 0x4c, 0x4a, 0x4e, 0x89, 0x48, 0x4a, 0x4e, 0x49, 0x4d, 0x4b, 0xcf, 0x88,
        0x4c, 0x84, 0x32, 0x00];
    for level in 1..5 { assert(same(raw(lazy, level), greedy)); }
    for level in 5..10 { assert(same(raw(lazy, level), lazier)); }
}

// The Kraft sum of h's lengths in units of 2^-15, which is 2^15 for a
// complete code.
fn kraft(h: compress::Huff&) -> i64 {
    var sum = 0;
    for n in h.len { if n > 0 { sum += 1 << (15 - n); } }
    return sum;
}

fn test_huffman() {
    // RFC 1951 §3.2.2's example: lengths 3, 3, 3, 3, 3, 2, 4, 4 give codes
    // 010, 011, 100, 101, 110, 00, 1110, and 1111, here bit-reversed: 010,
    // 110, 001, 101, 011, 00, 0111, and 1111.
    var h = compress::Huff { .. };
    for n, s in [3, 3, 3, 3, 3, 2, 4, 4] { h.len[s] = n as! u8; }
    compress::huff_codes(h);
    for c, s in [0x2, 0x6, 0x1, 0x5, 0x3, 0x0, 0x7, 0xf] {
        assert(h.code[s] == c);
    }

    // Optimal lengths, and none for a symbol that isn't used.
    compress::huff_build([1, 1, 2, 0, 3, 5, 8], h, 15);
    for n, s in [5, 5, 4, 0, 3, 2, 1] { assert(h.len[s] == n); }
    assert(kraft(h) == 1 << 15);

    // With fewer than two symbols used, two get 1 bit.
    compress::huff_build([0, 0, 0, 7], h, 15);
    for n, s in [1, 0, 0, 1] { assert(h.len[s] == n); }
    compress::huff_build([0, 0, 0], h, 15);
    for n, s in [1, 1, 0] { assert(h.len[s] == n); }

    // Fibonacci frequencies would take 28 bits for 29 symbols; the code
    // stops at the limit and stays complete, with the least frequent symbols
    // the longest.
    var fib: u32[29] = [0; 29];
    fib[0] = 1;
    fib[1] = 1;
    for i in 2..29 { fib[i] = fib[i - 1] + fib[i - 2]; }
    compress::huff_build(fib, h, 15);
    assert(h.len[0] == 15 && h.len[28] < 15 && kraft(h) == 1 << 15);
    for i in 1..29 { assert(h.len[i] <= h.len[i - 1]); }
    // The code-length code's limit: 19 symbols in 7 bits.
    compress::huff_build(fib[..19], h, 7);
    var sum = 0;
    for n in h.len[..19] {
        assert(n >= 1 && n <= 7);
        sum += 1 << (7 - n);
    }
    assert(sum == 1 << 7);
}

// Small dynamic blocks, which Python's zlib decompresses to their input.
fn test_dynamic() {
    // No 3 bytes repeat, so nothing matches and the distance code is the
    // two 1-bit codes a block without distances sends.
    let db = "aaacaagaataccacgactagcaggagtatcatgattcccgcctcggcgtctgcttgggtgttt";
    assert(same(raw(db, 1), [
        0x05, 0xc1, 0x31, 0x0d, 0x00, 0x00, 0x00, 0x83, 0x30, 0xad, 0x0b, 0x07,
        0x06, 0xf0, 0x9f, 0xb5, 0xdb, 0xd8, 0xdc, 0x1a, 0x0c, 0x47, 0x93, 0xe9,
        0x6c, 0xb1, 0x5c, 0x01, 0x42, 0x28, 0x46, 0x52, 0x6a, 0x56, 0x07]));
    // Literals and short matches, the first of 5 at distance 7.
    let dna = "gattacagattaccatgacgtagctagcatcgtacgatcgatgcatgctagg";
    let one = raw(dna, 1);
    assert(same(one, [
        0x25, 0x88, 0xb1, 0x0d, 0x00, 0x40, 0x10, 0x82, 0x66, 0x25, 0x16, 0x2e,
        0xc0, 0xfe, 0xf9, 0xf8, 0x57, 0x18, 0x84, 0xa2, 0x84, 0x43, 0xb0, 0xa4,
        0xd2, 0x6c, 0xb8, 0x9f, 0x8e, 0x38, 0xff, 0xbd, 0x0f]));
    // The final bit and BTYPE 2.
    assert(one[0] & 7 == 5);

    // A dynamic block ended by a flush, then one that matches across it.
    var e = compress::encoder(compress::RAW, 1);
    var out: u8[>..] = [];
    compress::write(e, dna, out);
    compress::flush(e, out);
    // The empty stored block's 3 bits go in the last byte of the block if they
    // fit there.
    assert(out.len == one.len + 4 || out.len == one.len + 5);
    assert(out[0] == one[0] & 0xfe && out[1..one.len - 1] == one[1..one.len - 1]);
    assert(same(out[out.len - 4..], [0, 0, 0xff, 0xff]));
    out.clear();
    compress::write(e, db, out);
    compress::finish(e, out);
    assert(same(out, [
        0x1d, 0xcb, 0xb1, 0x09, 0x00, 0x40, 0x10, 0x84, 0xc0, 0x5a, 0x65, 0x03,
        0x1b, 0xb0, 0x7f, 0x9e, 0xfb, 0x54, 0x1c, 0x60, 0x20, 0x7c, 0x32, 0xb9,
        0x3a, 0x14, 0xa3, 0xdb, 0xa8, 0x6d, 0x6e, 0x4d, 0x67, 0x3b, 0x99, 0x9a,
        0xd5, 0x03]));
}

// Random bytes would grow in a code, so the block is stored.
fn test_stored_fallback() {
    var data: u8[>..] = [];
    var r = rng { 11 };
    for i in 1000 { data.push(r.rand_int(256) as! u8); }
    let out = raw(data, 1);
    assert(out.len == 5 + data.len);
    assert(out[0] == 1 && out[1] == 0xe8 && out[2] == 0x03);
    assert(out[5..] == data);
}

// Bytes that repeat at distance 32768 exactly, the farthest DEFLATE reaches, in
// runs of 258, the longest match: 32768 random bytes, then the first 258 again
// at each of several offsets.
fn far_repeats() -> u8[>..] {
    var data: u8[>..] = [];
    var r = rng { 5 };
    for i in compress::WSIZE { data.push(r.rand_int(256) as! u8); }
    for i in 3 * compress::WSIZE { data.push(data[i]); }
    return data;
}

fn test_far_matches() {
    let data = far_repeats();
    let out = raw(data, 1);
    // The first 32 KB stored. The rest repeats only at distance 32768, and
    // comes out at least 10 times smaller: a match of 258 takes 31 bits, and
    // a probe misses where a later position took its hash bucket.
    assert(out.len < compress::WSIZE + 3 * compress::WSIZE / 10);
}

// The same input through one-shot compress and through writes of each size
// below must give the same bytes when nothing flushes.
fn test_splits() {
    var data: u8[>..] = [];
    var r = rng { 7 };
    // Random bytes, with runs copied from up to 40 KB back.
    while data.len < 3 * compress::STORED_MAX + 100 {
        if data.len > 40000 && r.rand_int(16) == 0 {
            let from = data.len - 1 - r.rand_int(40000);
            for k in r.rand_int(300) { data.push(data[from + k]); }
        }
        data.push(r.rand_int(256) as! u8);
    }
    let far = far_repeats();
    for level in [0, 1, 2, 6, 9] {
        for input in [data[..], far[..]] {
            var whole: u8[>..] = [];
            compress::compress(input, whole, compress::GZIP, level);
            if level == 0 && input.len % compress::STORED_MAX != 0 {
                // The gzip header and trailer, and a 5-byte header a block.
                let blocks = input.len / compress::STORED_MAX + 1;
                assert(whole.len == 10 + 5 * blocks + input.len + 8);
            }
            for size in [1, 257, 1000, compress::WSIZE - 1, compress::WSIZE + 1,
                         compress::STORED_MAX, compress::STORED_MAX + 1, input.len] {
                var e = compress::encoder(compress::GZIP, level);
                var out: u8[>..] = [];
                var at = 0;
                while at < input.len {
                    let end = min(at + size, input.len);
                    compress::write(e, input[at..end], out);
                    at = end;
                }
                compress::finish(e, out);
                assert(out == whole);
            }
        }
    }
}

// An encoder reset partway through a stream, at another format and level, gives
// what a new encoder gives.
fn test_reset() {
    let data = far_repeats();
    for format in [compress::GZIP, compress::ZLIB, compress::RAW] {
        for level in [0, 1, 6] {
            var e = compress::encoder(compress::ZLIB, 9);
            var junk: u8[>..] = [];
            compress::write(e, data[..50000], junk);
            compress::flush(e, junk);
            compress::write(e, data[50000..70000], junk);
            compress::reset(e, format, level);
            var got: u8[>..] = [];
            compress::write(e, data, got);
            compress::finish(e, got);
            var fresh = compress::encoder(format, level);
            var want: u8[>..] = [];
            compress::write(fresh, data, want);
            compress::finish(fresh, want);
            assert(got == want);
        }
    }
}

// A flush ends what was written with an empty stored block; the stream goes on.
fn test_flush() {
    var e = compress::encoder(compress::RAW, 0);
    var out: u8[>..] = [];
    compress::flush(e, out);
    assert(same(out, [0, 0, 0, 0xff, 0xff]));
    out.clear();
    compress::write(e, "hi", out);
    assert(out.len == 0);
    compress::flush(e, out);
    assert(same(out, [0, 2, 0, 0xfd, 0xff, 'h', 'i', 0, 0, 0, 0xff, 0xff]));
    out.clear();
    compress::finish(e, out);
    assert(same(out, [1, 0, 0, 0xff, 0xff]));
}

// The same at level 1, as zlib gives it, and a match that reaches back across
// a flush to the stream's first byte.
fn test_fixed_flush() {
    var e = compress::encoder(compress::RAW, 1);
    var out: u8[>..] = [];
    compress::flush(e, out);
    assert(same(out, [0, 0, 0, 0xff, 0xff]));
    out.clear();
    compress::write(e, "hi", out);
    assert(out.len == 0);
    compress::flush(e, out);
    assert(same(out, [0xca, 0xc8, 0x04, 0x00, 0, 0, 0xff, 0xff]));
    out.clear();
    compress::finish(e, out);
    assert(same(out, [0x03, 0x00]));

    var f = compress::encoder(compress::RAW, 1);
    out.clear();
    compress::write(f, "hello, ", out);
    compress::flush(f, out);
    assert(same(out, [0xca, 0x48, 0xcd, 0xc9, 0xc9, 0xd7, 0x51, 0x00, 0, 0, 0, 0xff,
                      0xff]));
    out.clear();
    compress::write(f, "hello, hello", out);
    compress::finish(f, out);
    // A match of 12 at distance 7, where zlib gives a literal and 11.
    assert(same(out, [0x43, 0xa6, 0x00]));
}

fn zstd(data: const u8[:], level: i64 = 1) -> u8[>..] {
    var out: u8[>..] = [];
    compress::compress(data, out, compress::ZSTD, level);
    return out;
}

fn test_zstd() {
    assert(compress::xxh64("") == 0xEF46DB3751D8E999);
    assert(compress::xxh64("a") == 0xD24EC4F1A98C6E5B);
    assert(compress::xxh64("abc") == 0x44BC2CF5AD770999);
    // Stripes, then 4 bytes, as a Python port of the reference gives it.
    var bytes: u8[>..] = [];
    for i in 100 { bytes.push(i as! u8); }
    assert(compress::xxh64(bytes) == 7692681977284421015);
    for cut in [1, 31, 32, 33, 50] {
        var x = compress::Xxh64 { .. };
        compress::xxh64_update(x, bytes[..cut]);
        compress::xxh64_update(x, bytes[cut..]);
        assert(compress::xxh64_digest(x) == 7692681977284421015);
    }

    // The magic, the descriptor, a 128 KB window, an empty last raw block,
    // and XXH64("")'s low 32 bits.
    assert(same(zstd(""), [0x28, 0xB5, 0x2F, 0xFD, 0x04, 0x38, 1, 0, 0,
                           0x99, 0xE9, 0xD8, 0x51]));
    // A last RLE block of 4 bytes.
    assert(same(zstd("aaaa"), [0x28, 0xB5, 0x2F, 0xFD, 0x04, 0x38, 0x23, 0, 0, 0x61,
                               0x32, 0xBF, 0x84, 0xBF]));
    // A last raw block of 2 bytes.
    assert(same(zstd("ab"), [0x28, 0xB5, 0x2F, 0xFD, 0x04, 0x38, 0x11, 0, 0, 0x61, 0x62,
                             0x61, 0x4A, 0xD0, 0x92]));

    // A last compressed block of 14 bytes: 8 raw literals, then 1 sequence
    // with the predefined tables. The sequence is the 8 literals and a match
    // of 24 at distance 8, the third of the starting repeat offsets 1, 4, and
    // 8, so its offset value is 3: code 1, with 1 extra bit. Its bitstream
    // is that bit, the match length's, offset's, and literal length's states
    // (32, 23, and 28, which decode to codes 21, 1, and 8), and a 1 bit.
    let abc = "abcdefghabcdefghabcdefghabcdefgh";
    assert(same(zstd(abc), [0x28, 0xB5, 0x2F, 0xFD, 0x04, 0x38, 0x75, 0, 0, 0x40,
                            0x61, 0x62, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x01, 0x00,
                            0xC1, 0xCB, 0x05, 0xCE, 0x1A, 0x76, 0x51]));
    // The same block not last, then after a flush a last one of 7 bytes: a
    // literal, then a match of 31 at distance 8, now the first repeat offset,
    // so offset value 1, with no extra bits.
    var f = compress::zstd_encoder(1);
    var fout: u8[>..] = [];
    compress::write(f, abc, fout);
    compress::flush(f, fout);
    compress::write(f, abc, fout);
    compress::finish(f, fout);
    assert(same(fout, [0x28, 0xB5, 0x2F, 0xFD, 0x04, 0x38, 0x74, 0, 0, 0x40, 0x61,
                       0x62, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x01, 0x00, 0xC1, 0xCB,
                       0x05, 0x3D, 0, 0, 0x08, 0x61, 0x01, 0x00, 0x0D, 0xB8, 0x02,
                       0x7B, 0x53, 0x07, 0x18]));

    // A last compressed block of 15 bytes, of Huffman literals alone: no
    // 4 bytes repeat, so there are no sequences. Bytes 0 to 3, 16, 8, 4, and
    // 4 times, take codes of 1, 2, 3, and 3 bits: 1, 01, 000, and 001, as
    // weights 3, 2, and 1, the last byte's left for the decoder. The section
    // header says 32 bytes out of 11 in one stream; the weights take 2 bytes
    // after their count, 127 + 3; the stream's 56 bits and closing 1 bit take
    // 8 bytes. Then a 0 for no sequences.
    let lits: u8[32] = [0, 0, 2, 1, 0, 3, 1, 2, 3, 0, 1, 0, 2, 0, 0, 0, 0, 3, 1, 0, 0, 1,
                        2, 1, 0, 1, 0, 0, 0, 1, 0, 3];
    assert(same(zstd(lits), [0x28, 0xB5, 0x2F, 0xFD, 0x04, 0x38, 0x7D, 0x00, 0x00, 0x02,
                             0xC2, 0x02, 0x82, 0x32, 0x10, 0xD9, 0x1B, 0xBA, 0x3C, 0x36,
                             0x28, 0xC3, 0x01, 0x00, 0xAB, 0x13, 0x10, 0x5C]));

    // Tables built from a block, then repeated in the next. Each part is a
    // word, then 12 times a separator of 1 or 2 bytes and the word again,
    // and a flush ends the first part's block, of 52 bytes. Its 11 sequences
    // are a match of 8 at distances 9 and 10 by turns, after 9, 2, and 1
    // literals: the modes byte A4 gives the literal lengths and offsets
    // tables built from the block, and the match lengths an RLE table, its
    // code 5. The literal lengths' table, of accuracy 5, gives 14, 15, and 3
    // of its 32 states to codes 1, 2, and 9, described in the 4 bytes
    // 10 78 BC 3D; the offsets' gives 26 to code 1, the second repeat offset,
    // and 6 to code 3, new offsets, in 10 D8 E1. The second part's block, of 45
    // bytes, has modes EC: it repeats both of those tables, and builds one
    // for its offsets, which start from the first block's repeat offsets.
    var two: u8[>..] = [];
    for word, w in ["abcdefgh", "ijklmnop"] {
        two.append(word);
        for i in 12 {
            two.push_n((65 + 12 * w + i) as! u8, 1 + i % 2);
            two.append(word);
        }
    }
    var t = compress::zstd_encoder(1);
    var tout: u8[>..] = [];
    compress::write(t, two[..122], tout);
    compress::flush(t, tout);
    compress::write(t, two[122..], tout);
    compress::finish(t, tout);
    assert(same(tout, [
        0x28, 0xB5, 0x2F, 0xFD, 0x04, 0x38, 0xA4, 0x01, 0x00, 0x24, 0x02, 0x61, 0x62, 0x63,
        0x64, 0x65, 0x66, 0x67, 0x68, 0x41, 0x42, 0x42, 0x43, 0x44, 0x44, 0x45, 0x46, 0x46,
        0x47, 0x48, 0x48, 0x49, 0x4A, 0x4A, 0x4B, 0x4C, 0x4C, 0x61, 0x62, 0x63, 0x64, 0x65,
        0x66, 0x67, 0x68, 0x0B, 0xA4, 0x10, 0x78, 0xBC, 0x3D, 0x10, 0xD8, 0xE1, 0x05, 0x4A,
        0x95, 0x40, 0x05, 0x94, 0x3B, 0x6D, 0x01, 0x00, 0x24, 0x02, 0x69, 0x6A, 0x6B, 0x6C,
        0x6D, 0x6E, 0x6F, 0x70, 0x4D, 0x4E, 0x4E, 0x4F, 0x50, 0x50, 0x51, 0x52, 0x52, 0x53,
        0x54, 0x54, 0x55, 0x56, 0x56, 0x57, 0x58, 0x58, 0x69, 0x6A, 0x6B, 0x6C, 0x6D, 0x6E,
        0x6F, 0x70, 0x0B, 0xEC, 0x40, 0x3E, 0xAA, 0x42, 0xE0, 0xB8, 0x3B, 0xB2, 0xD1, 0x03,
        0xA1]));
    // A new frame has no tables to repeat: after reset, the same input comes
    // out as from a new encoder, whose first block builds its tables.
    compress::reset(t, 1);
    tout.clear();
    compress::write(t, two[122..], tout);
    compress::finish(t, tout);
    var fresh = compress::zstd_encoder(1);
    var fout2: u8[>..] = [];
    compress::write(fresh, two[122..], fout2);
    compress::finish(fresh, fout2);
    assert(tout == fout2 && tout[6 + 3 + 2 + 34 + 1] == 0xA4);

    // Level 3 finds the 5-byte matches level 1's 6-byte hash misses: words of
    // 5 bytes, each with a separator no other has, so no 6 bytes repeat. Its
    // last block, of 44 bytes, holds 31 raw literals and 13 sequences: a
    // match of 5 at distance 12 after 12 literals, then 12 after 1 literal at
    // the first repeat offset. The modes byte A4 builds the literal lengths'
    // and offsets' tables and gives the match lengths an RLE table, code 2.
    // The last word is within 8 bytes of the end, where no position is
    // probed. Level 1 codes the literals alone, with no sequences.
    var words: u8[>..] = [];
    for i in 16 {
        words.append(if i % 2 == 0 { "hello" } else { "world" });
        words.push((65 + i) as! u8);
    }
    let words3 = [
        0x28, 0xB5, 0x2F, 0xFD, 0x04, 0x38, 0x65, 0x01, 0x00, 0xF8, 0x68, 0x65, 0x6C, 0x6C,
        0x6F, 0x41, 0x77, 0x6F, 0x72, 0x6C, 0x64, 0x42, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48,
        0x49, 0x4A, 0x4B, 0x4C, 0x4D, 0x4E, 0x4F, 0x77, 0x6F, 0x72, 0x6C, 0x64, 0x50, 0x0D,
        0xA4, 0x10, 0xF8, 0xFA, 0x19, 0xF0, 0xD5, 0x02, 0x8B, 0x3C, 0xA5, 0x04, 0x5F, 0x4D,
        0x9D];
    assert(same(zstd(words, 3), words3));
    let words1 = zstd(words);
    assert(words1.len == 81 && words1[words1.len - 5] == 0);
    // The hash tables are kept across reset, out of the new stream's reach:
    // after a stream at level 3 and one at level 1, the words come out as
    // from a new encoder.
    var g = compress::zstd_encoder(3);
    var gout: u8[>..] = [];
    compress::write(g, two, gout);
    compress::write(g, words, gout);
    compress::finish(g, gout);
    compress::reset(g, 1);
    gout.clear();
    compress::write(g, words, gout);
    compress::finish(g, gout);
    assert(gout == words1);
    compress::reset(g, 3);
    gout.clear();
    compress::write(g, words, gout);
    compress::finish(g, gout);
    assert(same(gout, words3));

    // Across blocks, the bytes don't depend on how the input was split, and a
    // flush with nothing held writes nothing.
    var big: u8[>..] = [];
    for i in 300000 { big.push((i * 7 / 3) as! u8); }
    let whole = zstd(big, 3);
    for step in [1000, 131072, 131073] {
        var e = compress::zstd_encoder(3);
        var out: u8[>..] = [];
        var at = 0;
        while at < big.len {
            let end = min(at + step, big.len);
            compress::write(e, big[at..end], out);
            at = end;
        }
        compress::finish(e, out);
        assert(out == whole);
        compress::reset(e, 3);
        out.clear();
        compress::write(e, "ab", out);
        compress::flush(e, out);
        let n = out.len;
        compress::flush(e, out);
        assert(out.len == n && n == 6 + 3 + 2);
    }
}

fn main() {
    test_checksums();
    test_empty();
    test_one_byte();
    test_headers();
    test_fixed();
    test_levels();
    test_huffman();
    test_dynamic();
    test_stored_fallback();
    test_far_matches();
    test_splits();
    test_reset();
    test_flush();
    test_fixed_flush();
    test_zstd();
    print("test_compress: ok");
}
