// A flush at level 0 ends what was written with an empty stored block; the
// stream goes on.
import std;
import compress from "../../";
import check from "../";

fn main() {
    var e = compress::encoder(compress::RAW, 0);
    var out: u8[>..] = [];
    compress::flush(e, out);
    check::bytes("flush with nothing written", out, [0, 0, 0, 0xff, 0xff]);
    out.clear();
    compress::write(e, "hi", out);
    check::eq("write \"hi\": bytes out", out.len, 0);
    compress::flush(e, out);
    check::bytes("flush", out, [0, 2, 0, 0xfd, 0xff, 'h', 'i', 0, 0, 0, 0xff, 0xff]);
    out.clear();
    compress::finish(e, out);
    check::bytes("finish", out, [1, 0, 0, 0xff, 0xff]);
}
