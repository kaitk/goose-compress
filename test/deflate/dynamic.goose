// Small dynamic blocks at level 1, which Python's zlib decompresses to their
// input.
import std;
import compress from "../../";
import check from "../";

fn main() {
    // No 3 bytes repeat, so nothing matches and the distance code is the
    // two 1-bit codes a block without distances sends.
    let db = "aaacaagaataccacgactagcaggagtatcatgattcccgcctcggcgtctgcttgggtgttt";
    check::bytes("no matches", check::raw(db, 1), [
        0x05, 0xc1, 0x31, 0x0d, 0x00, 0x00, 0x00, 0x83, 0x30, 0xad, 0x0b, 0x07,
        0x06, 0xf0, 0x9f, 0xb5, 0xdb, 0xd8, 0xdc, 0x1a, 0x0c, 0x47, 0x93, 0xe9,
        0x6c, 0xb1, 0x5c, 0x01, 0x42, 0x28, 0x46, 0x52, 0x6a, 0x56, 0x07]);
    // Literals and short matches, the first of 5 at distance 7.
    let dna = "gattacagattaccatgacgtagctagcatcgtacgatcgatgcatgctagg";
    let one = check::raw(dna, 1);
    check::bytes("short matches", one, [
        0x25, 0x88, 0xb1, 0x0d, 0x00, 0x40, 0x10, 0x82, 0x66, 0x25, 0x16, 0x2e,
        0xc0, 0xfe, 0xf9, 0xf8, 0x57, 0x18, 0x84, 0xa2, 0x84, 0x43, 0xb0, 0xa4,
        0xd2, 0x6c, 0xb8, 0x9f, 0x8e, 0x38, 0xff, 0xbd, 0x0f]);
    check::eq("its final bit and BTYPE", one[0] & 7, 5);

    // A dynamic block ended by a flush, then one that matches across it.
    var e = compress::encoder(compress::RAW, 1);
    var out: u8[>..] = [];
    compress::write(e, dna, out);
    compress::flush(e, out);
    // The empty stored block's 3 bits go in the last byte of the block if they
    // fit there.
    check::that(str("flushed: ", out.len, " bytes, the block's and 4 or 5 more"),
                out.len == one.len + 4 || out.len == one.len + 5);
    check::that("the same block, not final",
                out[0] == one[0] & 0xfe && out[1..one.len - 1] == one[1..one.len - 1]);
    check::bytes("ending in", out[out.len - 4..], [0, 0, 0xff, 0xff]);
    out.clear();
    compress::write(e, db, out);
    compress::finish(e, out);
    check::bytes("then a block matching across the flush", out, [
        0x25, 0xcc, 0xb1, 0x0d, 0x00, 0x20, 0x00, 0x84, 0xc0, 0x59, 0x3f, 0x14,
        0x2c, 0xc0, 0xfe, 0x31, 0x6a, 0xcf, 0xb1, 0x8d, 0xcd, 0xed, 0x11, 0xdc,
        0xaf, 0x75, 0xb6, 0xde, 0xa4, 0x00, 0x21, 0x14, 0xe3, 0xca, 0xd4, 0xac,
        0x0e]);
}
