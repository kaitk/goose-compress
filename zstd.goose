// The zstd frame (RFC 8878): a header declaring the window, blocks, and the
// low 32 bits of the content's XXH64.
namespace compress;

import std;
import .checksum;

// zstd's levels, 1 to 22, as its own. Each runs the nearest level built so far.
let ZSTD_DEFAULT_LEVEL = 3;
let ZSTD_MAX_LEVEL = 22;
// The largest block (RFC 8878 §3.1.1.2.4), which is also the window the frame
// declares.
let ZSTD_BLOCK_MAX = 1 << 17;
let ZSTD_RAW = 0;
let ZSTD_RLE = 1;

// A zstd stream. Its blocks depend only on its input and where it was flushed,
// not on how the input was split across writes.
struct ZstdEncoder {
    level: i64 = ZSTD_DEFAULT_LEVEL,
    started: bool = false,
    finished: bool = false,
    check: Xxh64,
    // buf[..fill] holds the input not yet in a block. A full buffer is held
    // until more input comes, so the last block can carry the last-block flag.
    fill: i64 = 0,
    buf: u8[ZSTD_BLOCK_MAX],
}

fn zstd_encoder(level: i64 = ZSTD_DEFAULT_LEVEL) -> ZstdEncoder {
    assert(level >= 1 && level <= ZSTD_MAX_LEVEL);
    return ZstdEncoder { level: level, check: Xxh64 { .. }, .. };
}

// Starts e over as a new stream, as zstd_encoder(level) would make it.
fn reset(e: ZstdEncoder&, level: i64 = ZSTD_DEFAULT_LEVEL) {
    assert(level >= 1 && level <= ZSTD_MAX_LEVEL);
    e.level = level;
    e.started = false;
    e.finished = false;
    xxh64_reset(e.check);
    e.fill = 0;
}

fn write(e: ZstdEncoder&, data: const u8[:], out: u8[>..]&) {
    assert(!e.finished);
    zstd_header(e, out);
    xxh64_update(e.check, data);
    var at = 0;
    while at < data.len {
        if e.fill == ZSTD_BLOCK_MAX {
            zstd_block(out, e.buf, false);
            e.fill = 0;
        }
        let take = min(ZSTD_BLOCK_MAX - e.fill, data.len - at);
        copy_into(e.buf[e.fill..e.fill + take], data[at..at + take]);
        e.fill += take;
        at += take;
    }
}

// Ends the output so far on a block, so a reader can decompress all the input
// written so far. zstd blocks end on a byte boundary, so nothing else is
// needed. The stream continues after it.
fn flush(e: ZstdEncoder&, out: u8[>..]&) {
    assert(!e.finished);
    zstd_header(e, out);
    if e.fill > 0 {
        zstd_block(out, e.buf[..e.fill], false);
        e.fill = 0;
    }
}

// Ends the stream: the held input as the last block, then the checksum.
fn finish(e: ZstdEncoder&, out: u8[>..]&) {
    assert(!e.finished);
    zstd_header(e, out);
    zstd_block(out, e.buf[..e.fill], true);
    e.fill = 0;
    put_le32(out, xxh64_digest(e.check) as! u32);
    e.finished = true;
}

fn zstd_header(e: ZstdEncoder&, out: u8[>..]&) {
    guard !e.started else { return; }
    e.started = true;
    // The magic number; a descriptor with only the checksum flag, so no
    // content size or dictionary and a window descriptor follows; a window of
    // 2^(10 + 7) bytes, ZSTD_BLOCK_MAX.
    out.append([0x28, 0xB5, 0x2F, 0xFD, 0x04, 7 << 3]);
}

// One block of data: one repeated byte as an RLE block, the rest raw.
fn zstd_block(out: u8[>..]&, data: const u8[:], last: bool) {
    assert(data.len <= ZSTD_BLOCK_MAX);
    var kind = if data.len > 1 { ZSTD_RLE } else { ZSTD_RAW };
    for b in data {
        if b != data[0] {
            kind = ZSTD_RAW;
            break;
        }
    }
    let h = (data.len << 3 | kind << 1 | (if last { 1 } else { 0 })) as! u32;
    out.append([h as! u8, (h >> 8) as! u8, (h >> 16) as! u8]);
    if kind == ZSTD_RLE {
        out.push(data[0]);
    } else {
        out.append(data);
    }
}
