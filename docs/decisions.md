# Decisions

The record of goose-compress's design decisions, for contributors and agents: each
dated, with its reason and the trade-off that matters. How the package works, for its
users, is [architecture](architecture.md). Measurements are recorded in
[results history](results-history.md).

## Settled

- **A package of its own, imported as `compress`.** goose-compress imports nothing of
  HTTP, so any Goose program can use it. goose-http, its first user, reaches it only from
  a module of its own (its task 022). The name leaves room for zstd, where
  `goose-deflate` wouldn't have (2026-10-12).
- **Goose where it's as fast, C where it wins; the package's own encoders, not
  proxies.** A hot loop moves to C, in `shim/` and built through `compress.build`, when
  the C measures faster than the best Goose for it, and the C keeps the Goose code's
  output byte for byte. The rest stays Goose. This replaces "pure Goose, not bindings"
  (2026-10-12): pure Goose isn't a requirement, and a server that gzips each response
  pays for every microsecond (2026-10-23). It settles task 005's keep-or-proxy question
  against proxies. libdeflate gzips the HttpArena bodies 7 to 13 percent faster than
  the package with its C matcher, but it has no streaming or sync flush, so a proxy
  would leave `Encoder` on another encoder whose bytes differ from `compress`'s, and
  would bring libdeflate's C to every platform the package builds on. In Plod's
  json-comp entry, gzip is now about 45 percent of the server's CPU, and most of the
  gap to Aegon is outside it ([results](results-history.md#level-1-and-the-symbol-coder-in-c)).
  A proxy comes back if gzip again decides that benchmark.
- **`bench/` holds each comparison library's own language: C, and Go for
  klauspost/compress.** klauspost is task 004's model of a zstd encoder written outside
  C, without assembly, so it shows what a language like Goose can reach; a C port or
  bindings would measure something else. `bench/klauspost/` is a Go module that pins
  its version in `go.mod`, and `bench/build.sh` builds it with `go build`. The package's
  own C is its shims, under the decision above (task 004 step 6, 2026-10-13).
- **CRC-32 on the CPU's carryless multiply, in C for now.** On x86-64 with PCLMULQDQ
  and SSE4.1, and on arm64 with PMULL, `crc32` folds 64 bytes and up with
  `shim/crc32.c`, which `compress.build` compiles, and the slice-by-16 tables take the
  rest and every other CPU. The CPU is checked once at run time, as goose-hash checks
  for its SHA instructions: CPUID on x86-64, `getauxval` on Linux arm64, and
  `IsProcessorFeaturePresent` on Windows arm64; macOS arm64 always has PMULL.
  `GOOSE_COMPRESS_PORTABLE=1` forces the tables, so `scripts/test.sh` runs on either
  path. This replaces "Goose with no C" for CRC-32 only, until Goose has a carryless
  multiply ([findings](goose-findings.md#goose-has-no-carryless-multiply)); goose-hash's
  SHA shim is the model. With gcc on a Ryzen 7 5800X3D, level 0 runs 2.8 times as fast
  on `dickens` and 35 to 38 percent faster on the 4 to 8 KB JSON bodies; level 1 is 4 to
  6 percent faster on the bodies and unchanged on `dickens`. With Apple clang on an M1
  Pro, level 0 runs 4.0 times as fast on `dickens` and 3.4 to 3.5 times on the bodies;
  level 1 takes 8 to 10 percent less time on the bodies and runs 3 percent faster on
  `dickens`
  ([results](results-history.md#crc-32-on-pmull)). The trade-off: a C compiler for one
  function (2026-10-23).
- **Level 1's matcher and the symbol coder in C.** `shim/deflate.c`'s `gc_match_fast`
  is level 1's loop, and `gc_put_syms` codes every level's dynamic and fixed blocks,
  each the Goose code's algorithm step for step, so the output is the same byte for
  byte. Goose keeps the stream, where blocks end, and the Huffman codes. The shim is
  plain C, which runs on every CPU, so nothing falls back. With gcc 15.2
  `-O3 -march=native` on a Ryzen 7 5800X3D under WSL2, level 1 takes 12 to 15 percent
  off the JSON bodies and runs 9 to 22 percent faster on Silesia; levels 6 and 9 are
  unchanged within noise. The gain is the bounds checks: the Goose code with every
  check stripped from its C ran as fast as the shim. A `checkfree` Goose loop came
  within 9 percent, 15.35 µs a call on `json40` against the shim's 14.04, because the
  facts the analysis can't keep had to be written as range tests of their own
  ([findings](goose-findings.md#bounds-check-elimination-misses-an-lz-matchers-facts)).
  Prefetching the next bucket, as libdeflate does, cost 2 percent in a server. The
  trade-off: level 1 and the symbol coder are no longer Goose to measure
  ([results](results-history.md#level-1-and-the-symbol-coder-in-c), 2026-10-23).
- **`load32` is an `inline fn`, tuned for gcc.** Level 1 no longer reads through it
  (above); the chains do. Servers build with gcc, which doesn't
  inline the C `load32` on its own. With gcc on a Ryzen 7 5800X3D, the inline form
  takes 21 to 29 percent off the small JSON bodies at levels 1 and 6 and gives 12 to 20
  percent more MB/s on Silesia
  ([results](results-history.md#level-1s-load32-and-next-bucket-with-gcc)). The
  trade-off: Apple clang already inlines the C function, and Goose's inlining gives it
  other C that costs 3 to 15 percent at levels 6 and 9 on an M1 Pro, and up to 3 at
  level 1 ([results](results-history.md#level-1s-load32-and-next-bucket-not-kept)).
  Task 008 looks for a form that wins under both (2026-10-23).
- **Encoding only.** Decoding is out of scope for now. goose-http doesn't decode request
  bodies, and accepting them needs limits against decompression bombs (2026-10-12).
- **Bytes in, bytes out, streaming with flush.** A one-shot `compress`, and an `Encoder`
  with `write`, `flush`, and `finish`, each appending to a `u8[>..]` the caller owns.
  `flush` ends the output on a byte boundary with an empty stored block, as zlib's
  `Z_SYNC_FLUSH` does, so each chunk of a streamed response or SSE event decompresses
  whole on arrival (2026-10-12).
- **gzip, zlib, raw DEFLATE, and zstd; no brotli.** gzip and zlib share one
  DEFLATE stream; zstd has its own encoder (task 004, completed 2026-10-13).
  Brotli is out:
  HTTP servers serve it as precompressed files, which goose-http already does
  (2026-10-12). Task 002 says what would bring it back.
- **The encoder is a fixed-size value.** `Encoder` holds its state inline, with no
  resizable array, so a program can keep one per connection in an indexable array of
  slots. It holds input until a block fills, so the bytes of a stream that isn't flushed
  don't depend on how its input was split across writes (task 001, 2026-10-12).
- **An encoder is reset in place, not rebuilt.** `reset` starts an `Encoder` over
  where it is, because a struct literal builds one through temporaries and copies each array
  several times
  ([findings](goose-findings.md#a-struct-literal-copies-each-nested-fixed-array-whole)).
  `compress` resets one encoder that each program instance builds at its first call
  and keeps, held in a resizable global: a global `Encoder`, whose address clang
  knows, made level 6 2 to 7 percent slower on the Ryzen
  ([measurement](results-history.md#small-inputs-2), task 003, 2026-10-12).
- **A stream holds 460,406 bytes**, whatever its level: a window of 65,800 bytes, a
  hash table of 262,144, hash chains of 65,536, a block of symbols of 65,536, and
  the block's symbol counts, 1,264, plus scalar state.
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
- **The hash table holds stream offsets, not window positions.** From level 2 it uses
  2^16 `u32` entries, as libdeflate's chains use, of each bucket's latest offset modulo 2^32,
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
- **Hash chains as the low 16 bits of offsets, after libdeflate's `hc_matchfinder`.**
  From level 2, each stream offset's slot (offset modulo 32,768) holds the low 16 bits
  of the previous offset in its bucket, or of the offset 32,768 back when that one is
  farther. A search reads links only from offsets up to 32,768 back, whose slots no
  later offset has taken, so the 16 bits place the link; a search writes its own
  position's link after its walk, so the offset 32,768 back stays reachable. A chain
  step is then a load and a mask, as libdeflate's, where distances took a load, two
  additions, and a mask on the path from one load to the next. With the candidate test
  below and the search inlined, levels 6 and 9 got 22 to 92 percent faster on the
  Ryzen, writing the same bytes (task 005, 2026-10-13). The table stays 64 KB with
  nothing to rewrite at a slide. A slide-rebased `u16` head table, as libdeflate's,
  was slower at level 9 in a C prototype (task 005).
- **A search compares a candidate's 4 hashed bytes, and once it has a match, the 4
  bytes ending at the best length, before extending it,** as libdeflate's does. Until
  the first match, it compares only the 4 hashed bytes. Most candidates fail there.
  At level 1, comparing the 4 bytes at once made the encoder 16 to 27 percent faster
  (task 001 step 4, 2026-10-12).
- **A match is extended 8 bytes at a time, after one byte,** with the first differing
  byte found by a de Bruijn multiply and a 64-entry table. std's `ctz` was a loop until
  Goose `d687028`; as an instruction it made DEFLATE's chain search 3 to 5 percent
  slower on `x-ray` at levels 6 and 9, and zstd's own `match_len` uses it
  ([results](results-history.md#task-005-zstds-own-match_len-at-d10dd61), 2026-10-14).
  `match_len` is an `inline fn`: as a call it lost more than the compare gained, 5 to 7
  percent at level 6 on `x-ray`. Against a byte at a time it made every level 0.8 to
  9.0 percent faster on the Ryzen, most on `nci` (task 005, 2026-10-13). With `ctz`
  in its place it was 4 to 26 percent slower (task 001 step 4, task 005 step 2).
- **Length and distance codes, and a distance's logarithm for lazy matching, come from
  tables built once.** When this was measured, std's `clz` compiled to a loop on
  x86-64; the tables made level 1 1.2 to 2.1 times faster on the Ryzen and levels 6
  and 9 9 to 27 percent faster. Goose `0bdbd18` and the current pin provide bit-scan
  instructions; the package retains the measured table implementation (task 003,
  2026-10-12).
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
  libdeflate's. Level 1 is libdeflate's `ht_matchfinder`: 2^15 buckets of the 2
  latest offsets, in the 2^16-entry hash table, both tried unless the newer gives 32
  bytes, and the longer match taken greedily, with no chains. Against one probe a
  position it made level 1's output 0.1 to 20 percent smaller, to within 0.2 percent
  of libdeflate's, and 11 to 28 percent slower on the Ryzen; the same code in
  hand-fixed C ran within 2.4 percent of the old rate, or faster, on four files of
  seven, so the loss is taken as codegen to fix (task 005, 2026-10-13). Levels 2 to 9 search the hash chains with libdeflate's
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
  | Search | 2-entry bucket | greedy | greedy | greedy | lazy | lazy | lazy | lazy2 | lazy2 |
  | Maximum candidates | 2 | 6 | 12 | 16 | 16 | 35 | 100 | 300 | 600 |
  | Nice length | 32 | 10 | 14 | 30 | 30 | 65 | 130 | 258 | 258 |
- **A match found ahead is held across writes.** When a lazy level takes the match
  one or two positions on, it keeps it in the stream until that position is matched,
  which may be in the next write. With the lookahead, this keeps a stream's bytes
  independent of how its input was split (task 001 step 4, 2026-10-12).
- **Bits go out 8 bytes at a time.** Between calls the writer holds fewer than 32
  bits and appends 32 at once. A block's symbols are coded into a 4 KB buffer on the
  stack, 8 bytes stored per symbol, and appended to the output as it fills; growing
  the output first and shrinking it after would make `compress` a function that
  shrinks its `out`, which bars callers from holding slices of it (task 001 step 4,
  2026-10-12).
- **CRC-32 by slice-by-16**, from a 16 KB table: 2.8 GB/s on an M1 Pro, against 346
  MB/s a byte at a time and 1.8 GB/s by slice-by-8. The libraries' carryless multiply
  is out of Goose's reach
  ([findings](goose-findings.md#goose-has-no-carryless-multiply)) (task 001 step 4,
  2026-10-12). From 2 KB, the input's two halves run at once, as two chains of
  lookups, and their CRCs are joined as zlib's `crc32_combine` joins them: on the M1
  Pro, 8,397 bytes took 1.87 µs against 2.69 µs, and 64 KB 13.1 µs against 20.8 µs;
  at 2 KB, 0.46 µs against 0.64 µs
  ([results](results-history.md#small-json-bodies-reset-huffman-codes-level-1s-loop-and-crc-32),
  2026-10-23).
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
  [results](results-history.md#the-window-and-the-matchers-parameters)). Confirmed
  against libzstd built in `bench/` (task 004 step 6, 2026-10-13,
  [results](results.md#zstd-levels-1-and-3-at-237de3a)): with the same 128 KB
  window, Silesia's output is 5.0 percent smaller than libzstd's at level 1 and 2.3
  percent smaller at level 3. Level 3's 4.2 percent over libzstd's full 2 MB window is
  all the window's. With level 1's 2^13 table (2026-10-14), level 1's output is 1.6
  percent smaller than libzstd's at 128 KB and 1.2 percent larger than at its own 512
  KB.
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
- **zstd's level 1 is libzstd's `ZSTD_fast`**: a hash table of 2^13 stream offsets,
  hashed from 6 bytes as klauspost's `enc_fast.go` does, probed at two positions a
  step, with the last offset checked two positions on first and a match extended back.
  After a match, the offset before last is tried at once. The step grows by one
  position every 128 bytes without a match. libzstd's 7-byte hash made Silesia's
  output 2.6 percent larger; a 5-byte one gained 1.7 percent, nearly all on `x-ray`,
  and was 2 to 9 percent slower (task 004 step 2, 2026-10-13).
- **zstd's level 1 table is libzstd's 2^13 entries, 32 KB**, which stays in the
  Ryzen's 512 KB L2 beside the window, not klauspost's 2^15. It's up to 18.6 percent
  faster, and Silesia's output goes from 0.3378 of its input to 0.3498, against
  libzstd's 0.3455 at level 1 and 0.3556 with a 128 KB window. 2^14 gained up to 12.3
  percent for up to 3.1 percent more output. Level 1 uses the first 2^13 entries of
  level 3's short table, so the encoder's size is the same (task 005, 2026-10-14,
  [results](results-history.md#level-1s-hash-table-against-the-l2)).
- **zstd's level 3 is libzstd's `ZSTD_dfast`, with libzstd's parameters for inputs up
  to 128 KB**: a table of 2^16 stream offsets hashed from 8 bytes and a table of
  2^15 offsets hashed from 5. Each position checks the last offset one position
  on, then the long match, then the short one, which gives way to a longer long match
  at the next position. Silesia's output went from level 1's 0.3378 of its input to
  0.3251, against `zstd -3`'s 0.3124 with its 2 MB window and 0.3335 with a 128 KB one
  (`--zstd=wlog=17`). It's 2 to 24 percent slower than level 1 on six of seven files,
  and 80 percent slower on `x-ray`, where libzstd's level 3 is 70 percent slower than
  its level 1 with one thread (step 6). A 2^17-entry long table, libzstd's for larger
  inputs, made the output 0.15 percent smaller for 256 KB more; a 6-byte short hash
  made it 2.0 percent larger, and a 4-byte one left it the same as 5 (task 004 step 5,
  2026-10-13,
  [results](results-history.md#zstd-level-3-task-004-step-5)).
- **A zstd `reset` keeps the hash tables.** Each stream's offsets start a window past
  the last stream's end, so no entry from before is in reach, and a new encoder's start
  a window past 0, so its empty entries aren't either: a reset stream codes as a new
  encoder's does. The tables are cleared when offsets would pass 2^31, so the two agree
  for a stream's first 2 GB, as far as the tables' 32-bit offsets go without wrapping
  in either. Clearing level 3's 384 KB of tables at every reset made `compress` of 100
  bytes take 6.2 µs, against 2.6 µs without (task 004 step 5, 2026-10-13).
- **A DEFLATE `reset` keeps the hash tables and chains too,** by the zstd reset's
  rule: offsets start at 32,768 in a new encoder, and each stream's a window past the
  last one's end, so no entry from before is in reach; the tables are cleared when
  offsets would pass 2^31, and a stream after a reset codes as a new encoder's for its
  first 2 GB. The window and the block's symbols aren't zeroed either, since nothing
  reads them past the input and the symbols held; only the symbol counts are. Zeroing
  the 460 KB at every reset was half the time of `compress` of a 100-byte body at
  level 1 on the M1 Pro: 7.4 µs, against 3.8 µs without
  ([results](results-history.md#small-json-bodies-reset-huffman-codes-level-1s-loop-and-crc-32),
  2026-10-23).
- **zstd accepts levels 1 to 22, with two implemented matchers.** Level 1 uses the
  fast matcher; levels 2 to 22 use the double-fast matcher, level 3. The stream's
  default is 3. Higher levels need separate implementations and measurements
  (task 004, 2026-10-13).
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
  3, 2026-10-13, [results](results-history.md#zstd-huffman-literals-task-004-step-3)).
- **zstd literals are copied into a contiguous 128 KB buffer as sequences are stored.**
  Each Huffman stream's counts are kept separately, so its size is known before any
  stream is written. The buffer avoids walking sequences again to count and write
  literals. It adds 131,072 bytes to the encoder, for a total of 1,010,955 bytes at
  every level; the measured rate gain justified the memory cost
  ([measurement](results-history.md#task-005-zstd-coding-changes-at-b396581),
  task 005, 2026-10-13).
- **Each kind of zstd sequence code takes the table its block codes in the fewest
  bits**: one built from the block's counts, the predefined one, an RLE table for one
  code, or the last block's repeated. Each is priced at log2(2^accuracy / probability)
  bits a code, from a table of 256ths, plus its description; the block's size is then
  counted exactly with the tables chosen. libzstd's fast levels choose by rules of
  thumb instead (`ZSTD_selectEncodingType`). Built tables take libzstd's accuracy,
  at most 9, 8, and 9 for literal lengths, offsets, and match lengths. Silesia's
  output went from 0.3768 of its input to 0.3378, below `zstd -1`'s 0.3457, for 2
  percent of the rate or less (task 004 step 4, 2026-10-13,
  [results](results-history.md#zstd-fse-tables-per-block-task-004-step-4)).
- **A `ZstdEncoder` holds two table slots for each kind of code**: the decoder's
  table, which a block can repeat, and one the block builds into, which becomes the
  decoder's only when the block is written compressed. Repeat mode carries across
  flushes, and `reset` starts a frame with no table to repeat. Tables are in
  libzstd's coding form, a state table and two deltas a symbol, 1,888 bytes at
  accuracy 9; the decoding form indexed by symbol and state that step 2 used would
  take 54 KB a table at that accuracy. Each sequence's three codes are kept, 48 KB,
  so they're computed once for counting, sizing, and writing (task 004 step 4,
  2026-10-13).
- **Tests follow Goose's own convention**, as the Goose repository's `test/` and
  `docs/testing.md` lay it out, in goose-compress, goose-http, and goose-rest alike: a
  top-level `test/` by area; each test a small program, a `main` with `assert`s that
  prints what it checks, against a golden file in `test/expected/` (`<name>.out`, and
  `<name>.stderr` and `<name>.aborts` where they apply); `// error:` fixtures for code
  that must not compile; shared helpers in one imported module; and the repository's own runner,
  `test/run_tests.py` in Python as Goose's is, shared with no other repository, that
  compiles them in batches with `goose --multi-test`, runs each as a process of its own
  and in parallel, and reports every failure without stopping at the first. It
  replaces test programs run by name, where the first failed `assert` ends a program.
  Rejected: a test framework inside Goose, which has no reflection to find tests and
  needs none to check printed output; and tests beside the code, since the compiler
  leaves out of a build what its root doesn't import, and a separate `test/` matches
  the convention any reader of Goose's own repository knows (task 007, 2026-10-15).
