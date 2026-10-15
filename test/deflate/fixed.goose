// Small fixed-Huffman streams at level 1, which Python's zlib decompresses to
// their input. The first two are zlib's own at level 1 with Z_FIXED. zlib never
// matches the stream's first byte, its hash table's empty mark, so it spends a
// literal more than these on each of the rest.
import std;
import compress from "../../";
import check from "../";

fn main() {
    check::bytes("\"\"", check::raw("", 1), [0x03, 0x00]);
    check::bytes("\"a\"", check::raw("a", 1), [0x4b, 0x04, 0x00]);
    // A literal, then a match of 9 at distance 1.
    check::bytes("\"aaaaaaaaaa\"", check::raw("aaaaaaaaaa", 1), [0x4b, 0x84, 0x03, 0x00]);
    // Three literals, then a match of 6 at distance 3.
    check::bytes("\"abcabcabc\"", check::raw("abcabcabc", 1),
                 [0x4b, 0x4c, 0x4a, 0x86, 0x20, 0x00]);
    // Seven literals, then a match of 12 at distance 7.
    check::bytes("\"hello, hello, hello\"", check::raw("hello, hello, hello", 1),
                 [0xcb, 0x48, 0xcd, 0xc9, 0xc9, 0xd7, 0x51, 0x40, 0xa6, 0x00]);
    check::that("\"hello, hello, hello\" at level 9 as at level 1",
                check::raw("hello, hello, hello", 9) == check::raw("hello, hello, hello", 1));
}
