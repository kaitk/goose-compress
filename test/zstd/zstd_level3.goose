// What zstd's level 3 matches that level 1 doesn't, and that the hash tables
// kept across reset are out of the new stream's reach.
import std;
import compress from "../../";
import check from "../";

fn main() {
    // Level 3 finds the 5-byte matches level 1's 6-byte hash misses. Its last
    // block, of 44 bytes, holds 31 raw literals and 13 sequences: a match of 5
    // at distance 12 after 12 literals, then 12 after 1 literal at the first
    // repeat offset. The modes byte A4 builds the literal lengths' and
    // offsets' tables and gives the match lengths an RLE table, code 2. The
    // last word is within 8 bytes of the end, where no position is probed.
    // Level 1 codes the literals alone, with no sequences.
    let words = check::five_byte_words();
    let words3 = [
        0x28, 0xB5, 0x2F, 0xFD, 0x04, 0x38, 0x65, 0x01, 0x00, 0xF8, 0x68, 0x65, 0x6C, 0x6C,
        0x6F, 0x41, 0x77, 0x6F, 0x72, 0x6C, 0x64, 0x42, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48,
        0x49, 0x4A, 0x4B, 0x4C, 0x4D, 0x4E, 0x4F, 0x77, 0x6F, 0x72, 0x6C, 0x64, 0x50, 0x0D,
        0xA4, 0x10, 0xF8, 0xFA, 0x19, 0xF0, 0xD5, 0x02, 0x8B, 0x3C, 0xA5, 0x04, 0x5F, 0x4D,
        0x9D];
    check::bytes("5-byte words, level 3", check::zstd(words, 3), words3);
    let words1 = check::zstd(words);
    check::eq("level 1: length", words1.len, 81);
    check::eq("its sequence count", words1[words1.len - 5], 0);
    // After a stream at level 3 and one at level 1, the words come out as
    // from a new encoder.
    var g = compress::zstd_encoder(3);
    var gout: u8[>..] = [];
    compress::write(g, check::two_words(), gout);
    compress::write(g, words, gout);
    compress::finish(g, gout);
    compress::reset(g, 1);
    gout.clear();
    compress::write(g, words, gout);
    compress::finish(g, gout);
    check::that("level 1 after reset: as from a new encoder", gout == words1);
    compress::reset(g, 3);
    gout.clear();
    compress::write(g, words, gout);
    compress::finish(g, gout);
    check::that("then level 3 after reset: as from a new encoder", check::same(gout, words3));
}
