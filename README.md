# goose-compress

Compression package for [Goose](https://github.com/aardappel/goose): gzip, zlib, and raw
DEFLATE encoders, bytes in and bytes out, with a streaming encoder that flushes. Pure
Goose, with no C ([architecture](docs/architecture/README.md)). Its first user is
[goose-http](https://github.com/kaitk/goose-http), which compresses responses with it.

Early work: the encoder stores its input in uncompressed blocks. The output is valid
gzip and zlib, but no smaller than the input yet (task 001).

## Status

🟢 works · 🟡 partial or next · 🔴 not yet

| | Encoding | Notes |
|---|---|---|
| 🟡 | gzip | Valid streams of stored blocks. LZ77 and Huffman coding next (task 001). |
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
| 🔴 | Compression levels: every level stores until task 001's step 2 |

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
- **`compress::compress(data, out, format = GZIP)`**: compresses `data` whole into one
  stream.
- **`compress::encoder(format = GZIP)`**: a stream, `compress::Encoder`. It's a
  fixed-size value, about 64 KB, so it fits in an array of per-connection slots.
  - `compress::write(e, data, out)`: compresses `data` into the stream. It appends whole
    blocks and holds the rest, so `out` may grow by nothing.
  - `compress::flush(e, out)`: appends everything written so far, then an empty stored
    block (`00 00 00 ff ff`), as zlib's `Z_SYNC_FLUSH`. A reader can then decompress all
    of it. The stream goes on.
  - `compress::finish(e, out)`: appends the rest and the trailer. The stream is done.
  - The bytes of a stream that isn't flushed don't depend on how its input was split
    across `write` calls.
- **`compress::crc32(crc, data)`** and **`compress::adler32(adler, data)`**: the
  checksums, continuing from a previous value. Start CRC-32 at 0 and Adler-32 at 1.

## Benchmarks

Against libdeflate and zlib-ng, built in release mode: [docs/results.md](docs/results.md).
At level 0, where all three store, the package compresses about 345 MB/s on an M1 Pro,
against zlib-ng's 7.0-7.4 GB/s and libdeflate's 21-32 GB/s. The gap is CRC-32, which
both libraries compute with a carryless multiply that Goose can't express
([findings](docs/goose-findings.md#goose-has-no-carryless-multiply)).

## Credits

Nothing is adopted from another encoder yet. The CRC-32 table and Adler-32's 5,552-byte
run between reductions (zlib's `NMAX`) follow zlib and its RFCs. libdeflate
([ebiggers/libdeflate](https://github.com/ebiggers/libdeflate)) and zlib-ng
([zlib-ng/zlib-ng](https://github.com/zlib-ng/zlib-ng)) are the benchmark's
competitors; when the package takes an idea from either, this section names it.

## Layout

```text
compress.goose   the package's entry: formats, the one-shot and streaming encoders
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
