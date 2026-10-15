// One byte at level 0, in zlib.
import std;
import compress from "../../";
import check from "../";

fn main() {
    var z: u8[>..] = [];
    compress::compress("a", z, compress::ZLIB, 0);
    // Adler-32 of "a" is 0x00620062.
    check::bytes("zlib of \"a\"", z, [0x78, 0x01, 1, 1, 0, 0xfe, 0xff, 'a', 0, 0x62, 0, 0x62]);
}
