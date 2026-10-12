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
  that measuring Goose is about; libdeflate and zlib-ng are what it's benchmarked
  against, in `bench/` (2026-10-12). Whether a C-backed encoder is kept beside the Goose
  one, for comparison inside a program, is open.
- **Encoding only.** Decoding is out of scope for now. goose-http doesn't decode request
  bodies, and accepting them needs limits against decompression bombs (2026-10-12).
- **Bytes in, bytes out, streaming with flush.** A one-shot `compress`, and an `Encoder`
  with `write`, `flush`, and `finish`, each appending to a `u8[>..]` the caller owns.
  `flush` ends the output on a byte boundary with an empty stored block, as zlib's
  `Z_SYNC_FLUSH` does, so each chunk of a streamed response or SSE event decompresses
  whole on arrival (2026-10-12).
- **gzip and zlib first, zstd later, no brotli.** gzip and zlib/deflate share one
  DEFLATE stream. zstd joins the same package once gzip is measured. Brotli is out:
  HTTP servers serve it as precompressed files, which goose-http already does
  (2026-10-12). Task 002 says what would bring it back.
- **The encoder is a fixed-size value.** `Encoder` holds its state inline, with no
  resizable array, so a program can keep one per connection in an indexable array of
  slots. It holds input until a block fills, so the bytes of a stream that isn't flushed
  don't depend on how its input was split across writes (task 001, 2026-10-12).
- **A stream holds 328,050 bytes**, whatever its level: a window of 65,800 bytes, a
  hash table of 131,072, hash chains of 65,536, and a block of symbols of 65,536.
  Level 0 keeps its pending input in the window, and level 1 leaves the chains unused.
  zlib holds about as much at its defaults. The chains added 65,566 bytes to step 2's
  262,484 (task 001 step 4, 2026-10-12).
- **The window is 32 KB of history, 32 KB of input, and 264 bytes of lookahead.** Input
  is copied in, and when the window fills it slides down 32 KB. Matching stops 264
  bytes short of its end, so it always stops past 64 KB and a slide keeps the full
  32,768 bytes DEFLATE can reach; zlib reaches 32,506. Those 264 bytes are the 2
  positions a lazy level looks ahead, the longest match, and the 4 bytes hashed at its
  last position, so a match never depends on how much input a write brought. A flush
  or finish matches to the end of the input (task 001 steps 2 and 4, 2026-10-12).
- **The hash table holds stream offsets, not window positions.** It's 2^15 `u32`
  entries of each bucket's latest offset modulo 2^32, hashed from 4 bytes. Every
  candidate is compared, so an entry that is stale or from 4 GB back costs a probe and
  never gives a wrong match, and a slide rewrites nothing. zlib's table of `u16`
  window positions takes half the memory but is rewritten at each slide. 2^16 entries,
  as libdeflate's chains use, made level 6 up to 20 percent faster on `x-ray` and
  level 1's output up to 0.8 percent smaller, for 131,072 more bytes a stream; not
  taken (`docs/results.md`, task 001 step 4, 2026-10-12).
- **Every position inside a match is hashed, at every level.** Skipping them at level 1
  made output 3 to 8 percent larger on six Silesia files of seven; hashing only inside
  matches of up to 32 bytes was faster only on the most compressible files (`nci` 17
  percent, `xml` 9 percent), where level 1 is fastest already, and 2.6 percent larger
  on `nci` (`docs/results.md`, task 001 step 4, 2026-10-12).
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
  ([findings](../goose-findings.md#ctz-and-popcount-loop-over-the-bits)) (task 001 step
  4, 2026-10-12).
- **A block is held as symbols, then coded whole.** A block ends at 16,384 symbols, at
  a slide that would drop its first bytes, and at a flush or finish. Holding the block
  lets its header carry the final-block bit and gives the symbol counts its dynamic
  code is built from (task 001 step 2, 2026-10-12).
- **Each block takes the shortest of three forms, by exact bit count:** a dynamic
  code built from its symbol counts, the fixed code, or stored. Ties go to stored,
  then fixed, as zlib breaks them. Incompressible input grows by about 5 bytes every
  16 KB (task 001 step 3, 2026-10-12).
- **Blocks keep ending at 16,384 symbols and at a slide that would drop their first
  bytes.** Both alternatives were measured at step 3 (`docs/results.md`, "Where blocks
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
  `x-ray`, for up to 4.7 percent more output, on `xml` (`docs/results.md`). `compress` runs the streaming encoder, so a stream that isn't
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

## Proposed

- **DEFLATE in steps that each give valid output** (task 001): stored blocks, then LZ77
  with fixed Huffman tables, then dynamic tables, then speed. Each step keeps the API.
  All four steps are done (2026-10-12).
