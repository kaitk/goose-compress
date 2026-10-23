# Architecture

How goose-compress works and why, for its users. The decisions behind it, each with its
reason and what was weighed against it, are in [decisions](decisions.md); measurements
are in [results](results.md).

## A package of its own, in Goose

goose-compress is imported as `compress` and knows nothing of HTTP, so any Goose
program can use it. goose-http reaches it only from a module of its own, which a
program imports when it compresses responses.

The encoders are Goose, not bindings to zlib-ng, libdeflate, or libzstd. Compression is
hashing, bit-packing, and Huffman tables, the byte work Goose is meant to do well, and
those C libraries, with klauspost/compress in Go, are what the encoders are benchmarked
against, in `bench/`.

It encodes only. Accepting compressed request bodies would need limits against
decompression bombs, and goose-http doesn't decode them.

## Formats and the API

Four formats: gzip, zlib, and raw DEFLATE, which share one DEFLATE encoder, and zstd,
which has an encoder of its own. Brotli is left out: HTTP servers serve it as
precompressed files, which goose-http already does.

Bytes go in and bytes come out, appended to a `u8[>..]` the caller owns:

- `compress::compress(data, out, format, level)` compresses `data` whole, reusing one
  encoder that each program instance builds at its first call.
- `compress::encoder(format, level)` gives a gzip, zlib, or DEFLATE stream, an
  `Encoder`, with `write`, `flush`, and `finish`; `compress::zstd_encoder(level)` gives
  a zstd one, a `ZstdEncoder`, with the same calls. A flush ends the
  output so that a reader decodes everything so far, for each chunk of a streamed
  response or event.

An encoder is a fixed-size value, with no resizable part, so a program can keep one per
connection in an array of slots and reset it in place between streams. Its size doesn't
depend on its level:

| Encoder | Bytes | What it holds |
|---|---:|---|
| `Encoder` (gzip, zlib, DEFLATE) | 460,406 | a 64 KB window, a 256 KB hash table, 64 KB of hash chains, a block of symbols |
| `ZstdEncoder` | 1,010,955 | a 128 KB window and a block, hash tables, a block's sequences and literals, FSE tables |

A stream's bytes don't depend on how its input was split across writes: an encoder that
isn't flushed gives the same output for one write or many, and `compress` gives the
same bytes as a stream that isn't flushed.

## DEFLATE

The encoder follows libdeflate's design:

- **Matching.** Level 0 stores. Level 1 looks up 2-entry hash buckets and takes the
  longer match greedily. Levels 2 to 9 walk hash chains, comparing more candidates the
  higher the level; levels 5 to 9 match lazily, trying one position on, and 8 and 9 two
  positions on, before they take a match. The default is 6. Level 1's loop is C,
  `shim/deflate.c`, which gives the same matches the Goose did.
- **The window** holds 32 KB of history and 32 KB of input, and slides when it fills.
  The hash table holds stream offsets rather than window positions, so a slide rewrites
  nothing, and every candidate is compared, so a stale entry costs a probe, never a
  wrong match.
- **Blocks.** A block is held as symbols until 16,384 of them, a slide, a flush, or the
  end, then coded whole in the shortest of three forms, counted exactly: a Huffman code
  built from its symbol counts, the fixed code, or stored. Incompressible input grows
  by about 5 bytes every 16 KB. Goose builds the codes; `shim/deflate.c` writes the
  symbols with them.
- **Checksums.** CRC-32 for gzip, by the CPU's carryless multiply where it has one
  (`shim/crc32.c`) and slice-by-16 elsewhere, and Adler-32 for zlib, both also
  available on their own (`compress::crc32`, `compress::adler32`).

## zstd

The zstd encoder writes frames with the content checksum and a 128 KB window, smaller
than libzstd's at level 1, since most responses are smaller than that and an encoder may
be held per connection:

- **Levels 1 to 22, with two matchers.** Level 1 follows libzstd's fast matcher, and
  levels 2 to 22 its double-fast matcher, which level 3, the stream's default, uses.
- **Blocks.** A block is matched once it's whole, 128 KB of input or what a flush or
  the end holds, and written compressed only when that's smaller than raw, or as RLE
  for one repeated byte.
- **Coding.** Literals are Huffman coded per block where that's shortest. Each kind of
  sequence code takes whichever table codes the block in the fewest bits: one built
  from the block, the predefined one, an RLE table, or the last block's, repeated.
