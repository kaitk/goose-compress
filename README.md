# goose-compress

Compression package for [Goose](https://github.com/aardappel/goose): gzip, zlib, raw
DEFLATE, and zstd encoders, bytes in and bytes out, with a streaming encoder that
flushes. The encoders are the package's own: Goose, with C for the loops where C
measures faster, which are CRC-32's carryless multiply, DEFLATE level 1's matcher,
and the Huffman symbol coder, each giving the Goose code's output byte for byte
([decisions](docs/decisions.md)). Its first user is
[goose-http](https://github.com/kaitk/goose-http), which compresses responses with it.

For DEFLATE, level 1 finds LZ77 matches in 2-entry hash buckets; levels 2 to 9
search hash chains, and from level 5 match lazily, after libdeflate's design. Each block
is coded with a dynamic Huffman code built from it, the fixed code, or stored, whichever
is shortest. For zstd, levels 1 and 3 follow libzstd's fast and double-fast matchers,
and each block's literals and sequences are coded with tables chosen for it.

## Status

🟢 works · 🟡 partial or next · 🔴 not yet

| | Encoding | Notes |
|---|---|---|
| 🟢 | gzip | LZ77 with dynamic Huffman codes, levels 0 to 9. See [benchmarks](#benchmarks) for measured rates and output sizes. |
| 🟢 | zlib (HTTP's `deflate`) | The same DEFLATE stream as gzip, with the zlib header and Adler-32. |
| 🟢 | Raw DEFLATE | The same stream with no wrapper. |
| 🟢 | zstd | Levels 1 and 3, libzstd's fast and double-fast matchers, with Huffman literals and FSE tables chosen per block; levels 2 to 22 run level 3. See [benchmarks](#benchmarks) for measured rates and output sizes. |
| 🔴 | Brotli | Out of scope: HTTP servers serve it precompressed (task 002). |
| 🔴 | Decoding | Out of scope for now. |

| | Feature |
|---|---|
| 🟢 | One-shot `compress` |
| 🟢 | Streaming `write`, `flush` (as zlib's `Z_SYNC_FLUSH`), and `finish` |
| 🟢 | CRC-32, Adler-32, and XXH64, continuing across calls |
| 🟢 | DEFLATE levels: 0 stores, 1 tries 2 candidates, 2 to 4 search chains greedily, 5 to 9 lazily |
| 🟢 | zstd levels: 1 runs the fast matcher, 2 to 22 the double-fast one |

## Quick start

```goose
import std;
import compress from "github.com/kaitk/goose-compress@v0.1.4";

fn main() {
    var gz: u8[>..] = [];
    compress::compress("hello, hello, hello", gz);   // one gzip stream

    var e = compress::encoder(compress::ZLIB);
    var out: u8[>..] = [];
    compress::write(e, "first chunk", out);
    compress::flush(e, out);    // out now decompresses to "first chunk"
    compress::write(e, "second chunk", out);
    compress::finish(e, out);

    var zs: u8[>..] = [];
    compress::compress("hello, hello, hello", zs, compress::ZSTD, 3);   // one zstd frame
}
```

```sh
goose build hello.goose
```

The tag `v0.1.4` has everything in the tables above. The package needs no other
package. Its C, in `shim/`, is built through `compress.build` by the C compiler
`goose build` already uses, and CPUs without a carryless multiply take CRC-32's Goose
tables ([decisions](docs/decisions.md)).

## API

All in namespace `compress`. Output is appended to a `u8[>..]` the caller owns.

- **Formats**: `compress::GZIP` (RFC 1952), `compress::ZLIB` (RFC 1950, HTTP's
  `deflate`), `compress::RAW` (RFC 1951 alone), and `compress::ZSTD` (RFC 8878).
- **DEFLATE levels**: 0 stores; 1 to 9 compress, with higher levels searching more
  candidates and using lazy matching from level 5,
  and `compress::DEFAULT_LEVEL` is 6, as zlib's. Each block is coded with a dynamic
  Huffman code, the fixed code, or stored, whichever is shortest, so incompressible
  input grows by about 5 bytes every 16 KB.
- **`compress::compress(data, out, format = GZIP, level = DEFAULT_LEVEL)`**: compresses
  `data` whole into one stream. It reuses one encoder for each program instance (each
  thread program has its own), built at the first call, so the program holds its
  460,406 bytes from then on.
- **`compress::encoder(format = GZIP, level = DEFAULT_LEVEL)`**: a stream,
  `compress::Encoder`. It's a fixed-size value of 460,406 bytes, so it fits in an
  array of per-connection slots: a 64 KB window, a 256 KB hash table, 64 KB of hash
  chains, and a 64 KB block of symbols ([architecture](docs/architecture.md#formats-and-the-api)).
  Building one copies its arrays several times at the pinned compiler, about 145 µs on
  a Ryzen under Windows
  ([findings](docs/goose-findings.md#a-struct-literal-copies-each-nested-fixed-array-whole)),
  so build each slot once and reset it for each stream.
  - `compress::reset(e, format = GZIP, level = DEFAULT_LEVEL)`: starts `e` over as a
    new stream, in place, which codes as one from `encoder` would. It clears nothing
    large: a stream starts out of the hash tables' reach, and they're cleared after
    2 GB of streams, counting 32 KB more for each ([decisions](docs/decisions.md)).
    `compress` of 100 bytes, which resets, took 7.3 µs there at `v0.1.1`.
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
- **`compress::zstd_encoder(level = 3)`**: a zstd stream, `compress::ZstdEncoder`,
  with zstd's levels 1 to 22. Level 1 runs libzstd's fast matcher, and 2 and up its
  double-fast one, level 3. Each
  block's literals are Huffman coded from its counts, RLE, or raw, whichever is
  shortest, and its sequences' three kinds of codes each coded with an FSE table
  built from the block's counts, the predefined table, an RLE table, or the last
  block's table repeated, whichever is shortest. A block is compressed where that's
  smaller, else raw, or RLE for one repeated byte.
  `compress::compress(data, out, compress::ZSTD, level)` takes the same levels. It
  overloads `reset(e, level)`, `write`, `flush`, and `finish`, which keep the contracts
  above, except that `flush` writes the input held as blocks and nothing
  more: zstd blocks end on a byte boundary. Tables repeat across flushes, and `reset`
  starts a frame with none. The frame declares a 128 KB window, which
  matches reach across writes and flushes, and ends with the low 32 bits of the
  input's XXH64. A `ZstdEncoder` is a fixed-size value of 1,010,955 bytes: the window,
  a 128 KB block, and 32 KB to slide by, hash tables of 128 KB and, for level 3,
  256 KB, 128 KB of sequences, 128 KB of their literals, and 48 KB of their codes, and
  11 KB of FSE tables. Its
  `reset` clears nothing large: a stream starts out of the hash tables' reach, and
  they're cleared after 2 GB of streams, counting 128 KB more for each
  ([decisions](docs/decisions.md)). When the one-shot `compress` level is
  omitted, its default of 6 selects zstd's level-3 matcher.
- **`compress::crc32(crc, data)`** and **`compress::adler32(adler, data)`**: the
  checksums, continuing from a previous value. Start CRC-32 at 0 and Adler-32 at 1.
  **`compress::xxh64(data)`** is XXH64 with seed 0; `compress::Xxh64 { .. }`,
  `xxh64_update`, and `xxh64_digest` compute it across calls.

## Benchmarks

The package is measured against libdeflate, zlib-ng, and libzstd, built in release
mode, and klauspost/compress in Go. Each machine's full tables, setup, and method are in
[docs/results.md](docs/results.md), and each change's measurements in
[results-history.md](docs/results-history.md).

gzip on a Ryzen 7 5800X3D under Windows 11, at `v0.1.1` built by Goose `v2026.2`,
over seven Silesia files[^1]:

| Level | goose | libdeflate | zlib-ng | goose / libdeflate rate | goose output vs libdeflate's |
|---:|---:|---:|---:|---:|---:|
| 0 | 2.7–2.9 GB/s | 13–20 GB/s | 15–17 GB/s | 0.14–0.20[^2] | stored |
| 1 | 100–370 MB/s | 160–650 MB/s | 160–900 MB/s | 0.57–0.65 | −0.1% to +0.2% |
| 6 | 65–200 MB/s | 74–240 MB/s | 67–215 MB/s | 0.72–0.88 | +0.1% to +4.3% |
| 9 | 31–83 MB/s | 30–103 MB/s | 27–80 MB/s | 0.80–1.12 | +0.1% to +4.5% |

[^1]: One-shot, the whole file in memory; a cell gives the range over the seven files,
    each file's median of 10 runs. Level 9 matches or beats libdeflate's rate on six
    files of seven; level 1 writes libdeflate's sizes but runs at 0.57 to 0.65 of its
    rate.
[^2]: The level 0 gap is CRC-32, which both libraries compute with a carryless multiply
    that Goose can't express
    (see the compiler findings linked below).

zstd on the same Ryzen, at `v0.1.1`, against libzstd v1.5.7 and klauspost/compress
v1.20.3, all with the checksum, over the same seven files[^3]:

| Level | goose | libzstd | klauspost | goose / libzstd rate | goose output vs libzstd's |
|---:|---:|---:|---:|---:|---:|
| 1 | 250–800 MB/s | 360–1,020 MB/s | 210–2,320 MB/s | 0.70–0.95 | +0.0% to +12.1% |
| 3 | 150–680 MB/s | 150–820 MB/s | 150–610 MB/s | 0.78–1.04 | +2.6% to +12.8%[^4] |

[^3]: The median of 10 runs. klauspost's 2,320 MB/s is `x-ray`, whose literals it
    leaves raw; on the other six files it's at most 660 MB/s.
[^4]: libzstd's level 3 window is 2 MB, the package's 128 KB. Against libzstd at 128 KB,
    the package's output is 5.7 percent smaller to 0.4 percent larger.

The [compiler findings](docs/goose-findings.md#goose-has-no-carryless-multiply)
explain the CRC-32 limitation. Further performance work is tracked in
[task 005](tasks/005-parity.md).

## Credits

No code is adopted from another encoder. The package follows these designs, and
[docs/credits.md](docs/credits.md) names what it takes from each:

| Source | What the package follows |
|---|---|
| zlib, RFCs 1950 to 1952 | CRC-32 table, Adler-32's `NMAX`, block size and type choice, 15-bit code limit, header level fields, sync flush |
| Moffat and Katajainen (1995) | Optimal Huffman code lengths, computed in place |
| [libdeflate](https://github.com/ebiggers/libdeflate) | Hash-chain search, lazy matching, each level's parameters, 8-byte symbol stores |
| [libzstd](https://github.com/facebook/zstd) | zstd levels 1 and 3 (`ZSTD_fast`, `ZSTD_dfast`), literals, FSE tables |
| [klauspost/compress](https://github.com/klauspost/compress) | zstd level 1's 6-byte hash |
| xxHash specification | XXH64 |
| RFC 8878 | zstd's block format, predefined tables, and bitstream order |

libdeflate and [zlib-ng](https://github.com/zlib-ng/zlib-ng) are the benchmark's DEFLATE
competitors, and libzstd and klauspost/compress its zstd ones.

## Layout

```text
compress.goose       the package's entry: formats, the one-shot and streaming encoders
deflate.goose        the DEFLATE stream at levels 1 and up: LZ77, the bit writer, blocks
huffman.goose        length-limited Huffman codes, for dynamic blocks and zstd's literals
zstd.goose           the zstd frame, level 1 and 3 matching, and compressed blocks
zstd_literals.goose  a zstd block's literals: Huffman coded, RLE, or raw
zstd_fse.goose       zstd's FSE tables, normalized counts, and table descriptions
checksum.goose       CRC-32, Adler-32, and XXH64
compress.build       the C that goose build compiles: shim/
shim/                crc32.c, CRC-32 on the carryless multiply; deflate.c, level 1's
                     matcher and the symbol coder
test/                unit tests, and encode.goose, which scripts/roundtrip.py drives
scripts/             test scripts
bench/               the C harness for libdeflate, zlib-ng, and libzstd, the Go one for
                     klauspost/compress, the Goose one, and scripts
docs/                architecture, decisions, development setup, results, Goose findings,
                     credits
tasks/               task tracking (tasks/README.md)
```

## Pins

| What | Pin | Why |
|---|---|---|
| Goose compiler | `aardappel/goose` release `v2026.3` (`8511ae3`), which the scripts fetch ([setup](docs/development.md#set-up-the-goose-compiler)) | An official release builds the same on every platform; a commit is pinned only for a fix not yet released. `v2026.1` is `46356c2` plus the release packaging and where the compiler looks for its packages and the macOS SDK, so results at `46356c2` stand |
| Benchmark libraries | libdeflate v1.26, zlib-ng 2.3.3, and libzstd v1.5.7 in `bench/build.sh`; klauspost/compress v1.20.3 in `bench/klauspost/go.mod` | Each result names the versions it ran against |

Move the pin in its own commit, with the tests and results that still hold
([development.md](docs/development.md#move-the-pin)).

## License

Licensed under either of the [Apache License, Version 2.0](LICENSE-APACHE) or the
[MIT license](LICENSE-MIT), at your option. Unless you state otherwise, any
contribution you submit for inclusion, as defined in the Apache-2.0 license, is
licensed the same way, without any additional terms or conditions.
