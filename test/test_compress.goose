// Unit tests for the checksums and the encoder: known checksum values, the
// exact bytes of small streams at level 0 and of small fixed-Huffman streams at
// level 1, and that a stream's bytes don't depend on how its input was split
// across writes. scripts/test-unit.sh runs them through TinyCC;
// scripts/roundtrip.py checks the output against gzip and Python's zlib.
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
    // Every level from 1 matches the same way for now.
    assert(raw("hello, hello, hello", 9) == raw("hello, hello, hello", 1));
}

// Random bytes would grow in the fixed code, so the block is stored.
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
    for level in [0, 1, 6] {
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

fn main() {
    test_checksums();
    test_empty();
    test_one_byte();
    test_headers();
    test_fixed();
    test_stored_fallback();
    test_far_matches();
    test_splits();
    test_flush();
    test_fixed_flush();
    print("test_compress: ok");
}
