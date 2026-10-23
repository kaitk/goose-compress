// CRC-32 against known values, across splits of its input, and against a bit
// at a time on each side of 2 KB, where it starts to take two halves at once.
import std;
import compress from "../../";
import check from "../";

fn crc_bitwise(crc: u32, data: const u8[:]) -> u32 {
    var c = ~crc;
    for x in data {
        c ^= x;
        for k in 8 { c = if c & 1 == 1 { 0xEDB88320 ^ (c >> 1) } else { c >> 1 }; }
    }
    return ~c;
}

fn main() {
    check::hex("crc32 of \"\"", compress::crc32(0, ""), 0);
    check::hex("crc32 of \"123456789\"", compress::crc32(0, "123456789"), 0xCBF43926);
    check::hex("crc32 of \"1234\", then \"56789\"",
               compress::crc32(compress::crc32(0, "1234"), "56789"), 0xCBF43926);
    // 16 bytes at a time, and the bytes left over, as zlib.crc32 gives it.
    var ff: u8[>..] = [];
    ff.push_n(255, 100000);
    check::hex("crc32 of 100000 bytes 0xff", compress::crc32(0, ff), 0x68C6CEC4);
    var bytes: u8[>..] = [];
    for i in 10240 { bytes.push(i as! u8); }
    check::hex("crc32 of bytes 0 to 255, 40 times", compress::crc32(0, bytes), 0xBBCE3B9D);
    for cut in [1, 15, 16, 17, 5000] {
        check::hex(str("the same, split at ", cut),
                   compress::crc32(compress::crc32(0, bytes[..cut]), bytes[cut..]), 0xBBCE3B9D);
    }
    var r = rng { 3 };
    var rand: u8[>..] = [];
    for i in 70001 { rand.push(r.rand_int(256) as! u8); }
    for n in [2015, 2047, 2048, 2049, 2079, 2080, 4111, 8397, 70001] {
        let want = crc_bitwise(0, rand[..n]);
        check::hex(str("crc32 of ", n, " random bytes"), compress::crc32(0, rand[..n]), want);
        check::hex(str("the same, from the crc32 of its first 7"),
                   compress::crc32(compress::crc32(0, rand[..7]), rand[7..n]), want);
    }
}
