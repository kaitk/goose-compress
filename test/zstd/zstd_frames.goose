// zstd frames of one empty, RLE, or raw block, which `zstd -d` and
// compression.zstd decompress to their input.
import std;
import compress from "../../";
import check from "../";

fn main() {
    // The magic, the descriptor, a 128 KB window, an empty last raw block,
    // and XXH64("")'s low 32 bits.
    check::bytes("\"\"", check::zstd(""), [0x28, 0xB5, 0x2F, 0xFD, 0x04, 0x38, 1, 0, 0,
                                          0x99, 0xE9, 0xD8, 0x51]);
    // A last RLE block of 4 bytes.
    check::bytes("\"aaaa\"", check::zstd("aaaa"), [0x28, 0xB5, 0x2F, 0xFD, 0x04, 0x38, 0x23,
                                                  0, 0, 0x61, 0x32, 0xBF, 0x84, 0xBF]);
    // A last raw block of 2 bytes.
    check::bytes("\"ab\"", check::zstd("ab"), [0x28, 0xB5, 0x2F, 0xFD, 0x04, 0x38, 0x11, 0,
                                              0, 0x61, 0x62, 0x61, 0x4A, 0xD0, 0x92]);
}
