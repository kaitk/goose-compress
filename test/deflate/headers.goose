// zlib's header for each level, and gzip's XFL.
import std;
import compress from "../../";
import check from "../";

fn main() {
    for flg, level in [0x01, 0x01, 0x5e, 0x5e, 0x5e, 0x5e, 0x9c, 0xda, 0xda, 0xda] {
        var z: u8[>..] = [];
        compress::compress("", z, compress::ZLIB, level);
        check::bytes(str("zlib level ", level, " CMF and FLG"), z[..2], [0x78, flg]);
        check::eq(str("zlib level ", level, " header mod 31"), (0x78 * 256 + z[1] as i64) % 31, 0);
    }
    var gz: u8[>..] = [];
    compress::compress("", gz);
    check::eq("gzip default level XFL", gz[8], 0);
    gz.clear();
    compress::compress("", gz, compress::GZIP, 1);
    check::eq("gzip level 1 XFL", gz[8], 4);
    gz.clear();
    compress::compress("", gz, compress::GZIP, 9);
    check::eq("gzip level 9 XFL", gz[8], 2);
}
