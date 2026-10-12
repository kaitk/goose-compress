# goose-compress

Compression package for [Goose](https://github.com/aardappel/goose): gzip, zlib, and raw
DEFLATE encoders, bytes in and bytes out, with a streaming encoder that flushes. Pure
Goose, with no C ([architecture](docs/architecture/README.md)). Its first user is
[goose-http](https://github.com/kaitk/goose-http), which compresses responses with it.

Level 1 finds LZ77 matches with one hash probe a position; levels 2 to 9 search hash
chains, and from level 5 match lazily, after libdeflate's design. Each block is coded
with a dynamic Huffman code built from it, the fixed code, or stored, whichever is
shortest.

## Status

🟢 works · 🟡 partial or next · 🔴 not yet

| | Encoding | Notes |
|---|---|---|
| 🟢 | gzip | LZ77 with dynamic Huffman codes, levels 0 to 9. 1.1 to 2.1 times slower than zlib-ng and libdeflate at levels 1 and 6 ([results](docs/results.md)). |
| 🟢 | zlib (HTTP's `deflate`) | The same DEFLATE stream as gzip, with the zlib header and Adler-32. |
| 🟢 | Raw DEFLATE | The same stream with no wrapper. |
| 🔴 | zstd | Later, in this package, once gzip is measured. |
| 🔴 | Brotli | Out of scope: HTTP servers serve it precompressed (task 002). |
| 🔴 | Decoding | Out of scope for now. |

| | Feature |
|---|---|
| 🟢 | One-shot `compress` |
| 🟢 | Streaming `write`, `flush` (as zlib's `Z_SYNC_FLUSH`), and `finish` |
| 🟢 | CRC-32 and Adler-32, continuing across calls |
| 🟢 | Compression levels: 0 stores, 1 probes once, 2 to 4 search chains greedily, 5 to 9 lazily |

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
- **Levels**: 0 stores; 1 to 9 compress, each smaller and slower than the one before,
  and `compress::DEFAULT_LEVEL` is 6, as zlib's. Each block is coded with a dynamic
  Huffman code, the fixed code, or stored, whichever is shortest, so incompressible
  input grows by about 5 bytes every 16 KB.
- **`compress::compress(data, out, format = GZIP, level = DEFAULT_LEVEL)`**: compresses
  `data` whole into one stream.
- **`compress::encoder(format = GZIP, level = DEFAULT_LEVEL)`**: a stream,
  `compress::Encoder`. It's a fixed-size value of 328,050 bytes, so it fits in an
  array of per-connection slots: a 64 KB window, a 128 KB hash table, 64 KB of hash
  chains, and a 64 KB block of symbols ([architecture](docs/architecture/README.md)).
  Building one is most of the 24 µs `compress` takes for 100 bytes on an M1 Pro, at the
  pinned compiler
  ([findings](docs/goose-findings.md#a-struct-literal-copies-each-nested-fixed-array-whole)).
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
On an M1 Pro, with seven Silesia files:

- Level 0 stores at 2.8 GB/s (on `dickens` and `x-ray`), against zlib-ng's 7 GB/s and
  libdeflate's 21-32 GB/s.
  The gap is CRC-32, which both libraries compute with a carryless multiply that Goose
  can't express ([findings](docs/goose-findings.md#goose-has-no-carryless-multiply)).
- Level 1 compresses 112-351 MB/s, 1.1 to 1.7 times slower than zlib-ng and 1.3 to
  1.7 times slower than libdeflate. Its output is smaller than zlib-ng's on all seven
  files and 1.3 to 20 percent larger than libdeflate's.
- Level 6 compresses 43-114 MB/s, 1.3 to 1.9 times slower than zlib-ng and 1.5 to
  2.1 times slower than libdeflate. Its output is smaller than zlib-ng's on five files,
  the same on one, and 1 percent larger on `xml`; it's 0 to 4 percent larger than
  libdeflate's.

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
competitors; when the package takes an idea from either, this section names it. From
libdeflate: hash chains searched newest first, with a candidate's 4 hashed bytes and
the byte at the best length compared before it's extended (`hc_matchfinder`); lazy
and lazy2 matching, with its measure of a better match; each level's search depth,
nice length, and lazy mode; loading the next position's hash bucket early, as its
prefetch does; and coding a block's symbols with 8-byte stores. CRC-32 by
slice-by-16 is the common table method, not either library's.

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
| Goose compiler | `aardappel/goose` `c38dc0f` (`master`, 2026-10-12) | The language and stdlib change often |

Move the pin in its own commit, with the tests and results that still hold
([development.md](docs/development.md#move-the-pin)).
