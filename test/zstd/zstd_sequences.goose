// Compressed zstd blocks of raw literals and sequences with the predefined
// tables, alone and across a flush with a repeat offset. `zstd -d` and
// compression.zstd decompress each to its input.
import std;
import compress from "../../";
import check from "../";

fn main() {
    // A last compressed block of 14 bytes: 8 raw literals, then 1 sequence
    // with the predefined tables. The sequence is the 8 literals and a match
    // of 24 at distance 8, the third of the starting repeat offsets 1, 4, and
    // 8, so its offset value is 3: code 1, with 1 extra bit. Its bitstream
    // is that bit, the match length's, offset's, and literal length's states
    // (32, 23, and 28, which decode to codes 21, 1, and 8), and a 1 bit.
    let abc = "abcdefghabcdefghabcdefghabcdefgh";
    check::bytes("one block", check::zstd(abc), [
        0x28, 0xB5, 0x2F, 0xFD, 0x04, 0x38, 0x75, 0, 0, 0x40, 0x61, 0x62, 0x63, 0x64,
        0x65, 0x66, 0x67, 0x68, 0x01, 0x00, 0xC1, 0xCB, 0x05, 0xCE, 0x1A, 0x76, 0x51]);
    // The same block not last, then after a flush a last one of 7 bytes: a
    // literal, then a match of 31 at distance 8, now the first repeat offset,
    // so offset value 1, with no extra bits.
    var f = compress::zstd_encoder(1);
    var fout: u8[>..] = [];
    compress::write(f, abc, fout);
    compress::flush(f, fout);
    compress::write(f, abc, fout);
    compress::finish(f, fout);
    check::bytes("the same, a flush, and again", fout, [
        0x28, 0xB5, 0x2F, 0xFD, 0x04, 0x38, 0x74, 0, 0, 0x40, 0x61, 0x62, 0x63, 0x64,
        0x65, 0x66, 0x67, 0x68, 0x01, 0x00, 0xC1, 0xCB, 0x05, 0x3D, 0, 0, 0x08, 0x61,
        0x01, 0x00, 0x0D, 0xB8, 0x02, 0x7B, 0x53, 0x07, 0x18]);
}
