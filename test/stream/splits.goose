// The same input through one-shot compress and through writes of each size
// below gives the same bytes when nothing flushes, at levels 0, 1, 2, 6, and 9.
import std;
import compress from "../../";
import check from "../";

fn main() {
    var data: u8[>..] = [];
    var r = rng { 7 };
    // Random bytes, with runs copied from up to 40 KB back.
    while data.len < 3 * compress::STORED_MAX + 100 {
        if data.len > 40000 && r.rand_int(16) == 0 {
            let from = data.len - 1 - r.rand_int(40000);
            for k in r.rand_int(300) { data.push(data[from + k]); }
        }
        data.push(r.rand_int(256) as! u8);
    }
    let far = check::far_repeats();
    for level in [0, 1, 2, 6, 9] {
        for input, i in [data[..], far[..]] {
            let name = if i == 0 { "copies" } else { "far repeats" };
            var whole: u8[>..] = [];
            compress::compress(input, whole, compress::GZIP, level);
            if level == 0 && input.len % compress::STORED_MAX != 0 {
                // The gzip header and trailer, and a 5-byte header a block.
                let blocks = input.len / compress::STORED_MAX + 1;
                check::eq(str("level 0, ", name, ", one-shot: length"), whole.len,
                          10 + 5 * blocks + input.len + 8);
            }
            var same = true;
            for size in [1, 257, 1000, compress::WSIZE - 1, compress::WSIZE + 1,
                         compress::STORED_MAX, compress::STORED_MAX + 1, input.len] {
                var e = compress::encoder(compress::GZIP, level);
                var out: u8[>..] = [];
                var at = 0;
                while at < input.len {
                    let end = min(at + size, input.len);
                    compress::write(e, input[at..end], out);
                    at = end;
                }
                compress::finish(e, out);
                if out != whole {
                    print("  writes of ", size, " differ");
                    same = false;
                }
            }
            check::that(str("level ", level, ", ", name, ", ", input.len,
                            " bytes: written in pieces of each size, as one-shot"), same);
        }
    }
}
