# goose-compress

Compression package for [Goose](https://github.com/aardappel/goose): gzip, zlib, raw
DEFLATE, and zstd encoders, bytes in and bytes out, with a streaming encoder that
flushes. Pure
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
| 🟢 | gzip | LZ77 with dynamic Huffman codes, levels 0 to 9. 1.05 to 1.7 times slower than zlib-ng and libdeflate at levels 1 and 6 on an M1 Pro, 1.2 to 2.3 times on a Ryzen ([results](docs/results.md)). |
| 🟢 | zlib (HTTP's `deflate`) | The same DEFLATE stream as gzip, with the zlib header and Adler-32. |
| 🟢 | Raw DEFLATE | The same stream with no wrapper. |
| 🟡 | zstd | Levels 1 and 3, libzstd's fast and double-fast matchers, into compressed blocks with Huffman literals and FSE tables chosen per block; levels 2 and up run level 3. Silesia comes to 0.3378 of its size at level 1 and 0.3251 at level 3, against `zstd -1`'s 0.3457 and `zstd -3`'s 0.3124. Speed against libzstd is next (task 004). |
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

Against libdeflate and zlib-ng, built in release mode: [docs/results.md](docs/results.md).
On an M1 Pro, with seven Silesia files, at `ce13855`:

- Level 0 stores at 2.8 GB/s (on `dickens` and `x-ray`), against zlib-ng's 7 GB/s and
  libdeflate's 21-32 GB/s.
  The gap is CRC-32, which both libraries compute with a carryless multiply that Goose
  can't express ([findings](docs/goose-findings.md#goose-has-no-carryless-multiply)).
- Level 1 compresses 120-393 MB/s, 1.05 to 1.5 times slower than zlib-ng and 1.2 to
  1.5 times slower than libdeflate. Its output is smaller than zlib-ng's on all seven
  files and 0.5 to 20 percent larger than libdeflate's.
- Level 6 compresses 46-127 MB/s, 1.25 to 1.7 times slower than zlib-ng and 1.4 to
  1.7 times slower than libdeflate, and faster than zlib-ng on `x-ray` (73 MB/s
  against 65). Its output is smaller than zlib-ng's on five files, the same on one,
  and 1 percent larger on `xml`; it's 0 to 4 percent larger than libdeflate's.

On a Ryzen 7 5800X3D under Windows, with the same files and output, at `43cb937`:

- Level 1 compresses 130-379 MB/s, 1.2 to 2.3 times slower than zlib-ng and 1.2 to
  1.7 times slower than libdeflate.
- Level 6 compresses 48-124 MB/s, 1.2 to 1.7 times slower than zlib-ng and 1.6 to 2.0
  times slower than libdeflate.
- Level 0 zlib output, a copy and Adler-32 as a `simd fn` in AVX2, runs at 10-15 GB/s,
  against zlib-ng's 20-43 GB/s and libdeflate's 16-25 GB/s.

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
prefetch does, and carrying that position's hash to the next search, as its
`next_hashes` do; and coding a block's symbols with 8-byte stores. XXH64 follows
its specification in the xxHash repository (`Cyan4973/xxHash`, `doc/xxhash_spec.md`). CRC-32 by
slice-by-16 is the common table method, not either library's. zstd's level 1 follows
libzstd's `ZSTD_fast` (`facebook/zstd`): two positions probed a step, the last offset
checked first, one byte of backward extension for it, the step that grows with the
distance from the last match, the two positions it hashes after a match, and the
offset before last tried at once; and its blocks of at most 128 KB matched whole, as
its streaming API buffers them. The 6-byte hash and the 2^15-entry table are
klauspost's `enc_fast.go` (`klauspost/compress`). Level 3 follows libzstd's
`ZSTD_dfast` (`zstd_double_fast.c`) with its parameters for inputs up to 128 KB: a
2^16-entry table of 8-byte hashes and a 2^15-entry table of 5-byte ones, each
position checking the last offset one position on, then the long match, then the
short one, which gives way to a longer long match at the next position; the step
that grows by one every 256 bytes; and the four positions it hashes after a match.
From libzstd's literals: one
Huffman stream below 256 literals and four above, the guess that skips building a code
for literals with no byte more common than 1/128 of them (`HUF_compress_internal`),
counting bytes into 4 tables (`HIST_count_parallel`), and the weights' FSE accuracy of
5 (`FSE_optimalTableLog`). From its sequences: the FSE coding table's form, a state
table and two deltas a symbol (`FSE_buildCTable`), each table's accuracy
(`FSE_optimalTableLog` again), and probabilities "less than 1" only in blocks of 2,048
sequences and more (`ZSTD_useLowProbCount`); choosing each table by its estimated
bits, where libzstd's fast levels use rules of thumb, is this package's. The block
format, the predefined FSE tables, the Huffman weights, and the bitstreams' order
come from RFC 8878.

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
bench/               the C harness for libdeflate and zlib-ng, the Goose one, and scripts
docs/                architecture, development setup, results, Goose findings
tasks/               task tracking (tasks/README.md)
```

## Pins

| What | Pin | Why |
|---|---|---|
| Goose compiler | `aardappel/goose` `a6249a4` (`master`, 2026-10-12) | The language and stdlib change often |

Move the pin in its own commit, with the tests and results that still hold
([development.md](docs/development.md#move-the-pin)).
