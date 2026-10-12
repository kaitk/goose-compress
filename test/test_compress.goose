// Unit tests for the checksums and the stored-block encoder: known checksum
// values, the exact bytes of small streams, and that a stream's bytes don't
// depend on how its input was split across writes. scripts/test-unit.sh runs
// them through TinyCC; scripts/roundtrip.py checks the output against gzip and
// Python's zlib.
import std;
import compress from "../";

fn same(got: const u8[:], want: const i64[:]) -> bool {
    guard got.len == want.len else { return false; }
    for b, i in got { guard b == want[i] else { return false; } }
    return true;
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
    compress::compress("", gz);
    assert(same(gz, [0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 255, 1, 0, 0, 0xff, 0xff,
                     0, 0, 0, 0, 0, 0, 0, 0]));
    var z: u8[>..] = [];
    compress::compress("", z, compress::ZLIB);
    assert(same(z, [0x78, 0x01, 1, 0, 0, 0xff, 0xff, 0, 0, 0, 1]));
    assert((0x78 * 256 + 0x01) % 31 == 0);
    var raw: u8[>..] = [];
    compress::compress("", raw, compress::RAW);
    assert(same(raw, [1, 0, 0, 0xff, 0xff]));
}

fn test_one_byte() {
    var z: u8[>..] = [];
    compress::compress("a", z, compress::ZLIB);
    // Adler-32 of "a" is 0x00620062.
    assert(same(z, [0x78, 0x01, 1, 1, 0, 0xfe, 0xff, 'a', 0, 0x62, 0, 0x62]));
}

// The same input through one-shot compress and through writes of each size
// below must give the same bytes when nothing flushes.
fn test_splits() {
    var data: u8[>..] = [];
    var r = rng { 7 };
    for i in 3 * compress::STORED_MAX + 100 { data.push(r.rand_int(256) as! u8); }
    var whole: u8[>..] = [];
    compress::compress(data, whole);
    // The gzip header and trailer, and four blocks of 5 header bytes each.
    assert(whole.len == 10 + 4 * 5 + data.len + 8);
    for size in [1, 1000, compress::STORED_MAX - 1, compress::STORED_MAX,
                 compress::STORED_MAX + 1, data.len] {
        var e = compress::encoder();
        var out: u8[>..] = [];
        var at = 0;
        while at < data.len {
            let end = min(at + size, data.len);
            compress::write(e, data[at..end], out);
            at = end;
        }
        compress::finish(e, out);
        assert(out == whole);
    }
}

// A flush ends what was written with an empty stored block; the stream goes on.
fn test_flush() {
    var e = compress::encoder(compress::RAW);
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

fn main() {
    test_checksums();
    test_empty();
    test_one_byte();
    test_splits();
    test_flush();
    print("test_compress: ok");
}
