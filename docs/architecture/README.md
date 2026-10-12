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

## Proposed

- **DEFLATE in steps that each give valid output** (task 001): stored blocks, then LZ77
  with fixed Huffman tables, then dynamic tables, then speed. Each step keeps the API.
