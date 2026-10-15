// Adler-32 against known values, and across splits of its input.
import std;
import compress from "../../";
import check from "../";

fn main() {
    check::hex("adler32 of \"\"", compress::adler32(1, ""), 1);
    check::hex("adler32 of \"Wikipedia\"", compress::adler32(1, "Wikipedia"), 0x11E60398);
    check::hex("adler32 of \"Wiki\", then \"pedia\"",
               compress::adler32(compress::adler32(1, "Wiki"), "pedia"), 0x11E60398);
    // Past one run between reductions, at the largest sums, as Python's
    // zlib.adler32 gives it.
    var ff: u8[>..] = [];
    ff.push_n(255, 100000);
    check::hex("adler32 of 100000 bytes 0xff", compress::adler32(1, ff), 0x149A302C);
    // 32-byte blocks across runs, and the bytes left over, as zlib.adler32 gives it.
    var bytes: u8[>..] = [];
    for i in 10240 { bytes.push(i as! u8); }
    check::hex("adler32 of bytes 0 to 255, 40 times", compress::adler32(1, bytes), 0xF475ED1E);
    for cut in [1, 31, 32, 33, 5552, 5553, 5600] {
        check::hex(str("the same, split at ", cut),
                   compress::adler32(compress::adler32(1, bytes[..cut]), bytes[cut..]),
                   0xF475ED1E);
    }
}
