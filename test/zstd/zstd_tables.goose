// zstd sequence tables built from a block, then repeated in the next across a
// flush, and none to repeat after reset. `zstd -d` and compression.zstd
// decompress the frame to its input.
import std;
import compress from "../../";
import check from "../";

fn main() {
    // A flush ends the first part's block, of 52 bytes. Its 11 sequences are a
    // match of 8 at distances 9 and 10 by turns, after 9, 2, and 1 literals:
    // the modes byte A4 gives the literal lengths and offsets tables built
    // from the block, and the match lengths an RLE table, its code 5. The
    // literal lengths' table, of accuracy 5, gives 14, 15, and 3 of its 32
    // states to codes 1, 2, and 9, described in the 4 bytes 10 78 BC 3D; the
    // offsets' gives 26 to code 1, the second repeat offset, and 6 to code 3,
    // new offsets, in 10 D8 E1. The second part's block, of 45 bytes, has
    // modes EC: it repeats both of those tables, and builds one for its
    // offsets, which start from the first block's repeat offsets.
    let two = check::two_words();
    var t = compress::zstd_encoder(1);
    var tout: u8[>..] = [];
    compress::write(t, two[..122], tout);
    compress::flush(t, tout);
    compress::write(t, two[122..], tout);
    compress::finish(t, tout);
    check::bytes("two parts, a flush between", tout, [
        0x28, 0xB5, 0x2F, 0xFD, 0x04, 0x38, 0xA4, 0x01, 0x00, 0x24, 0x02, 0x61, 0x62, 0x63,
        0x64, 0x65, 0x66, 0x67, 0x68, 0x41, 0x42, 0x42, 0x43, 0x44, 0x44, 0x45, 0x46, 0x46,
        0x47, 0x48, 0x48, 0x49, 0x4A, 0x4A, 0x4B, 0x4C, 0x4C, 0x61, 0x62, 0x63, 0x64, 0x65,
        0x66, 0x67, 0x68, 0x0B, 0xA4, 0x10, 0x78, 0xBC, 0x3D, 0x10, 0xD8, 0xE1, 0x05, 0x4A,
        0x95, 0x40, 0x05, 0x94, 0x3B, 0x6D, 0x01, 0x00, 0x24, 0x02, 0x69, 0x6A, 0x6B, 0x6C,
        0x6D, 0x6E, 0x6F, 0x70, 0x4D, 0x4E, 0x4E, 0x4F, 0x50, 0x50, 0x51, 0x52, 0x52, 0x53,
        0x54, 0x54, 0x55, 0x56, 0x56, 0x57, 0x58, 0x58, 0x69, 0x6A, 0x6B, 0x6C, 0x6D, 0x6E,
        0x6F, 0x70, 0x0B, 0xEC, 0x40, 0x3E, 0xAA, 0x42, 0xE0, 0xB8, 0x3B, 0xB2, 0xD1, 0x03,
        0xA1]);
    // A new frame has no tables to repeat: after reset, the same input comes
    // out as from a new encoder, whose first block builds its tables.
    compress::reset(t, 1);
    tout.clear();
    compress::write(t, two[122..], tout);
    compress::finish(t, tout);
    var fresh = compress::zstd_encoder(1);
    var fout: u8[>..] = [];
    compress::write(fresh, two[122..], fout);
    compress::finish(fresh, fout);
    check::that("the second part after reset: as from a new encoder", tout == fout);
    check::hex("its modes byte", tout[6 + 3 + 2 + 34 + 1], 0xA4, 2);
}
