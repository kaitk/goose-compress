// A flush at level 1, as zlib gives it, and a match that reaches back across a
// flush to the stream's first byte.
import std;
import compress from "../../";
import check from "../";

fn main() {
    var e = compress::encoder(compress::RAW, 1);
    var out: u8[>..] = [];
    compress::flush(e, out);
    check::bytes("flush with nothing written", out, [0, 0, 0, 0xff, 0xff]);
    out.clear();
    compress::write(e, "hi", out);
    check::eq("write \"hi\": bytes out", out.len, 0);
    compress::flush(e, out);
    check::bytes("flush", out, [0xca, 0xc8, 0x04, 0x00, 0, 0, 0xff, 0xff]);
    out.clear();
    compress::finish(e, out);
    check::bytes("finish", out, [0x03, 0x00]);

    var f = compress::encoder(compress::RAW, 1);
    out.clear();
    compress::write(f, "hello, ", out);
    compress::flush(f, out);
    check::bytes("\"hello, \", flush", out,
                 [0xca, 0x48, 0xcd, 0xc9, 0xc9, 0xd7, 0x51, 0x00, 0, 0, 0, 0xff, 0xff]);
    out.clear();
    compress::write(f, "hello, hello", out);
    compress::finish(f, out);
    // A match of 12 at distance 7, where zlib gives a literal and 11.
    check::bytes("then \"hello, hello\", finish", out, [0x43, 0xa6, 0x00]);
}
