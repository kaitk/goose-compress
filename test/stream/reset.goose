// An encoder reset partway through a stream, at another format and level,
// gives what a new encoder gives.
import std;
import compress from "../../";
import check from "../";

fn main() {
    let data = check::far_repeats();
    for format, f in [compress::GZIP, compress::ZLIB, compress::RAW] {
        for level in [0, 1, 6] {
            var e = compress::encoder(compress::ZLIB, 9);
            var junk: u8[>..] = [];
            compress::write(e, data[..50000], junk);
            compress::flush(e, junk);
            compress::write(e, data[50000..70000], junk);
            compress::reset(e, format, level);
            var got: u8[>..] = [];
            compress::write(e, data, got);
            compress::finish(e, got);
            var fresh = compress::encoder(format, level);
            var want: u8[>..] = [];
            compress::write(fresh, data, want);
            compress::finish(fresh, want);
            check::that(str(["gzip", "zlib", "raw"][f], " level ", level,
                            " after reset: as from a new encoder"), got == want);
        }
    }
}
