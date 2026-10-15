// What the levels match differently, in fixed-Huffman streams Python's zlib
// decompresses to their input.
import std;
import compress from "../../";
import check from "../";

// Checks `data` at `levels` gives `want`: its bytes at the first level, and
// the same at each of the rest.
fn at_levels(label: const u8[:], data: const u8[:], levels: const i64[:], want: const i64[:]) {
    let first = check::raw(data, levels[0]);
    check::bytes(str(label, ", level ", levels[0]), first, want);
    for level in levels[1..] {
        check::that(str(label, ", level ", level, ": the same"), check::raw(data, level) == first);
    }
}

fn main() {
    // Level 1 tries the hash bucket's 2 newest entries: at the last
    // "abcdefgh", the older one gives a match of 8 at distance 18, as the
    // chains do.
    at_levels("2 matches", "abcdefgh1abcdXYZW2abcdefgh", [1, 2, 3, 4, 5, 6, 7, 8, 9], [
        0x4b, 0x4c, 0x4a, 0x4e, 0x49, 0x4d, 0x4b, 0xcf, 0x30, 0x04, 0x31, 0x22, 0x22,
        0xa3, 0xc2, 0x8d, 0x60, 0x22, 0x00]);
    // With a third "abcd", level 1 takes 4 at distance 9, then "efgh" at 27.
    // Level 2 follows the chain to a match of 8 at 27.
    let three = "abcdefgh1abcdXYZW2abcdQRST3abcdefgh";
    at_levels("3 matches", three, [1], [
        0x4b, 0x4c, 0x4a, 0x4e, 0x49, 0x4d, 0x4b, 0xcf, 0x30, 0x04, 0x31, 0x22, 0x22,
        0xa3, 0xc2, 0x8d, 0x40, 0x8c, 0xc0, 0xa0, 0xe0, 0x10, 0x63, 0x10, 0x03, 0x24,
        0x05, 0x00]);
    at_levels("3 matches", three, [2, 3, 4, 5, 6, 7, 8, 9], [
        0x4b, 0x4c, 0x4a, 0x4e, 0x49, 0x4d, 0x4b, 0xcf, 0x30, 0x04, 0x31, 0x22, 0x22,
        0xa3, 0xc2, 0x8d, 0x40, 0x8c, 0xc0, 0xa0, 0xe0, 0x10, 0x63, 0x98, 0x14, 0x00]);

    // At the last "abcdefgh", greedy levels take "abcd" at distance 13, then
    // "efgh" at 9. From level 5, a match of 7 one byte on is better: a
    // literal "a", then "bcdefgh" at 9.
    let lazy = "abcdXbcdefghYabcdefgh";
    at_levels("lazy", lazy, [1, 2, 3, 4], [
        0x4b, 0x4c, 0x4a, 0x4e, 0x89, 0x48, 0x4a, 0x4e, 0x49, 0x4d, 0x4b, 0xcf, 0x88,
        0x04, 0x71, 0x40, 0x0c, 0x00]);
    at_levels("lazy", lazy, [5, 6, 7, 8, 9], [
        0x4b, 0x4c, 0x4a, 0x4e, 0x89, 0x48, 0x4a, 0x4e, 0x49, 0x4d, 0x4b, 0xcf, 0x88,
        0x4c, 0x84, 0x32, 0x00]);
}
