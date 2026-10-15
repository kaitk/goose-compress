// Matches at distance 32768, the farthest DEFLATE reaches.
import std;
import compress from "../../";
import check from "../";

fn main() {
    let data = check::far_repeats();
    let out = check::raw(data, 1);
    // The first 32 KB stored. The rest repeats only at distance 32768, and
    // comes out at least 10 times smaller: a match of 258 takes 31 bits, and
    // a probe misses where a later position took its hash bucket.
    let limit = compress::WSIZE + 3 * compress::WSIZE / 10;
    check::that(str("32 KB random, then 96 KB repeating at 32768: ", out.len,
                    " bytes, under ", limit),
                out.len < limit);
}
