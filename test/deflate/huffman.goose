// The Huffman code builder: RFC 1951's canonical-code example, optimal lengths,
// and Fibonacci frequencies cut to 15 and to 7 bits.
import std;
import compress from "../../";
import check from "../";

// The Kraft sum of h's lengths in units of 2^-15, which is 2^15 for a
// complete code.
fn kraft(h: compress::Huff&) -> i64 {
    var sum = 0;
    for n in h.len { if n > 0 { sum += 1 << (15 - n); } }
    return sum;
}

fn lengths(label: const u8[:], h: compress::Huff&, want: const i64[:]) {
    var got: i64[>..] = [];
    for s in want.len { got.push(h.len[s]); }
    print(label, ": lengths ", got);
    for n, s in want { assert(h.len[s] == n); }
}

fn main() {
    // RFC 1951 §3.2.2's example: lengths 3, 3, 3, 3, 3, 2, 4, 4 give codes
    // 010, 011, 100, 101, 110, 00, 1110, and 1111, here bit-reversed: 010,
    // 110, 001, 101, 011, 00, 0111, and 1111.
    var h = compress::Huff { .. };
    for n, s in [3, 3, 3, 3, 3, 2, 4, 4] { h.len[s] = n as! u8; }
    compress::huff_codes(h);
    for c, s in [0x2, 0x6, 0x1, 0x5, 0x3, 0x0, 0x7, 0xf] {
        check::eq(str("RFC 1951 example, symbol ", s, " code"), h.code[s], c);
    }

    // Optimal lengths, and none for a symbol that isn't used.
    compress::huff_build([1, 1, 2, 0, 3, 5, 8], h, 15);
    lengths("counts 1, 1, 2, 0, 3, 5, 8", h, [5, 5, 4, 0, 3, 2, 1]);
    check::eq("their Kraft sum", kraft(h), 1 << 15);

    // With fewer than two symbols used, two get 1 bit.
    compress::huff_build([0, 0, 0, 7], h, 15);
    lengths("counts 0, 0, 0, 7", h, [1, 0, 0, 1]);
    compress::huff_build([0, 0, 0], h, 15);
    lengths("counts 0, 0, 0", h, [1, 1, 0]);

    // Fibonacci frequencies would take 28 bits for 29 symbols; the code
    // stops at the limit and stays complete, with the least frequent symbols
    // the longest.
    var fib: u32[29] = [0; 29];
    fib[0] = 1;
    fib[1] = 1;
    for i in 2..29 { fib[i] = fib[i - 1] + fib[i - 2]; }
    compress::huff_build(fib, h, 15);
    check::eq("29 Fibonacci counts, limit 15: symbol 0's length", h.len[0], 15);
    check::that("symbol 28's length under 15", h.len[28] < 15);
    check::eq("their Kraft sum", kraft(h), 1 << 15);
    var falls = true;
    for i in 1..29 { falls = falls && h.len[i] <= h.len[i - 1]; }
    check::that("lengths fall as counts grow", falls);
    // The code-length code's limit: 19 symbols in 7 bits.
    compress::huff_build(fib[..19], h, 7);
    var sum = 0;
    var within = true;
    for n in h.len[..19] {
        within = within && n >= 1 && n <= 7;
        sum += 1 << (7 - n);
    }
    check::that("19 Fibonacci counts, limit 7: lengths 1 to 7", within);
    check::eq("their Kraft sum, in units of 2^-7", sum, 1 << 7);
}
