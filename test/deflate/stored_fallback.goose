// Random bytes would grow in a code, so level 1 stores the block.
import std;
import compress from "../../";
import check from "../";

fn main() {
    var data: u8[>..] = [];
    var r = rng { 11 };
    for i in 1000 { data.push(r.rand_int(256) as! u8); }
    let out = check::raw(data, 1);
    check::eq("1000 random bytes: length", out.len, 5 + data.len);
    check::bytes("its stored block's header", out[..5], [1, 0xe8, 0x03, 0x17, 0xfc]);
    check::that("then the input", out[5..] == data);
}
