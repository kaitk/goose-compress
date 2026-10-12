# 001: gzip and zlib

Status: in-progress (steps 1 and 2 done, 2026-10-12)

A DEFLATE encoder in Goose with the gzip and zlib wrappers, for goose-http's task 022
(its subtask 02, which points here). Each step gives output `gzip -d` accepts, so
goose-http can build its side after step 1. Correctness comes first, then speed: once
step 3 passes, step 4 aims for the same ballpark as libdeflate and zlib-ng at their
nearest levels, taking from their designs what Goose can express (requested
2026-10-12).

## Steps

1. Stored blocks: the gzip header, the input in uncompressed DEFLATE blocks of at most
   65,535 bytes, then CRC-32 and the length; the zlib wrapper with Adler-32; the
   streaming encoder with `flush` and `finish`.
2. LZ77 matching with one hash probe per position, coded with DEFLATE's fixed Huffman
   tables.
3. Dynamic Huffman tables per block, built from the block's symbol counts and limited
   to 15 bits.
4. Speed: a faster CRC-32 than one table lookup a byte (slice-by-8, or what `simd fn`
   can reach), a lazy-matching level beside the greedy one, matching taken from
   libdeflate's or zlib-ng's where it pays, and the memory a stream holds (the 32 KB
   window and the hash table). Each change measured with `bench/run.sh`.

## Acceptance criteria

- [x] The package builds as its own repository and imports nothing of `http`
- [x] One-shot `compress` and a streaming encoder with `flush` (an empty stored block,
      as zlib's `Z_SYNC_FLUSH`) and `finish`
- [x] gzip and zlib wrappers over the same DEFLATE stream
- [x] Round trips through `gzip -d` and Python's `zlib` on empty input, one byte, text,
      JSON, random bytes, inputs of 65,535 and 65,536 bytes and across other block
      boundaries, and many flushes (`scripts/roundtrip.py`)
- [x] A fuzz test of random inputs and flush points against Python's `zlib`
- [x] Step 2: LZ77 with fixed Huffman tables, passing the same tests
- [ ] Step 3: dynamic Huffman tables, passing the same tests
- [ ] Step 4: rate and ratio per level against libdeflate and zlib-ng at their nearest
      levels, on the same inputs and machine, with how they were measured, in
      `docs/results.md`
- [ ] Findings from the work recorded in `docs/goose-findings.md`

## Step 1

Stored blocks only, so every level stores. At level 0, where all three store, the
package compresses 342-345 MB/s against libdeflate's 21-32 GB/s and zlib-ng's 7.0-7.4
GB/s (`docs/results.md`). The gap is CRC-32: one table lookup a byte, against the
libraries' carryless-multiply CRC, which Goose can't express
([findings](../docs/goose-findings.md#goose-has-no-carryless-multiply)).

## Step 2

Levels 1 to 9 find LZ77 matches with one probe of a 4-byte hash a position, greedily,
up to 32,768 bytes back across writes and flushes. Each block of up to 16,384 symbols
is coded with the fixed Huffman tables, or stored where that's shorter. A stream holds
262,484 bytes. The decisions are in the
[architecture doc](../docs/architecture/README.md). Level 0 stores as at step 1, but
`compress` now runs the streaming encoder, so a one-shot input of a whole number of
65,535-byte blocks ends with an empty final block, as a stream's always did.

At level 1 the package compresses 65-159 MB/s on 7 Silesia files, 1.9 to 3.7 times
slower than zlib-ng and libdeflate. Its output is smaller than zlib-ng's, which uses
the same fixed tables, on six files of seven; libdeflate's is 13 to 32 percent
smaller than the package's. At level 6 it does a level 1's work, so it loses every
ratio (`docs/results.md`).
