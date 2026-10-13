# 004: zstd

Status: in-progress

A Zstandard encoder (RFC 8878) in Goose, in this package, for HTTP's `Content-Encoding:
zstd` (RFC 9659): Chrome since 123 and Firefox since 126 accept it, and Safari partly
from 26.3. Task 001 is measured, which is what the architecture doc waited on. As in
task 001, each step gives output `zstd -d` and Python's `compression.zstd` accept, so
goose-http can negotiate `zstd` after step 1 (requested 2026-10-12).

## What others do

Read on 2026-10-12, to choose what to build first:

- **libzstd** (`facebook/zstd`, `lib/compress/clevels.h`). Level 1 is `ZSTD_fast`:
  one hash table of 2^14 entries, a 7-byte hash, and a 512 KB window. Level 3, its
  default, is `ZSTD_dfast`: two tables, of 8-byte and 5-byte hashes, and a 2 MB
  window. Levels 5 and up search chains or binary trees. Below 16 KB of input, levels
  1 to 6 take a 16 KB window and hash 4 or 5 bytes. Its API leaves the checksum
  off; its command line turns it on.
- **klauspost/compress** (Go, no assembly needed). The closest model for a package in
  a language other than C. Four levels, roughly zstd's 1, 3, 7, and 11. Its fastest
  encoder (`enc_fast.go`) probes a table of 2^15 entries of 6-byte hashes, at two
  positions a step, checks the last offset first, extends matches backward, and steps
  faster the longer it goes without a match (`kSearchStrength` 6). On Silesia it
  writes 73.8 MB in 634 ms against libzstd level 1's 73.6 MB in 543 ms: within 17
  percent of C. Its default level is 3.5 times slower than libzstd's.
- **ruzstd** (Rust): an encoder with a `Fastest` level near zstd's 1, which says it
  doesn't yet reach libzstd's speed or ratio. **zrip** claims to be the fastest
  pure-Rust encoder, levels -7 to 4, on its own benchmarks.
- **Zig's std** and **Odin's `core:compress`** decode zstd but don't encode it. Tina,
  goose-http's Odin comparison, compresses nothing on the fly.

What every encoder outside C does: levels 1 and 3 first, as zstd's fast and double-fast
matchers, Huffman literals and FSE sequences built per block, and higher levels only
after those are measured. This task follows that order.

## Proposed decisions

Recorded in `docs/architecture/README.md`. Step 1 settled all but the window and the
levels; step 2 kept the 128 KB window, and the levels stay proposed:

- **`compress::ZSTD` is a fourth format for `compress`**, so goose-http picks an
  encoding with one argument. The stream is a `ZstdEncoder` of its own, with
  overloads of `reset`, `write`, `flush`, and `finish`, because its window and tables
  differ in size from DEFLATE's, and one `Encoder` holding both would make every gzip
  slot pay for zstd's.
- **A fixed window, declared in the frame header**, not libzstd's 512 KB: the
  `ZstdEncoder` is a fixed-size value, one per connection slot. Step 1 declares
  128 KB, the largest block. Step 2 measures the ratio against memory for 128 KB to
  512 KB. RFC 9659 caps HTTP's window at 8 MB.
- **`flush` ends the current block, and writes nothing else.** zstd blocks end on a
  byte boundary, so a reader can decode everything up to the last block whole, with no
  marker like DEFLATE's empty stored block.
- **The content checksum is on**: the low 32 bits of XXH64, as the zstd command line
  and klauspost's encoder write it. The benchmark turns it on in libzstd too
  (`ZSTD_c_checksumFlag`).
- **No frame content size**, so `compress` and an unflushed stream give the same bytes,
  as for DEFLATE.
- **Levels named after zstd's.** Level 1 is the fast matcher and 3, the default, the
  double-fast. Others wait on a measurement.

## Steps

1. The frame: the header with its window, raw blocks of up to 128 KB (RLE where a
   block is one repeated byte), the last-block flag, and the XXH64 checksum. A
   streaming `ZstdEncoder` with `flush` and `finish`.
2. Compressed blocks: level 1 matching (a hash of 6 bytes, one probe, the repeat
   offsets checked first) into sequences, coded with the predefined FSE tables, with
   the literals raw.
3. Huffman-coded literals: one stream below 256 bytes, four above, with tables built
   from the block, or raw where that's shorter.
4. FSE tables built from each block's counts, or predefined, RLE, or repeated,
   whichever is shortest.
5. Level 3: double-fast matching.
6. Speed against libzstd at levels 1 and 3, and klauspost's at its fastest and default,
   with `bench/run.sh`.

## Acceptance criteria

- [x] Step 1: `compress::ZSTD` and `ZstdEncoder`, round trips through `zstd -d` and
      Python's `compression.zstd` on the inputs `scripts/roundtrip.py` covers, flushes
      included, and XXH64 checked against known values
- [x] Step 2: level 1 matches into compressed blocks, passing the same tests
- [ ] Step 3: Huffman literals, passing the same tests
- [ ] Step 4: FSE tables per block, passing the same tests, with a fuzz run
- [ ] Step 5: level 3, passing the same tests
- [ ] Step 6: libzstd built in `bench/` in release mode, and rate and ratio at levels
      1 and 3 recorded in `docs/results-history.md` with how they were measured
- [ ] Decisions above confirmed or replaced in `docs/architecture/README.md`, and the
      README's status table and API updated
- [ ] Findings recorded in `docs/goose-findings.md`

## Step 1

Done (2026-10-12). `compress::ZSTD` and `ZstdEncoder` write a frame with a 128 KB
window, raw blocks of up to 128 KB, RLE blocks for one repeated byte, and the XXH64
checksum. XXH64 matches the reference values for `""`, `"a"`, and `"abc"`, and a
Python port of the specification on 100 bytes. `scripts/roundtrip.py` checks zstd at
levels 1 and 3 on every input and plan, through `compression.zstd` and `zstd -dc`, in
the fuzz run too. The decisions it settles are in the architecture doc. There's no
speed to measure yet: the encoder copies its input and hashes it.

## Step 2

Done (2026-10-13). Level 1 is libzstd's `ZSTD_fast`, with a 2^15-entry table of
6-byte hashes, matching each 128 KB block once it's whole. Each block is compressed,
with raw literals and the predefined FSE tables, or written raw or RLE where that's no
larger. The window stays 128 KB: 256 KB and 512 KB made Silesia's output 1.4 and 2.0
percent smaller for 24 and 71 percent more memory. On the M1 Pro, the 12 Silesia files
come to 0.4246 of their size, against 0.4127 from `zstd -1 --no-compress-literals`
and 0.3457 from `zstd -1`. Rates are 169 to 560 MB/s on six of seven files, and 2.3
GB/s on `x-ray`, against step 1's 8.7 GB/s copy
([results](../docs/results-history.md#zstd-level-1-task-004-step-2)).
`scripts/roundtrip.py` holds each input to a zstd size limit, with inputs at the
window's edge and one that fills a block's 16,384 sequences. The unit tests check the
exact bytes of two compressed blocks, the second using a repeat offset.
