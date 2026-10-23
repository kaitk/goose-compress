// Streams one after another through one encoder, reset in place between them,
// each give what a new encoder gives: at levels 1, 2, and 6, of sizes and
// flushes that vary, and across the clear of the hash tables once stream
// offsets would pass 2^31.
import std;
import compress from "../../";
import check from "../";

// Writes data as one stream, flushed every `every` bytes, or never for 0.
fn stream(e: compress::Encoder&, data: const u8[:], every: i64, out: u8[>..]&) {
    var at = 0;
    if every > 0 {
        while at + every < data.len {
            compress::write(e, data[at..at + every], out);
            compress::flush(e, out);
            at += every;
        }
    }
    compress::write(e, data[at..], out);
    compress::finish(e, out);
}

fn fresh(data: const u8[:], level: i64, every: i64) -> u8[>..] {
    var e = compress::encoder(compress::RAW, level);
    var out: u8[>..] = [];
    stream(e, data, every, out);
    return out;
}

// Words of 2 to 9 letters from a vocabulary of 300, so matches come at every
// distance.
fn words(n: i64) -> u8[>..] {
    var r = rng { 13 };
    // Word w is vocab[w * 9..], ending at the first 0.
    var vocab: u8[>..] = [];
    for i in 300 {
        let len = 2 + r.rand_int(8);
        for k in 9 { vocab.push(if k < len { (97 + r.rand_int(26)) as! u8 } else { 0 }); }
    }
    var data: u8[>..] = [];
    while data.len < n {
        let w = r.rand_int(r.rand_int(300) + 1);
        var k = 0;
        while k < 9 && vocab[w * 9 + k] != 0 && data.len < n {
            data.push(vocab[w * 9 + k]);
            k++;
        }
        if data.len < n { data.push(if r.rand_int(12) == 0 { 10 } else { 32 }); }
    }
    return data;
}

fn main() {
    let data = words(4 * compress::WSIZE);
    var r = rng { 17 };
    for level in [1, 2, 6] {
        var e = compress::encoder(compress::RAW, level);
        var same = 0;
        for i in 60 {
            let n = if i % 10 == 9 { 100000 } else { r.rand_int(12000) };
            let at = r.rand_int(data.len - n);
            let every = [0, 0, 1000, 4097][r.rand_int(4)];
            compress::reset(e, compress::RAW, level);
            var out: u8[>..] = [];
            stream(e, data[at..at + n], every, out);
            if out == fresh(data[at..at + n], level, every) { same++; }
        }
        check::eq(str("level ", level, ": streams after reset as from a new encoder, of 60"),
                  same, 60);
    }
    // Zeros with random bytes at 900 to 1,100, flushed every 1,000, which
    // leaves the 3 positions before each flush unhashed; the 20 bytes from
    // position 997 come again at 1,500.
    var second: u8[>..] = [];
    second.push_n(0, 2 * compress::WSIZE);
    for i in 900..1100 { second[i] = r.rand_int(256) as! u8; }
    for k in 20 { second[1500 + k] = second[997 + k]; }
    // A first stream of 2 * WSIZE that hashes position 997 as the second
    // would, then empty streams, each moving the offsets a window on, until
    // they come round to the first stream's again. Without the clear at 2^31,
    // its entry for 997 would be in reach at 1,500, a match a new encoder
    // doesn't find.
    var first: u8[>..] = [];
    first.append(second[..1004]);
    first.push_n(0, 2 * compress::WSIZE - first.len);
    for level in [1, 2, 6] {
        var e = compress::encoder(compress::RAW, level);
        var junk: u8[>..] = [];
        stream(e, first, 0, junk);
        for i in (1 << 32) / compress::WSIZE - 3 { compress::reset(e, compress::RAW, level); }
        compress::reset(e, compress::RAW, level);
        var out: u8[>..] = [];
        stream(e, second, 1000, out);
        check::that(str("level ", level, ": a stream after offsets passed 2^31",
                        " as from a new encoder"), out == fresh(second, level, 1000));
    }
}
