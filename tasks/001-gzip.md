# 001: gzip and zlib

Status: done (2026-10-12)

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
- [x] Step 3: dynamic Huffman tables, passing the same tests
- [x] Step 4: rate and ratio per level against libdeflate and zlib-ng at their nearest
      levels, on the same inputs and machine, with how they were measured, in
      `docs/results-history.md`
- [x] Findings from the work recorded in `docs/goose-findings.md`

## Step 1

Stored blocks only, so every level stores. At level 0, where all three store, the
package compresses 342-345 MB/s against libdeflate's 21-32 GB/s and zlib-ng's 7.0-7.4
GB/s (`docs/results-history.md`). The gap is CRC-32: one table lookup a byte, against the
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
ratio (`docs/results-history.md`).

## Step 3

Each block is coded with a dynamic code built from its symbol counts, the fixed code,
or stored, whichever takes the fewest bits. Code lengths are optimal (Moffat and
Katajainen) until one passes 15 bits, then limited as zlib limits them. Blocks still end
at 16,384 symbols and at a slide that would drop their first bytes: running past the
slide, and larger blocks, each gave more output on Silesia, so a stream still holds
262,484 bytes. The decisions are in the [architecture doc](../docs/architecture/README.md).

At level 1 the package's output is smaller than zlib-ng's on all seven Silesia files
and 1.3 to 20 percent larger than libdeflate's (13 to 32 percent at step 2). It
compresses 60-146 MB/s, 2.1 to 3.9 times slower than zlib-ng and 2.3 to 3.8 times
slower than libdeflate. At level 6 it still does a level 1's work and loses every
ratio, with 2 to 56 percent more output than zlib-ng (`docs/results-history.md`).

## Step 4

Each change was measured against the build before it, and kept only where it paid
(`docs/results-history.md`, "Step 4: each change"). Kept: CRC-32 by slice-by-16 (346 MB/s to
2.8 GB/s), a bit writer that appends 32 bits at once and codes a block's symbols with
8-byte stores, and comparing a candidate's 4 hashed bytes at once before extending it.
Levels 2 to 9 now search hash chains, and 5 to 9 match lazily, with libdeflate's
design and parameters; a stream holds 328,050 bytes, 65,566 more than at step 3, for
the chains. Measured and not kept: table lookups for the length and distance codes,
8-byte match compares, skipping the hashes inside matches at level 1, and a hash table
twice the size. Zeroing a stream can't be avoided in the package: the compiler builds
an `Encoder` through temporaries
([findings](../docs/goose-findings.md#a-struct-literal-copies-each-nested-fixed-array-whole)).
The decisions are in the [architecture doc](../docs/architecture/README.md).

On 7 Silesia files, against step 3: level 1 compresses 112-351 MB/s, 1.1 to 1.7 times
slower than zlib-ng and 1.3 to 1.7 times slower than libdeflate (2.1 to 3.9 times at
step 3), with the same output. Level 6 gives 2 to 35 percent less output than level 1:
smaller than zlib-ng's on five files, the same on one, and 1 percent larger on `xml`,
and up to 4 percent larger than libdeflate's. It compresses 43-114 MB/s, 1.3 to 1.9
times slower than zlib-ng and 1.5 to 2.1 times slower than libdeflate. Level 9 is faster
than zlib-ng on `x-ray` and 1.4 to 3.1 times slower on the other six files
(`docs/results-history.md`).

Not reached: the libraries' rates. What's left is mostly the chain search's fixed cost
a position at levels 2 to 9, and CRC-32 at level 0. The findings this step recorded are
std's `ctz` and `popcount` as loops, and a struct literal copying its arrays whole.
