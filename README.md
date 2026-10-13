# goose-compress

Compression package for [Goose](https://github.com/aardappel/goose): gzip, zlib, raw
DEFLATE, and zstd encoders, bytes in and bytes out, with a streaming encoder that
flushes. Pure
Goose, with no C ([architecture](docs/architecture/README.md)). Its first user is
[goose-http](https://github.com/kaitk/goose-http), which compresses responses with it.

For DEFLATE, level 1 finds LZ77 matches with one hash probe a position; levels 2 to 9
search hash chains, and from level 5 match lazily, after libdeflate's design. Each block
is coded with a dynamic Huffman code built from it, the fixed code, or stored, whichever
is shortest. For zstd, levels 1 and 3 follow libzstd's fast and double-fast matchers,
and each block's literals and sequences are coded with tables chosen for it.

## Status

🟢 works · 🟡 partial or next · 🔴 not yet

| | Encoding | Notes |
|---|---|---|
| 🟢 | gzip | LZ77 with dynamic Huffman codes, levels 0 to 9. 1.05 to 1.7 times slower than zlib-ng and libdeflate at levels 1 and 6 on an M1 Pro, 1.2 to 2.3 times on a Ryzen ([results](docs/results.md)). |
| 🟢 | zlib (HTTP's `deflate`) | The same DEFLATE stream as gzip, with the zlib header and Adler-32. |
| 🟢 | Raw DEFLATE | The same stream with no wrapper. |
| 🟢 | zstd | Levels 1 and 3, libzstd's fast and double-fast matchers, into compressed blocks with Huffman literals and FSE tables chosen per block; levels 2 and up run level 3. Silesia comes to 0.3378 of its size at level 1 and 0.3251 at level 3, against libzstd's 0.3455 and 0.3121. 2.0 to 3.2 times slower than libzstd and 1.6 to 1.9 times slower than klauspost/compress on six files of seven, on an M1 Pro ([results](docs/results.md#zstd-levels-1-and-3-at-237de3a)); speed is still being improved. |
| 🔴 | Brotli | Out of scope: HTTP servers serve it precompressed (task 002). |
| 🔴 | Decoding | Out of scope for now. |

| | Feature |
|---|---|
| 🟢 | One-shot `compress` |
| 🟢 | Streaming `write`, `flush` (as zlib's `Z_SYNC_FLUSH`), and `finish` |
| 🟢 | CRC-32, Adler-32, and XXH64, continuing across calls |
| 🟢 | DEFLATE levels: 0 stores, 1 probes once, 2 to 4 search chains greedily, 5 to 9 lazily |
| 🟢 | zstd levels: 1 runs the fast matcher, 2 to 22 the double-fast one |

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

    var zs: u8[>..] = [];
    compress::compress("hello, hello, hello", zs, compress::ZSTD, 3);   // one zstd frame
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
  `deflate`), `compress::RAW` (RFC 1951 alone), and `compress::ZSTD` (RFC 8878).
- **Levels**: 0 stores; 1 to 9 compress, each smaller and slower than the one before,
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
  chains, and a 64 KB block of symbols ([architecture](docs/architecture/README.md)).
  Building one copies its arrays several times at the pinned compiler, about 145 µs on
  a Ryzen under Windows
  ([findings](docs/goose-findings.md#a-struct-literal-copies-each-nested-fixed-array-whole)),
  so build each slot once and reset it for each stream.
  - `compress::reset(e, format = GZIP, level = DEFAULT_LEVEL)`: starts `e` over as a
    new stream, as `encoder` would make it, by zeroing it in place. `compress` of 100
    bytes, which resets, takes 7.3 µs there.
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
  double-fast one, level 3's, which writes 3.8 percent less on Silesia, and is 2 to
  24 percent slower on six of seven files and 80 percent slower on `x-ray`. Each
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
  input's XXH64. A `ZstdEncoder` is a fixed-size value of 879,875 bytes: the window,
  a 128 KB block, and 32 KB to slide by, hash tables of 128 KB and, for level 3,
  256 KB, 128 KB of sequences and 48 KB of their codes, and 11 KB of FSE tables. Its
  `reset` clears nothing large: a stream starts out of the hash tables' reach, and
  they're cleared after 2 GB of streams, counting 128 KB more for each
  ([architecture](docs/architecture/README.md)). `compress` of 100 bytes takes 2.5 µs at
  level 1 and 2.6 µs at level 3 on an M1 Pro.
- **`compress::crc32(crc, data)`** and **`compress::adler32(adler, data)`**: the
  checksums, continuing from a previous value. Start CRC-32 at 0 and Adler-32 at 1.
  **`compress::xxh64(data)`** is XXH64 with seed 0; `compress::Xxh64 { .. }`,
  `xxh64_update`, and `xxh64_digest` compute it across calls.

## Benchmarks

The package is measured against libdeflate, zlib-ng, and libzstd, built in release
mode, and klauspost/compress in Go. Each machine's full tables, setup, and method are in
[docs/results.md](docs/results.md), and each change's measurements in
[results-history.md](docs/results-history.md).

gzip on a Ryzen 7 5800X3D under Windows 11, at `6b57c40`, over seven Silesia files[^1]:

| Level | goose MB/s | libdeflate MB/s | zlib-ng MB/s | goose vs libdeflate | goose output vs libdeflate's |
|---:|---:|---:|---:|---:|---:|
| 0 | 2,639–2,833 | 12,859–19,144 | 14,214–17,252 | 4.9–7.0× slower[^2] | stored |
| 1 | 139–386 | 164–651 | 157–888 | 1.17–1.69× slower | +0.6% to +20.3% |
| 6 | 49–130 | 73–237 | 67–214 | 1.48–1.82× slower | +0.1% to +4.3% |
| 9 | 19–67 | 31–102 | 27–80 | 1.37–2.07× slower | +0.1% to +4.5% |

[^1]: One-shot, the whole file in memory; each file's rate is the median of 10 runs, and
    a cell gives the range over the seven files. DEFLATE speed is still being tuned:
    task 005 ([tasks/005-parity.md](tasks/005-parity.md)) ports libdeflate's matcher to
    reach its rate, and these numbers will change with it.
[^2]: The level 0 gap is CRC-32, which both libraries compute with a carryless multiply
    that Goose can't express
    ([findings](docs/goose-findings.md#goose-has-no-carryless-multiply)).

zstd on an M1 Pro, at `237de3a`, against libzstd v1.5.7 and klauspost/compress v1.20.3,
all with the checksum[^3]:

| Level | goose MB/s | goose vs libzstd | goose vs klauspost | Output, 12 Silesia files |
|---:|---:|---:|---:|---|
| 1 | 132–600 | 2.3–3.2× slower | 1.6–1.7× slower | 2.2% smaller than libzstd's, 2.9% than klauspost's |
| 3 | 114–430 | 1.7–2.3× slower | 1.4–1.9× slower | 4.2% larger than libzstd's (2.3% smaller at its 128 KB window) |

[^3]: Rates on six of seven files; on `x-ray` at level 1, 1.2 and 3.8 times slower.
    zstd's speed is still being tuned: on `webster` at level 1 the coding takes 4.3
    times libzstd's time a byte and the matcher 2.1 times
    ([profile](docs/results-history.md#zstd-against-libzstd-and-klauspost-task-004-step-6)).
    zstd hasn't been measured on the Ryzen yet.

## Credits

No code is adopted from another encoder. The package follows these designs, and
[docs/credits.md](docs/credits.md) names what it takes from each:

| Source | What the package follows |
|---|---|
| zlib, RFCs 1950 to 1952 | CRC-32 table, Adler-32's `NMAX`, block size and type choice, 15-bit code limit, header level fields, sync flush |
| Moffat and Katajainen (1995) | Optimal Huffman code lengths, computed in place |
| [libdeflate](https://github.com/ebiggers/libdeflate) | Hash-chain search, lazy matching, each level's parameters, 8-byte symbol stores |
| [libzstd](https://github.com/facebook/zstd) | zstd levels 1 and 3 (`ZSTD_fast`, `ZSTD_dfast`), literals, FSE tables |
| [klauspost/compress](https://github.com/klauspost/compress) | zstd level 1's 6-byte hash and table size |
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
test/                unit tests, and encode.goose, which scripts/roundtrip.py drives
scripts/             test scripts
bench/               the C harness for libdeflate, zlib-ng, and libzstd, the Go one for
                     klauspost/compress, the Goose one, and scripts
docs/                architecture, development setup, results, Goose findings, credits
tasks/               task tracking (tasks/README.md)
```

## Pins

| What | Pin | Why |
|---|---|---|
| Goose compiler | `aardappel/goose` `a6249a4` (`master`, 2026-10-12) | The language and stdlib change often |
| Benchmark libraries | libdeflate v1.26, zlib-ng 2.3.3, and libzstd v1.5.7 in `bench/build.sh`; klauspost/compress v1.20.3 in `bench/klauspost/go.mod` | Each result names the versions it ran against |

Move the pin in its own commit, with the tests and results that still hold
([development.md](docs/development.md#move-the-pin)).
