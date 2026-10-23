// Times one-shot gzip of a small body, as a server compresses each response:
// BATCHES batches of PER calls, after one call that sets the encoder up.
//
//   json LEVEL FILE BATCHES PER
//
// Prints the name goose, the level, the input and output sizes, and the median
// and best batch's ns per call.
import std;
import os;
import compress from "../";

fn main() {
    let a = args();
    guard a.len == 5 else {
        write_stderr("usage: json LEVEL FILE BATCHES PER\n");
        exit(2);
    }
    let level, lok = parse_int(a[1]);
    let batches, bok = parse_int(a[3]);
    let per, pok = parse_int(a[4]);
    guard lok && bok && pok && level >= 0 && level <= 9 && batches > 0 && per > 0 else {
        write_stderr("bad arguments\n");
        exit(2);
    }
    var data: u8[>..] = [];
    guard read_file(a[2], data) else { write_stderr("can't read input\n"); exit(1); }
    var out: u8[>..] = [];
    compress::compress(data, out, compress::GZIP, level);
    var ns: f64[>..] = [];
    for b in batches {
        let t = clock_ns();
        for i in per {
            out.clear();
            compress::compress(data, out, compress::GZIP, level);
        }
        ns.push((clock_ns() - t) as f64 / per);
    }
    sort(ns);
    var line: u8[>..] = [];
    format(line, "goose ", level, " ", data.len, " ", out.len, " ");
    format_flt(line, ns[batches / 2], 0);
    line.push(' ');
    format_flt(line, ns[0], 0);
    print(line);
}
