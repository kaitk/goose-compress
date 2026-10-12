# goose-compress

Compression package for [Goose](https://github.com/aardappel/goose): gzip, zlib, and raw
DEFLATE encoders, bytes in and bytes out, with a streaming encoder that flushes. Pure
Goose, with no C ([architecture](docs/architecture/README.md)). Its first user is
[goose-http](https://github.com/kaitk/goose-http), which compresses responses with it.

Early work: at levels 1 and up, the encoder finds LZ77 matches with one hash probe a
position and codes each block with a dynamic Huffman code built from it, the fixed
code, or stored, whichever is shortest. Speed and a stronger level come next (task
001).

## Status

🟢 works · 🟡 partial or next · 🔴 not yet

| | Encoding | Notes |
|---|---|---|
| 🟡 | gzip | LZ77 with dynamic Huffman codes. Speed and lazy matching next (task 001). |
| 🟡 | zlib (HTTP's `deflate`) | The same DEFLATE stream as gzip, with the zlib header and Adler-32. |
| 🟡 | Raw DEFLATE | The same stream with no wrapper. |
| 🔴 | zstd | Later, in this package, once gzip is measured. |
| 🔴 | Brotli | Out of scope: HTTP servers serve it precompressed (task 002). |
| 🔴 | Decoding | Out of scope for now. |

| | Feature |
|---|---|
| 🟢 | One-shot `compress` |
| 🟢 | Streaming `write`, `flush` (as zlib's `Z_SYNC_FLUSH`), and `finish` |
| 🟢 | CRC-32 and Adler-32, continuing across calls |
| 🟡 | Compression levels: 0 stores, and 1 to 9 all match greedily for now |

## Quick start

```goose
import std;
import compress from "github.com/kaitk/goose-compress@<commit>";

fn main() {
    var gz: u8[>..] = [];
    compress::compress("hello, hello, hello", gz);   // one gzip stream

    var e = compress::encoder(compress::ZLIB);
    var out: u8[>..] = [];
    compress::write(e, "first chunk", out);
    compress::flush(e, out);    // out now decompresses to "first chunk"
    compress::write(e, "second chunk", out);
    compress::finish(e, out);
}
```

```sh
goose build hello.goose
```

No tag yet; pin a commit. The package needs no C compiler of its own and no other
package.

## API

All in namespace `compress`. Output is appended to a `u8[>..]` the caller owns.

- **Formats**: `compress::GZIP` (RFC 1952), `compress::ZLIB` (RFC 1950, HTTP's
  `deflate`), and `compress::RAW` (RFC 1951 alone).
- **Levels**: 0 stores; 1 to 9 compress, and `compress::DEFAULT_LEVEL` is 6, as zlib's.
  Every level from 1 compresses the same way until task 001's step 4 adds a stronger
  one. Each block is coded with a dynamic Huffman code, the fixed code, or stored,
  whichever is shortest, so incompressible input grows by about 5 bytes every 16 KB.
- **`compress::compress(data, out, format = GZIP, level = DEFAULT_LEVEL)`**: compresses
  `data` whole into one stream.
- **`compress::encoder(format = GZIP, level = DEFAULT_LEVEL)`**: a stream,
  `compress::Encoder`. It's a fixed-size value of 262,484 bytes, so it fits in an
  array of per-connection slots: a 64 KB window, a 128 KB hash table, and a 64 KB
  block of symbols ([architecture](docs/architecture/README.md)).
  - `compress::write(e, data, out)`: compresses `data` into the stream. It appends whole
    blocks and holds the rest, so `out` may grow by nothing.
  - `compress::flush(e, out)`: appends everything written so far, then an empty stored
    block (`00 00 00 ff ff`), as zlib's `Z_SYNC_FLUSH`. A reader can then decompress all
    of it. The stream goes on.
  - `compress::finish(e, out)`: appends the rest and the trailer. The stream is done.
  - The bytes of a stream depend on its input and where it was flushed, not on how
    the input was split across `write` calls. A stream that isn't flushed gives the
    same bytes as `compress`.
  - Matches reach back 32,768 bytes, across writes and flushes.
- **`compress::crc32(crc, data)`** and **`compress::adler32(adler, data)`**: the
  checksums, continuing from a previous value. Start CRC-32 at 0 and Adler-32 at 1.

## Benchmarks

Against libdeflate and zlib-ng, built in release mode: [docs/results.md](docs/results.md).
At level 0, where all three store, the package compresses about 345 MB/s on an M1 Pro,
against zlib-ng's 7.0-7.4 GB/s and libdeflate's 21-32 GB/s. The gap is CRC-32, which
both libraries compute with a carryless multiply that Goose can't express
([findings](docs/goose-findings.md#goose-has-no-carryless-multiply)). At level 1, with
dynamic Huffman codes, it compresses 60-146 MB/s on Silesia files, 2.1 to 3.9 times
slower than zlib-ng and libdeflate. Its output is smaller than zlib-ng's on all seven
files and 1.3 to 20 percent larger than libdeflate's.

## Credits

No code is adopted from another encoder. The CRC-32 table and Adler-32's 5,552-byte
run between reductions (zlib's `NMAX`) follow zlib and its RFCs. From zlib too: a block
of at most 16,384 symbols (its default memory level), the choice among stored, fixed,
and dynamic blocks by bit count with its tie-breaks, the way it limits code lengths to
15 bits and gives a code at least two symbols, the zlib header's `FLEVEL` and gzip's
`XFL` for each level, and the flush as `Z_SYNC_FLUSH`. The optimal code lengths come
from Moffat and Katajainen's in-place algorithm ("In-Place Calculation of
Minimum-Redundancy Codes", 1995). libdeflate
([ebiggers/libdeflate](https://github.com/ebiggers/libdeflate)) and zlib-ng
([zlib-ng/zlib-ng](https://github.com/zlib-ng/zlib-ng)) are the benchmark's
competitors; when the package takes an idea from either, this section names it.

## Layout

```text
compress.goose   the package's entry: formats, the one-shot and streaming encoders
deflate.goose    the DEFLATE stream at levels 1 and up: LZ77, the bit writer, blocks
huffman.goose    length-limited Huffman codes for dynamic blocks
checksum.goose   CRC-32 and Adler-32
test/            unit tests, and encode.goose, which scripts/roundtrip.py drives
scripts/         test scripts
bench/           the C harness for libdeflate and zlib-ng, the Goose one, and scripts
docs/            architecture, development setup, results, Goose findings
tasks/           task tracking (tasks/README.md)
```

## Pins

| What | Pin | Why |
|---|---|---|
| Goose compiler | `aardappel/goose` `5c83a5a` (`master`, 2026-10-12) | The language and stdlib change often |

Move the pin in its own commit, with the tests and results that still hold
([development.md](docs/development.md#move-the-pin)).
