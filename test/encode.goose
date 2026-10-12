// Compresses a file for scripts/roundtrip.py, which checks the result with gzip
// and Python's zlib.
//
//   encode FORMAT IN OUT [PLAN]
//
// FORMAT is gzip, zlib, or raw. Without PLAN, the input goes through one-shot
// compress. PLAN is a comma-separated list of steps for the streaming encoder:
// a number writes that many more bytes of the input, and `f` flushes. The rest
// of the input is written after the last step, then the stream finished. For
// each flush, the program prints the input and output lengths so far, one pair
// a line.
import std;
import os;
import compress from "../";

fn main() {
    let a = args();
    guard a.len == 4 || a.len == 5 else {
        write_stderr("usage: encode gzip|zlib|raw IN OUT [PLAN]\n");
        exit(2);
    }
    let format = if a[1] == "gzip" { compress::GZIP }
        else if a[1] == "zlib" { compress::ZLIB }
        else if a[1] == "raw" { compress::RAW }
        else { -1 };
    guard format >= 0 else { write_stderr("unknown format\n"); exit(2); }
    var data: u8[>..] = [];
    guard read_file(a[2], data) else { write_stderr("can't read input\n"); exit(1); }
    var out: u8[>..] = [];
    if a.len == 4 {
        compress::compress(data, out, format);
    } else {
        var e = compress::encoder(format);
        var at = 0;
        each_split(a[4], ',') {
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
    guard write_file(a[3], out) else { write_stderr("can't write output\n"); exit(1); }
}
