// Compresses a file to gzip with the package, as bench/ref.c does with
// libdeflate and zlib-ng: one-shot, the whole file in memory, RUNS times.
//
//   bench LEVEL FILE RUNS
//
// Prints the same line as bench/ref.c, under the name goose.
import std;
import os;
import compress from "../";

fn main() {
    let a = args();
    guard a.len == 4 else { write_stderr("usage: bench LEVEL FILE RUNS\n"); exit(2); }
    let level, lok = parse_int(a[1]);
    let runs, rok = parse_int(a[3]);
    guard lok && rok && level >= 0 && level <= 9 && runs > 0 else {
        write_stderr("bad arguments\n");
        exit(2);
    }
    var data: u8[>..] = [];
    guard read_file(a[2], data) else { write_stderr("can't read input\n"); exit(1); }
    var out: u8[>..] = [];
    var rates: f64[>..] = [];
    for i in runs {
        out.clear();
        let t = clock_ns();
        compress::compress(data, out, compress::GZIP, level);
        let ns = clock_ns() - t;
        rates.push(data.len / (ns * 1e-9) / 1e6);
    }
    sort(rates);
    var line: u8[>..] = [];
    format(line, "goose ", level, " ", data.len, " ", out.len, " ");
    format_flt(line, rates[runs / 2], 1);
    line.push(' ');
    format_flt(line, rates[runs - 1], 1);
    print(line);
}
