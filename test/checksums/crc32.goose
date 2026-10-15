// CRC-32 against known values, and across splits of its input.
import std;
import compress from "../../";
import check from "../";

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
}
