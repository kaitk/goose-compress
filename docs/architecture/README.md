# Architecture

Decisions for the package. Each says when it was decided. A proposed decision stands
until the task named beside it confirms or replaces it.

## Settled

- **A package of its own, imported as `compress`.** goose-compress imports nothing of
  HTTP, so any Goose program can use it. goose-http, its first user, reaches it only from
  a module of its own (its task 022). The name leaves room for zstd, where
  `goose-deflate` wouldn't have (2026-10-12).
- **Pure Goose, not bindings.** The encoders are Goose, not wrappers over zlib-ng or
  libdeflate. Compression is hashing, bit-packing, and Huffman tables, the byte work
  that measuring Goose is about; libdeflate, zlib-ng, libzstd, and klauspost/compress
  are what it's benchmarked against, in `bench/` (2026-10-12). Whether a C-backed
  encoder is kept beside the Goose one, for comparison inside a program, is open.
- **`bench/` holds each comparison library's own language: C, and Go for
  klauspost/compress.** klauspost is task 004's model of a zstd encoder written outside
  C, without assembly, so it shows what a language like Goose can reach; a C port or
  bindings would measure something else. `bench/klauspost/` is a Go module that pins
  its version in `go.mod`, and `bench/build.sh` builds it with `go build`. The package
  itself stays Goose with no C (task 004 step 6, 2026-10-13).
- **Encoding only.** Decoding is out of scope for now. goose-http doesn't decode request
  bodies, and accepting them needs limits against decompression bombs (2026-10-12).
- **Bytes in, bytes out, streaming with flush.** A one-shot `compress`, and an `Encoder`
  with `write`, `flush`, and `finish`, each appending to a `u8[>..]` the caller owns.
  `flush` ends the output on a byte boundary with an empty stored block, as zlib's
  `Z_SYNC_FLUSH` does, so each chunk of a streamed response or SSE event decompresses
  whole on arrival (2026-10-12).
- **gzip and zlib first, zstd later, no brotli.** gzip and zlib/deflate share one
  DEFLATE stream. zstd joins the same package once gzip is measured, which it now is
  (task 004, 2026-10-12). Brotli is out:
  HTTP servers serve it as precompressed files, which goose-http already does
  (2026-10-12). Task 002 says what would bring it back.
- **The encoder is a fixed-size value.** `Encoder` holds its state inline, with no
  resizable array, so a program can keep one per connection in an indexable array of
  slots. It holds input until a block fills, so the bytes of a stream that isn't flushed
  don't depend on how its input was split across writes (task 001, 2026-10-12).
- **An encoder is reset in place, not rebuilt.** `reset` zeroes an `Encoder` where it
  is, because a struct literal builds one through temporaries and copies each array
  several times
  ([findings](../goose-findings.md#a-struct-literal-copies-each-nested-fixed-array-whole)).
  `compress` resets one encoder that each program instance builds at its first call
  and keeps, held in a resizable global: a global `Encoder`, whose address clang
  knows, made level 6 2 to 7 percent slower on the Ryzen. A 100-byte `compress` went
  from 108 to 7.3 µs on the Ryzen under Windows, for 459,122 bytes held for the
  program's life (task 003, 2026-10-12).
- **A stream holds 460,406 bytes**, whatever its level: a window of 65,800 bytes, a
  hash table of 262,144, hash chains of 65,536, a block of symbols of 65,536, and
  the block's symbol counts, 1,264.
  Level 0 keeps its pending input in the window, and level 1 leaves the chains unused.
  zlib's defaults take 256 KB and a few more, by its own formula. The chains added 65,566 bytes to step 2's
  262,484 (task 001 step 4, 2026-10-12), the larger hash table 131,072 more, and
  counting symbols as they're added 1,272 more, and carrying the next position's
  hash 12 more (task 003, 2026-10-12).
- **The window is 32 KB of history, 32 KB of input, and 264 bytes of lookahead.** Input
  is copied in, and when the window fills it slides down 32 KB. Matching stops 264
  bytes short of its end, so it always stops past 64 KB and a slide keeps the full
  32,768 bytes DEFLATE can reach; zlib reaches 32,506. Those 264 bytes are the 2
  positions a lazy level looks ahead, the longest match, and the 4 bytes hashed at its
  last position, so a match never depends on how much input a write brought. A flush
  or finish matches to the end of the input (task 001 steps 2 and 4, 2026-10-12).
- **The hash table holds stream offsets, not window positions.** It's 2^16 `u32`
  entries, as libdeflate's chains use, of each bucket's latest offset modulo 2^32,
  hashed from 4 bytes. Every candidate is compared, so an entry that is stale or from
  4 GB back costs a probe and never gives a wrong match, and a slide rewrites nothing.
  zlib's table of `u16` window positions takes half the memory but is rewritten at
  each slide, and `u16` offsets in the same memory let stale entries through
  (`docs/results-history.md`, task 003). Against 2^15 entries, 2^16 made level 1's output 0.3
  to 0.8 percent smaller, and every rate measured faster on the Ryzen, by up to 22
  percent at levels 6 and 9 on `x-ray`; the M1 Pro gained on two files of four (task
  001 step 4). It costs 131,072 bytes a stream, taken as worth it (2026-10-12).
- **Every position inside a match is hashed, at every level.** Skipping them at level 1
  made output 3 to 8 percent larger on six Silesia files of seven; hashing only inside
  matches of up to 32 bytes was faster only on the most compressible files (`nci` 17
  percent, `xml` 9 percent), where level 1 is fastest already, and 2.6 percent larger
  on `nci` (`docs/results-history.md`, task 001 step 4, 2026-10-12).
- **Hash chains as distances, after libdeflate's `hc_matchfinder`.** From level 2,
  each stream offset's slot (offset modulo 32,768) holds the distance back to the
  previous offset in its bucket, as a `u16`, or 65,535 when it's farther than 32,768.
  A slot is good until the offset 32,768 later takes it. A search stops when a
  distance leaves the range 1 to 32,768 (or to the position, at the stream's start),
  one unsigned compare: 65,535 always leaves it, and so does the step out of a slot
  that the search's own position took, 32,768 back. One test in place of five made
  level 6 and 9 up to 8.7 percent faster on `x-ray` (task 003, 2026-10-12). Distances
  keep the table at 64 KB with nothing to rewrite at a slide, as the hash table's
  offsets do; libdeflate's and zlib's `u16` window positions are rebased at each slide
  (task 001 step 4, 2026-10-12).
- **A search compares a candidate's 4 hashed bytes and the byte at the best length so
  far before extending it.** Most candidates fail there. At level 1, comparing the 4
  bytes at once made the encoder 16 to 27 percent faster. Extending 8 bytes at a time
  was no faster at any level, because matches are short, and std's `ctz` is a loop
  ([findings](../goose-findings.md#clz-ctz-and-popcount-loop-over-the-bits)) (task 001 step
  4, 2026-10-12).
- **Length and distance codes, and a distance's logarithm for lazy matching, come from
  tables built once,** not from std's `clz`. On the M1 Pro the tables were within the
  noise of `clz`, which Apple clang makes one instruction; on the Ryzen, where clang
  leaves `clz` a loop, they made level 1 1.2 to 2.1 times faster and levels 6 and 9 9 to
  27 percent faster (task 003, 2026-10-12).
- **A block is held as symbols, then coded whole.** A block ends at 16,384 symbols, at
  a slide that would drop its first bytes, and at a flush or finish. Holding the block
  lets its header carry the final-block bit and gives the symbol counts its dynamic
  code is built from (task 001 step 2, 2026-10-12).
- **Each block takes the shortest of three forms, by exact bit count:** a dynamic
  code built from its symbol counts, the fixed code, or stored. Ties go to stored,
  then fixed, as zlib breaks them. Incompressible input grows by about 5 bytes every
  16 KB (task 001 step 3, 2026-10-12).
- **Blocks keep ending at 16,384 symbols and at a slide that would drop their first
  bytes.** Both alternatives were measured at step 3 (`docs/results-history.md`, "Where blocks
  end"). Running a block past the slide, as zlib does, and blocks of 32,768 or 65,536
  symbols each gave more output on Silesia, up to 0.55 percent, and larger blocks hold
  up to 196,608 bytes more a stream. A smaller block's code follows the data more
  closely, and a dynamic header of a few dozen bytes is small beside 16,384 symbols
  (task 001 step 3, 2026-10-12).
- **Code lengths: optimal, then limited the way zlib limits them.** Moffat and
  Katajainen's in-place algorithm gives optimal lengths from the frequencies sorted
  ascending, in flat arrays with no heap or tree nodes. Where a length passes the limit
  (15 bits, 7 for the code-length code), every length over it is cut to it, and leaves
  move down one level at a time, zlib's way, until the Kraft sum is exactly 1; the
  lengths then go out longest to the least frequent symbol. Package-merge would be
  optimal at the limit too, but costs O(n·L) work and more state a block, and real
  data seldom passes 15 bits, where the two agree. A code always has at least two
  symbols, as zlib's does, because zlib's inflate rejects an incomplete code other than
  a lone 1-bit one (task 001 step 3, 2026-10-12).
- **Levels follow libdeflate's.** 0 stores; the default is 6, as zlib's and
  libdeflate's. Level 1 probes one hash candidate a position and takes the match
  greedily, keeping no chains. Levels 2 to 9 search the hash chains with libdeflate's
  depth (the most candidates compared) and nice length (the length that ends a
  search). Levels 5 to 7 match lazily: after a match, a search one position on
  (at half the depth) may find a better one, and the encoder emits a literal and
  takes it. Levels 8 and 9 also look two positions on, at a quarter of the depth.
  "Better" is libdeflate's measure: 4 for each byte longer, 1 for each power of two
  nearer, past 2 one position on and 6 two positions on. The same matcher design
  takes the same tuning, and level 6 then comes within 1 percent of libdeflate's
  output on text. zlib's `deflate_slow` was the alternative; its parameters are tuned
  for a 3-byte hash and a different lazy rule. Shallower searches at level 6 (depth
  16, nice 32) were 22 to 30 percent faster on four Silesia files and no faster on
  `x-ray`, for up to 4.7 percent more output, on `xml` (`docs/results-history.md`). `compress` runs the streaming encoder, so a stream that isn't
  flushed gives the same bytes either way (task 001 step 4, 2026-10-12).

  | Level | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 |
  |---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
  | Search | one probe | greedy | greedy | greedy | lazy | lazy | lazy | lazy2 | lazy2 |
  | Depth | 1 | 6 | 12 | 16 | 16 | 35 | 100 | 300 | 600 |
  | Nice length | 258 | 10 | 14 | 30 | 30 | 65 | 130 | 258 | 258 |
- **A match found ahead is held across writes.** When a lazy level takes the match
  one or two positions on, it keeps it in the stream until that position is matched,
  which may be in the next write. With the lookahead, this keeps a stream's bytes
  independent of how its input was split (task 001 step 4, 2026-10-12).
- **Building a stream is most of what a small input costs**, which the package can't
  avoid at the pin: `compress` takes 24 µs for 100 bytes on an M1 Pro, at level 1 or
  6, because the compiler builds an `Encoder` through temporaries, zeroing it and
  copying it whole three times
  ([findings](../goose-findings.md#a-struct-literal-copies-each-nested-fixed-array-whole)).
  Limited arrays, whose slots aren't zeroed, were slower still (task 001 step 4,
  2026-10-12).
- **Bits go out 8 bytes at a time.** Between calls the writer holds fewer than 32
  bits and appends 32 at once. A block's symbols are coded into a 4 KB buffer on the
  stack, 8 bytes stored per symbol, and appended to the output as it fills; growing
  the output first and shrinking it after would make `compress` a function that
  shrinks its `out`, which bars callers from holding slices of it (task 001 step 4,
  2026-10-12).
- **CRC-32 by slice-by-16**, from a 16 KB table: 2.8 GB/s on an M1 Pro, against 346
  MB/s a byte at a time and 1.8 GB/s by slice-by-8. The libraries' carryless multiply
  is out of Goose's reach
  ([findings](../goose-findings.md#goose-has-no-carryless-multiply)) (task 001 step 4,
  2026-10-12).
- **zstd is a fourth format for `compress`, with a stream type of its own.**
  `compress::ZSTD` lets a caller such as goose-http pick any encoding with one
  argument. Its stream is a `ZstdEncoder`, with overloads of `reset`, `write`,
  `flush`, and `finish`: an `Encoder` holding both formats' state would make every
  gzip slot pay for zstd's window and tables (task 004 step 1, 2026-10-12).
- **A zstd flush ends the current block and writes nothing else.** zstd blocks end on a
  byte boundary, so a reader decodes everything up to the last block whole, with no
  marker like DEFLATE's empty stored block. A flush with no input held writes nothing
  (task 004 step 1, 2026-10-12).
- **The zstd frame carries the content checksum and no content size.** The checksum
  is the low 32 bits of XXH64, as the zstd command line and klauspost's Go encoder
  write it; libzstd's API leaves it off, so the benchmark turns it on there. With no
  content size, `compress` and an unflushed stream give the same bytes, as for
  DEFLATE (task 004 step 1, 2026-10-12).
- **A zstd stream holds a full block until more input comes**, so the last block
  carries the last-block flag and `finish` adds no empty block after it (task 004
  step 1, 2026-10-12).
- **A zstd window of 128 KB**, declared in the frame header, in place of libzstd's
  512 KB at level 1. A 256 KB window made Silesia's output 1.4 percent smaller and a
  512 KB one 2.0 percent, for a `ZstdEncoder` of 688,304 or 950,448 bytes against
  557,232, and only on inputs past 128 KB; libzstd itself takes a 128 KB window for
  inputs up to 128 KB. Most HTTP responses are smaller than that, and the encoder is
  held per connection slot (task 004 step 2, 2026-10-13,
  [results](../results-history.md#the-window-and-the-matchers-parameters)). Confirmed
  against libzstd built in `bench/` (task 004 step 6, 2026-10-13,
  [results](../results.md#zstd-levels-1-and-3-at-237de3a)): with the same 128 KB
  window, Silesia's output is 5.0 percent smaller than libzstd's at level 1 and 2.3
  percent smaller at level 3. Level 3's 4.2 percent over libzstd's full 2 MB window is
  all the window's.
- **A zstd block is matched once it's whole**, as libzstd's streaming API does: 128 KB
  of input past the last block, or the input held at a flush or finish. A match ends at
  the block's end, so blocks and matches don't depend on how writes split the input,
  with no lookahead. The window buffer holds the window, a block, and 32 KB, 294,912
  bytes; when it fills it slides down, keeping exactly the window before the next
  block, and the 32 KB keeps flushes from making it slide every few bytes (task 004
  step 2, 2026-10-13).
- **A zstd block ends at 16,384 sequences**, which takes 131,072 bytes of `u64`
  entries; 32,768 would never end a block early, at 4 bytes a match. An early end
  costs another block's headers, a few bytes, since the next block can repeat its
  FSE tables. No block
  of the 12 Silesia files reaches it at level 1, the most being `mozilla`'s 15,263;
  `roundtrip.py`'s input of a sequence every 6 bytes reaches it in its second block
  (task 004 step 2, 2026-10-13).
- **zstd's level 1 is libzstd's `ZSTD_fast`**: a hash table of 2^15 stream offsets,
  hashed from 6 bytes as klauspost's `enc_fast.go` does, probed at two positions a
  step, with the last offset checked two positions on first and a match extended back.
  After a match, the offset before last is tried at once. The step grows by one
  position every 128 bytes without a match. libzstd's 7-byte hash made Silesia's
  output 2.6 percent larger; a 5-byte one gained 1.7 percent, nearly all on `x-ray`,
  and was 2 to 9 percent slower (task 004 step 2, 2026-10-13).
- **zstd's level 3 is libzstd's `ZSTD_dfast`, with libzstd's parameters for inputs up
  to 128 KB**: a table of 2^16 stream offsets hashed from 8 bytes, beside level 1's
  table of 2^15, here hashed from 5. Each position checks the last offset one position
  on, then the long match, then the short one, which gives way to a longer long match
  at the next position. Silesia's output went from level 1's 0.3378 of its input to
  0.3251, against `zstd -3`'s 0.3124 with its 2 MB window and 0.3335 with a 128 KB one
  (`--zstd=wlog=17`). It's 2 to 24 percent slower than level 1 on six of seven files,
  and 80 percent slower on `x-ray`, where libzstd's level 3 is 70 percent slower than
  its level 1 with one thread (step 6). A 2^17-entry long table, libzstd's for larger inputs, made the output
  0.15 percent smaller for 256 KB more; a 6-byte short hash made it 2.0 percent larger,
  and a 4-byte one left it the same as 5. The long table adds 262,144 bytes, for a
  `ZstdEncoder` of 879,875 (task 004 step 5, 2026-10-13,
  [results](../results-history.md#zstd-level-3-task-004-step-5)).
- **A zstd `reset` keeps the hash tables.** Each stream's offsets start a window past
  the last stream's end, so no entry from before is in reach, and a new encoder's start
  a window past 0, so its empty entries aren't either: a reset stream codes as a new
  encoder's does. The tables are cleared when offsets would pass 2^31, so the two agree
  for a stream's first 2 GB, as far as the tables' 32-bit offsets go without wrapping
  in either. Clearing level 3's 384 KB of tables at every reset made `compress` of 100
  bytes take 6.2 µs, against 2.6 µs without (task 004 step 5, 2026-10-13).
- **zstd's levels, 1 to 22, each run the nearest level built**: level 1 the fast
  matcher, and 2 and up the double-fast, level 3, as libzstd's level 2 does for inputs
  up to 256 KB. Higher levels wait on a measurement (task 004, 2026-10-12; level 3
  measured in step 5, 2026-10-13). Measured against libzstd and klauspost/compress in
  step 6 (2026-10-13), the levels stand: level 3 writes 3.8 percent less than level 1,
  as libzstd's writes 9.7 percent less and klauspost's SpeedDefault 8.5 percent less
  than SpeedFastest, each with a larger window.
- **Repeat offsets are resolved when a block is coded**, from the offsets a decoder
  holds after the last compressed block. The matcher keeps distances and its own last
  two offsets; a block written raw leaves the decoder's offsets as they were, as RFC
  8878 §3.1.1.5 says (task 004 step 2, 2026-10-13).
- **A zstd block is compressed only when that's smaller**, else written raw, or RLE
  when it's one repeated byte. The sequences' bitstream is counted exactly before it's
  written, because the block header holds its size: a bound computed in the forward
  pass, to skip the count, was 2 to 3 percent slower (task 004 step 2, 2026-10-13).
- **zstd literals are Huffman coded per block, or RLE, or raw, whichever is
  shortest**, counted to the byte before the block is written. The code is built from
  the block's counts with DEFLATE's length-limited builder, cut to zstd's 11 bits, in
  one stream below 256 literals and four from 256, as libzstd splits them. Its weights
  go 4 bits each or FSE coded at accuracy 5, the log libzstd's `FSE_optimalTableLog`
  gives them, where that's shorter. Literals whose most common byte is no more than
  1/128 of them and 4 stay raw without a code built, libzstd's guess. A block of
  literals alone is compressed too. Silesia's output went from 0.4246 of its input to
  0.3768, against `zstd -1`'s 0.3457, for 17 to 22 percent of the rate (task 004 step
  3, 2026-10-13, [results](../results-history.md#zstd-huffman-literals-task-004-step-3)).
- **Each zstd literal stream's counts are kept apart** while the literals are counted,
  so the four streams' sizes for the jump table are known before any is written, and
  no buffer of literals or coded bytes is held: each stream is written by walking the
  sequences back from where it ends. A literals buffer would add 128 KB to each
  `ZstdEncoder` (task 004 step 3, 2026-10-13).
- **Each kind of zstd sequence code takes the table its block codes in the fewest
  bits**: one built from the block's counts, the predefined one, an RLE table for one
  code, or the last block's repeated. Each is priced at log2(2^accuracy / probability)
  bits a code, from a table of 256ths, plus its description; the block's size is then
  counted exactly with the tables chosen. libzstd's fast levels choose by rules of
  thumb instead (`ZSTD_selectEncodingType`). Built tables take libzstd's accuracy,
  at most 9, 8, and 9 for literal lengths, offsets, and match lengths. Silesia's
  output went from 0.3768 of its input to 0.3378, below `zstd -1`'s 0.3457, for 2
  percent of the rate or less (task 004 step 4, 2026-10-13,
  [results](../results-history.md#zstd-fse-tables-per-block-task-004-step-4)).
- **A `ZstdEncoder` holds two table slots for each kind of code**: the decoder's
  table, which a block can repeat, and one the block builds into, which becomes the
  decoder's only when the block is written compressed. Repeat mode carries across
  flushes, and `reset` starts a frame with no table to repeat. Tables are in
  libzstd's coding form, a state table and two deltas a symbol, 1,888 bytes at
  accuracy 9; the decoding form indexed by symbol and state that step 2 used would
  take 54 KB a table at that accuracy. Each sequence's three codes are kept, 48 KB,
  so they're computed once for counting, sizing, and writing (task 004 step 4,
  2026-10-13).

## Proposed

- **DEFLATE in steps that each give valid output** (task 001): stored blocks, then LZ77
  with fixed Huffman tables, then dynamic tables, then speed. Each step keeps the API.
  All four steps are done (2026-10-12).
