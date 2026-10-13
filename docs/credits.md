# Credits

No code is adopted from another encoder. The package follows the designs below, and
this page names what it takes from each. libdeflate
([ebiggers/libdeflate](https://github.com/ebiggers/libdeflate)) and zlib-ng
([zlib-ng/zlib-ng](https://github.com/zlib-ng/zlib-ng)) are the benchmark's DEFLATE
competitors, and libzstd and klauspost/compress its zstd ones. When the package takes an
idea from any of them, this page names it.

- [zlib and the RFCs](#zlib-and-the-rfcs)
- [Huffman code lengths](#huffman-code-lengths)
- [libdeflate](#libdeflate)
- [Checksums](#checksums)
- [libzstd and klauspost/compress](#libzstd-and-klauspostcompress)

## zlib and the RFCs

The CRC-32 table and Adler-32's 5,552-byte run between reductions (zlib's `NMAX`) follow
zlib and its RFCs (1950, 1951, and 1952). Also from zlib:

- A block of at most 16,384 symbols, its default memory level.
- The choice among stored, fixed, and dynamic blocks by bit count, with its tie-breaks.
- The way it limits code lengths to 15 bits and gives a code at least two symbols.
- The zlib header's `FLEVEL` and gzip's `XFL` for each level.
- The flush, as `Z_SYNC_FLUSH`.

## Huffman code lengths

The optimal code lengths come from Moffat and Katajainen's in-place algorithm
("In-Place Calculation of Minimum-Redundancy Codes", 1995).

## libdeflate

- Hash chains searched newest first, with a candidate's 4 hashed bytes and the byte at
  the best length compared before it's extended (`hc_matchfinder`).
- Lazy and lazy2 matching, with its measure of a better match.
- Each level's search depth, nice length, and lazy mode.
- Loading the next position's hash bucket early, as its prefetch does, and carrying
  that position's hash to the next search, as its `next_hashes` do.
- Coding a block's symbols with 8-byte stores.

## Checksums

- XXH64 follows its specification in the xxHash repository (`Cyan4973/xxHash`,
  `doc/xxhash_spec.md`).
- CRC-32 by slice-by-16 is the common table method, not either library's.

## libzstd and klauspost/compress

The block format, the predefined FSE tables, the Huffman weights, and the bitstreams'
order come from RFC 8878.

### Level 1

Level 1 follows libzstd's `ZSTD_fast` (`facebook/zstd`):

- Two positions probed a step, the last offset checked first, with one byte of backward
  extension for it.
- The step that grows with the distance from the last match.
- The two positions it hashes after a match, and the offset before last tried at once.
- Blocks of at most 128 KB matched whole, as its streaming API buffers them.

The 6-byte hash and the 2^15-entry table are klauspost's `enc_fast.go`
(`klauspost/compress`).

### Level 3

Level 3 follows libzstd's `ZSTD_dfast` (`zstd_double_fast.c`), with its parameters for
inputs up to 128 KB:

- A 2^16-entry table of 8-byte hashes and a 2^15-entry table of 5-byte ones.
- Each position checks the last offset one position on, then the long match, then the
  short one, which gives way to a longer long match at the next position.
- The step that grows by one every 256 bytes.
- The four positions it hashes after a match.

### Literals

- One Huffman stream below 256 literals, and four above.
- The guess that skips building a code for literals with no byte more common than 1/128
  of them (`HUF_compress_internal`).
- Counting bytes into 4 tables (`HIST_count_parallel`).
- The weights' FSE accuracy of 5 (`FSE_optimalTableLog`).

### Sequences

- The FSE coding table's form: a state table and two deltas a symbol
  (`FSE_buildCTable`).
- Each table's accuracy (`FSE_optimalTableLog` again).
- Probabilities "less than 1" only in blocks of 2,048 sequences and more
  (`ZSTD_useLowProbCount`).

Choosing each table by its estimated bits, where libzstd's fast levels use rules of
thumb, is this package's.
