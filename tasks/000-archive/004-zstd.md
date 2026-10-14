# 004: zstd

Status: done

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
levels; step 2 kept the 128 KB window, step 5 settled the levels, and step 6 confirmed
both against libzstd and klauspost:

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
- [x] Step 3: Huffman literals, passing the same tests
- [x] Step 4: FSE tables per block, passing the same tests, with a fuzz run
- [x] Step 5: level 3, passing the same tests
- [x] Step 6: libzstd built in `bench/` in release mode, and rate and ratio at levels
      1 and 3 recorded in `docs/results.md`, and what was measured around them in
      `docs/results-history.md`, with how they were measured
- [x] Decisions above confirmed or replaced in `docs/architecture/README.md`, and the
      README's status table and API updated
- [x] Findings recorded in `docs/goose-findings.md`: steps 1 to 6 found none new

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
([results](../../docs/results-history.md#zstd-level-1-task-004-step-2)).
`scripts/roundtrip.py` holds each input to a zstd size limit, with inputs at the
window's edge and one that fills a block's 16,384 sequences. The unit tests check the
exact bytes of two compressed blocks, the second using a repeat offset.

## Step 3

Done (2026-10-13). Each block's literals are Huffman coded with a code built from the
block's counts, cut to 11 bits, in one stream below 256 literals and four from 256;
RLE where they're one byte; or raw where that's no larger. The code's weights go
4 bits each, or FSE coded at accuracy 5 where that's shorter, as they must be past
128 of them. A block of literals alone is compressed too. On the M1 Pro, the 12
Silesia files come to 0.3768 of their size, from step 2's 0.4246, against `zstd -1`'s
0.3457; on `x-ray`, nearly all literals, within 0.1 percent of libzstd. Rates fell 17
to 22 percent on six of seven files, to 134 to 459 MB/s, and `x-ray` went from 2.3
GB/s, a copy, to 596 MB/s. `compress` of 100 bytes takes 3.5 µs, from 1.3
([results](../../docs/results-history.md#zstd-huffman-literals-task-004-step-3)).
`scripts/roundtrip.py` adds skewed bytes of nearly every value, which take 11-bit codes
and FSE-coded weights, and holds text, JSON, and the other inputs with literals to
tighter zstd limits. A unit test checks the exact bytes of a block of Huffman literals.
Step 4 should beat 0.3768 on Silesia.

## Step 4

Done (2026-10-13). Each block codes its literal lengths, offsets, and match lengths
each with the table of the fewest estimated bits: one built from the block's counts, at
libzstd's accuracy of at most 9, 8, and 9; the predefined one; an RLE table for one
code; or the last block's repeated, across flushes too. `reset` starts a frame with
no table to repeat. Tables are now in libzstd's coding form, which the Huffman weights
use too. On the M1 Pro, the 12 Silesia files come to 0.3378 of their size, from step
3's 0.3768, below `zstd -1`'s 0.3457. Rates are within 2 percent of step 3's, inside
the rounds' spread, and `compress` of 1,000 bytes takes 7.8 µs, from 7.1
([results](../../docs/results-history.md#zstd-fse-tables-per-block-task-004-step-4)).
`scripts/roundtrip.py` adds 440,000 bytes whose statistics change between blocks, and
reads back its frames: one-shot, blocks build tables; flushed every 1,000 bytes, they
repeat them; and the two take all four modes. Fuzz runs of seeds 1 to 3 with 2,000
cases each, and of seeds 4 to 6 with 3,000 cases at `--levels 1`, which makes 2 in 5
cases zstd, all passed. A unit test checks the exact bytes of a block with built
tables and a block after a flush that repeats them. Step 5, level 3, should beat
level 1's 0.3378 on Silesia, toward `zstd -3`'s 0.3124 (zstd 1.5.7, `--no-check`).

## Step 5

Done (2026-10-13). Level 3 is libzstd's `ZSTD_dfast` with its parameters for inputs
up to 128 KB: a 2^16-entry table of 8-byte hashes beside level 1's 2^15-entry table,
hashed from 5 bytes at level 3. Levels 2 and up run it. The long table makes a
`ZstdEncoder` 879,875 bytes, from 617,727; a 2^17-entry one gained 0.15 percent for
256 KB more. `reset` no longer clears the tables: each stream starts out of their
entries' reach, which takes `compress` of 100 bytes from step 4's 3.6 µs to 2.5 at
level 1 and 2.6 at level 3.

On the M1 Pro, the 12 Silesia files come to 0.3251 of their size at level 3, from
level 1's 0.3378, against `zstd -3`'s 0.3124 with its 2 MB window and 0.3335 with a
128 KB one. Level 3 is 2 to 24 percent slower than level 1 on six of seven files, at
109 to 421 MB/s, and 80 percent slower on `x-ray`, 120 MB/s, as libzstd's level 3 is
84 percent slower there than its level 1. Level 1's rates are within the rounds'
spread of step 4's
([results](../../docs/results-history.md#zstd-level-3-task-004-step-5)).

`scripts/roundtrip.py` gives level 3 its own zstd limits: tighter on text, the copies,
short matches, and the changing input, and looser on the JSON, where level 3 does
worse than level 1, as libzstd's does. Fuzz runs of seeds 1 to 3 with 2,000 cases
each, and of seeds 4 to 6 with 3,000 cases at `--levels 1 --zstd-levels 3`, which
makes 1 in 4 cases zstd at level 3, all passed. A unit test checks the exact bytes of
5-byte matches that level 3 finds and level 1 misses, and that a reset stream comes
out as from a new encoder after streams at levels 3 and 1. Step 6 should compare
level 1's and level 3's rates above with libzstd's built in `bench/`.

## Step 6

Done (2026-10-13). `bench/build.sh` builds libzstd v1.5.7 in `Release` mode, which
`bench/ref.c` runs with the checksum on, at its own window and at 128 KB, and
`bench/klauspost`, a Go program running klauspost/compress v1.20.3. `FORMAT=zstd
bench/run.sh` runs all of them at levels 1 and 3. Go in `bench/` is a new decision,
recorded in the architecture doc and `AGENTS.md`.

On the M1 Pro, the package loses every rate
([results](../../docs/results.md#zstd-levels-1-and-3-at-237de3a)). At level 1, libzstd is
2.3 to 3.2 times faster on six of seven files and klauspost 1.6 to 1.7 times; on
`x-ray`, 1.2 and 3.8 times. At level 3, libzstd is 2.0 to 2.3 times faster on six
files and 1.7 on `x-ray`, and klauspost 1.4 to 1.9 times. The 12 Silesia files come to
0.3378 of their size at level 1, smaller than libzstd's 0.3455 and klauspost's 0.3478;
and 0.3251 at level 3, larger than libzstd's 0.3121 and klauspost's 0.3184, and smaller
than libzstd's 0.3326 with the same 128 KB window.

Step 5's `zstd -b` rates, which made libzstd's level 1 look 5 times faster, were
multithreaded: the zstd command line uses worker threads by default. On `webster` at
level 1, the package's matcher takes 2.1 times libzstd's time a byte, and the coding
after it 4.3 times ([profile](../../docs/results-history.md#zstd-against-libzstd-and-klauspost-task-004-step-6)).
Nothing was optimized in this step. The traps steps 1 to 6 added to
`docs/development.md` are the spec's defined behavior (§6.2, §7.2), not findings.
