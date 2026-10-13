// Compresses a file for scripts/roundtrip.py, which checks the result with gzip,
// zstd, and Python's zlib and compression.zstd.
//
//   encode FORMAT LEVEL IN OUT [PLAN]
//
// FORMAT is gzip, zlib, raw, or zstd, and LEVEL 0 to 9, or zstd's 1 to 22. Without PLAN, the input goes
// through one-shot compress. PLAN is a comma-separated list of steps for the
// streaming encoder: a number writes that many more bytes of the input, and `f`
// flushes. The rest of the input is written after the last step, then the
// stream finished. For each flush, the program prints the input and output
// lengths so far, one pair a line.
import std;
import os;
import compress from "../";

fn main() {
    let a = args();
    guard a.len == 5 || a.len == 6 else {
        write_stderr("usage: encode gzip|zlib|raw|zstd LEVEL IN OUT [PLAN]\n");
        exit(2);
    }
    let format = if a[1] == "gzip" { compress::GZIP }
        else if a[1] == "zlib" { compress::ZLIB }
        else if a[1] == "raw" { compress::RAW }
        else if a[1] == "zstd" { compress::ZSTD }
        else { -1 };
    guard format >= 0 else { write_stderr("unknown format\n"); exit(2); }
    let level, lok = parse_int(a[2]);
    let top = if format == compress::ZSTD { 22 } else { 9 };
    guard lok && level >= 0 && level <= top else { write_stderr("bad level\n"); exit(2); }
    var data: u8[>..] = [];
    guard read_file(a[3], data) else { write_stderr("can't read input\n"); exit(1); }
    var out: u8[>..] = [];
    if a.len == 5 {
        compress::compress(data, out, format, level);
    } else if format == compress::ZSTD {
        var e = compress::zstd_encoder(level);
        stream(&e, data, a[5], out);
    } else {
        var e = compress::encoder(format, level);
        stream(&e, data, a[5], out);
    }
    guard write_file(a[4], out) else { write_stderr("can't write output\n"); exit(1); }
}

// Runs the plan on e, an Encoder or a ZstdEncoder.
fn stream(e, data: const u8[:], plan: const u8[:], out: u8[>..]&) {
    var at = 0;
    each_split(plan, ',') {
        if it == "f" {
            compress::flush(e, out);
            print(at, " ", out.len);
        } else if it.len > 0 {
            let n, ok = parse_int(it);
            guard ok && n >= 0 else { write_stderr("bad plan\n"); exit(2); }
            let end = min(at + n, data.len);
            compress::write(e, data[at..end], out);
            at = end;
        }
    };
    compress::write(e, data[at..], out);
    compress::finish(e, out);
}
