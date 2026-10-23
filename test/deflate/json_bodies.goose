// The gzip output's size for each small JSON body bench/json.goose times, at
// level 1 and the default level, so that a matcher change which grows it
// shows. scripts/roundtrip.py checks these bodies decompress to their input.
import std;
import compress from "../../";
import check from "../";

fn main() {
    let names = ["small100", "json25", "json40", "json50"];
    let bodies = [
        embed_file("../../bench/json/small100.json"),
        embed_file("../../bench/json/json25.json"),
        embed_file("../../bench/json/json40.json"),
        embed_file("../../bench/json/json50.json"),
    ];
    let want = [[108, 108], [1008, 938], [1420, 1273], [1703, 1483]];
    let levels = [1, 6];
    for i in names.len {
        for j in levels.len {
            var out: u8[>..] = [];
            compress::compress(bodies[i], out, compress::GZIP, levels[j]);
            check::eq(str(names[i], " (", bodies[i].len, " bytes), level ", levels[j]),
                      out.len, want[i][j]);
        }
    }
}
