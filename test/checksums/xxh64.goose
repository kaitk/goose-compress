// XXH64, zstd's checksum, against known values, and across splits of its input.
import std;
import compress from "../../";
import check from "../";

fn main() {
    check::hex("xxh64 of \"\"", compress::xxh64(""), 0xEF46DB3751D8E999, 16);
    check::hex("xxh64 of \"a\"", compress::xxh64("a"), 0xD24EC4F1A98C6E5B, 16);
    check::hex("xxh64 of \"abc\"", compress::xxh64("abc"), 0x44BC2CF5AD770999, 16);
    // Stripes, then 4 bytes, as a Python port of the reference gives it.
    var bytes: u8[>..] = [];
    for i in 100 { bytes.push(i as! u8); }
    check::hex("xxh64 of bytes 0 to 99", compress::xxh64(bytes), 7692681977284421015, 16);
    for cut in [1, 31, 32, 33, 50] {
        var x = compress::Xxh64 { .. };
        compress::xxh64_update(x, bytes[..cut]);
        compress::xxh64_update(x, bytes[cut..]);
        check::hex(str("the same, split at ", cut), compress::xxh64_digest(x),
                   7692681977284421015, 16);
    }
}
