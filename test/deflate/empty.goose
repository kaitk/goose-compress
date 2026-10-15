// An empty input at level 0, in each format: one empty stored block.
import std;
import compress from "../../";
import check from "../";

fn main() {
    var gz: u8[>..] = [];
    compress::compress("", gz, compress::GZIP, 0);
    check::bytes("gzip", gz, [0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 255, 1, 0, 0, 0xff, 0xff,
                              0, 0, 0, 0, 0, 0, 0, 0]);
    var z: u8[>..] = [];
    compress::compress("", z, compress::ZLIB, 0);
    check::bytes("zlib", z, [0x78, 0x01, 1, 0, 0, 0xff, 0xff, 0, 0, 0, 1]);
    check::eq("zlib header mod 31", (0x78 * 256 + 0x01) % 31, 0);
    check::bytes("raw", check::raw("", 0), [1, 0, 0, 0xff, 0xff]);
}
