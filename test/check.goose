// What the tests under test/ share. Each check prints what it checked, for the
// test's golden file in test/expected/, then asserts it, so a failure shows
// in the output as well as in the exit code.
namespace check;

import std;
import compress from "../";

let DIGITS = "0123456789abcdef";

fn push_hex(out: u8[>..]&, v: u64, digits: i64) {
    for k in digits { out.push(DIGITS[(v >> (4 * (digits - 1 - k)) as! u64) & 15]); }
}

// Prints "label: ok", or "label: FAILED".
fn that(label: const u8[:], ok: bool) {
    print(label, if ok { ": ok" } else { ": FAILED" });
    assert(ok);
}

// Prints the value in decimal, and what was expected if it differs.
fn eq(label: const u8[:], got: i64, want: i64) {
    if got == want { print(label, ": ", got); }
    else { print(label, ": ", got, ", expected ", want, ": FAILED"); }
    assert(got == want);
}

// Prints the value in hexadecimal, `digits` digits long, and what was expected
// if it differs.
fn hex(label: const u8[:], got: u64, want: u64, digits: i64 = 8) {
    var line: u8[>..] = [];
    line.append(label);
    line.append(": ");
    push_hex(line, got, digits);
    if got != want {
        line.append(", expected ");
        push_hex(line, want, digits);
        line.append(": FAILED");
    }
    print(line);
    assert(got == want);
}

fn dump(data: const u8[:]) {
    var line: u8[>..] = [];
    for b, i in data {
        line.append(if i % 16 == 0 { "   " } else { " " });
        push_hex(line, b, 2);
        if i % 16 == 15 || i == data.len - 1 {
            print(line);
            line.clear();
        }
    }
}

fn same(got: const u8[:], want: const i64[:]) -> bool {
    guard got.len == want.len else { return false; }
    for b, i in got { guard b == want[i] else { return false; } }
    return true;
}

// Prints the bytes, 16 to a line, and what was expected if they differ.
fn bytes(label: const u8[:], got: const u8[:], want: const i64[:]) {
    let ok = same(got, want);
    print(label, ": ", got.len, " bytes", if ok { "" } else { ": FAILED" });
    dump(got);
    if !ok {
        print("  expected ", want.len, " bytes:");
        var w: u8[>..] = [];
        for b in want { w.push(b as! u8); }
        dump(w);
    }
    assert(ok);
}

// Raw DEFLATE, one-shot.
fn raw(data: const u8[:], level: i64) -> u8[>..] {
    var out: u8[>..] = [];
    compress::compress(data, out, compress::RAW, level);
    return out;
}

// zstd, one-shot.
fn zstd(data: const u8[:], level: i64 = 1) -> u8[>..] {
    var out: u8[>..] = [];
    compress::compress(data, out, compress::ZSTD, level);
    return out;
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

// Two parts, each a word, then 12 times a separator of 1 or 2 bytes and the
// word again: 122 bytes, then 122 more.
fn two_words() -> u8[>..] {
    var two: u8[>..] = [];
    for word, w in ["abcdefgh", "ijklmnop"] {
        two.append(word);
        for i in 12 {
            two.push_n((65 + 12 * w + i) as! u8, 1 + i % 2);
            two.append(word);
        }
    }
    return two;
}

// Words of 5 bytes, each with a separator no other has, so no 6 bytes repeat.
fn five_byte_words() -> u8[>..] {
    var words: u8[>..] = [];
    for i in 16 {
        words.append(if i % 2 == 0 { "hello" } else { "world" });
        words.push((65 + i) as! u8);
    }
    return words;
}
