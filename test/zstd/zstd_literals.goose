// A compressed zstd block of Huffman literals alone, which `zstd -d` and
// compression.zstd decompress to its input.
import std;
import compress from "../../";
import check from "../";

fn main() {
    // A last compressed block of 15 bytes: no 4 bytes repeat, so there are no
    // sequences. Bytes 0 to 3, 16, 8, 4, and 4 times, take codes of 1, 2, 3,
    // and 3 bits: 1, 01, 000, and 001, as weights 3, 2, and 1, the last byte's
    // left for the decoder. The section header says 32 bytes out of 11 in one
    // stream; the weights take 2 bytes after their count, 127 + 3; the
    // stream's 56 bits and closing 1 bit take 8 bytes. Then a 0 for no
    // sequences.
    let lits: u8[32] = [0, 0, 2, 1, 0, 3, 1, 2, 3, 0, 1, 0, 2, 0, 0, 0, 0, 3, 1, 0, 0, 1,
                        2, 1, 0, 1, 0, 0, 0, 1, 0, 3];
    check::bytes("32 bytes of 4 values", check::zstd(lits), [
        0x28, 0xB5, 0x2F, 0xFD, 0x04, 0x38, 0x7D, 0x00, 0x00, 0x02, 0xC2, 0x02, 0x82, 0x32,
        0x10, 0xD9, 0x1B, 0xBA, 0x3C, 0x36, 0x28, 0xC3, 0x01, 0x00, 0xAB, 0x13, 0x10, 0x5C]);
}
