// Across zstd blocks, the bytes don't depend on how the input was split, and a
// flush with nothing held writes nothing.
import std;
import compress from "../../";
import check from "../";

fn main() {
    var big: u8[>..] = [];
    for i in 300000 { big.push((i * 7 / 3) as! u8); }
    let whole = check::zstd(big, 3);
    for step in [1000, 131072, 131073] {
        var e = compress::zstd_encoder(3);
        var out: u8[>..] = [];
        var at = 0;
        while at < big.len {
            let end = min(at + step, big.len);
            compress::write(e, big[at..end], out);
            at = end;
        }
        compress::finish(e, out);
        check::that(str("300000 bytes at level 3, written in pieces of ", step, ": as one-shot"),
                    out == whole);
        compress::reset(e, 3);
        out.clear();
        compress::write(e, "ab", out);
        compress::flush(e, out);
        let n = out.len;
        compress::flush(e, out);
        check::eq("after reset, \"ab\" and a flush: length", n, 6 + 3 + 2);
        check::eq("and after a second flush", out.len, n);
    }
}
