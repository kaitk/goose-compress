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
- **A stream holds 262,484 bytes**, whatever its level: a window of 65,798 bytes, a
  hash table of 131,072, and a block of symbols of 65,536. Level 0 keeps its pending
  input in the window. zlib holds about as much at its defaults (task 001 step 2,
  2026-10-12).
- **The window is 32 KB of history, 32 KB of input, and 262 bytes of lookahead.** Input
  is copied in, and when the window fills it slides down 32 KB. Matching stops 262
  bytes short of its end, so it always stops past 64 KB and a slide keeps the full
  32,768 bytes DEFLATE can reach; zlib reaches 32,506. Those 262 bytes are the longest
  match and the 4 bytes hashed at its last position, so a match never depends on how
  much input a write brought. A flush or finish matches to the end of the input (task
  001 step 2, 2026-10-12).
- **The hash table holds stream offsets, not window positions.** It's 2^15 `u32`
  entries of each bucket's latest offset modulo 2^32, hashed from 4 bytes, probed once
  a position. Every candidate is compared byte by byte, so an entry that is stale or
  from 4 GB back costs a probe and never gives a wrong match, and a slide rewrites
  nothing. zlib's table of `u16` window positions takes half the memory but is
  rewritten at each slide. Every position inside a match is hashed too: ratio first,
  and step 4 measures what skipping them gains (task 001 step 2, 2026-10-12).
- **A block is held as symbols, then coded whole.** A block ends at 16,384 symbols, at
  a slide that would drop its first bytes, and at a flush or finish. It is then written
  with the fixed Huffman tables or stored, whichever takes fewer bits, as zlib chooses,
  so incompressible input grows by about 5 bytes every 16 KB. Holding the block lets
  its header carry the final-block bit, and gives step 3 the symbol counts it builds
  dynamic tables from (task 001 step 2, 2026-10-12).
- **Levels.** 0 stores, and 1 to 9 compress; the default is 6, as zlib's. Every level
  from 1 matches the same way until step 4 adds a lazy one. `compress` runs the
  streaming encoder, so a stream that isn't flushed gives the same bytes either way
  (task 001 step 2, 2026-10-12).

## Proposed

- **DEFLATE in steps that each give valid output** (task 001): stored blocks, then LZ77
  with fixed Huffman tables, then dynamic tables, then speed. Each step keeps the API.
