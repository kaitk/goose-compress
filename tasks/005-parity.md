# 005: Parity with the C libraries, Ryzen first

Status: in-progress

Steps 1 to 3 are done (2026-10-13). The hand-fixed C reached 0.63 to 0.91 of
libdeflate's rate, so step 3 pointed to the structure
([results](../docs/results-history.md#task-005-steps-2-and-3-simd-fn-and-the-codegen-ceiling)).
`9f7a539` ports `hc_matchfinder`'s chain search: level 9 now runs at 0.82 to 1.09 of
libdeflate's rate, level 6 at 0.73 to 0.84
([results](../docs/results-history.md#task-005-step-3-libdeflates-chain-search-at-9f7a539)).
`24ac46b` ports level 1's `ht_matchfinder`: output within 0.2 percent of libdeflate's,
at 0.51 to 0.63 of its rate, 11 to 28 percent slower than before
([results](../docs/results-history.md#task-005-level-1-in-libdeflates-2-entry-buckets-at-24ac46b)).
`8ec4538` extends matches 8 bytes at a time, +0.8 to +9.0 percent everywhere: level 9
runs at 0.85 to 1.12 of libdeflate's rate, at or above it on six files of seven, level
6 at 0.74 to 0.88, and level 1 at 0.56 to 0.66
([results](../docs/results-history.md#task-005-8-byte-match-extension-at-8ec4538)).
The window reads kept their bounds checks, which the compiler couldn't drop at
`a6249a4`; at `46356c2` it drops them on `win[p - d]` after a guard, but not on a
slice taken at a difference, as `load32` takes one
([findings](../docs/goose-findings.md#bounds-check-elimination-doesnt-combine-facts-about-a-difference)),
and strict aliasing gave at most 3 percent. At level 1, finding matches alone runs at
libdeflate's rate in C; recording and writing the symbols takes about 16 ms of a
`dickens` run against libdeflate's 9, and the small changes to that path tried came
within noise ([results](../docs/results-history.md#task-005-the-symbol-path-at-level-1-not-kept)).

Step 5, zstd, is in progress (2026-10-13). On the Ryzen at `8ec4538`, libzstd was 2.0
to 2.4 times faster at level 1 and 1.5 to 1.7 at level 3, and the coding after the
matcher took 3.8 times libzstd's time a byte on `webster`
([profile](../docs/results-history.md#zstd-profile-at-8ec4538)). Three changes to
the coding, `b396581` the largest (literals copied into one buffer as each sequence is
stored), leave libzstd 1.45 to 1.74 times faster at level 1 and 1.22 to 1.37 at level
3, with klauspost about even
([results](../docs/results.md#zstd-levels-1-and-3-at-b396581)). `be26d4e` and
`64f7bc5` took 0 to 3 percent more out of `code_seqs`. The pin moved to `0bdbd18`,
whose std `ctz` and `clz` are instructions. `d10dd61` gives zstd its own `match_len`
with one 8-byte load and `ctz`, +2.4 to +9.2 percent; either in the shared one cost
gzip up to 6 percent on `x-ray`
([history](../docs/results-history.md#task-005-zstds-own-match_len-at-d10dd61)). At
`e1a9800`, pin `46356c2`, libzstd is 1.37 to 1.60 times faster at level 1 and 1.14 to
1.29 at level 3 on six files, and klauspost 0.84 to 1.09 times the package's rate
([results](../docs/results.md#zstd-levels-1-and-3-at-e1a9800)). Removing every check
in the C of zstd's matchers gains 1.9 to 6.1 percent, but the Goose that drops the
window reads' checks loses 2.7 to 12.1, because marking `load32` and `load64` `inline`
costs as much on its own; not kept
([history](../docs/results-history.md#task-005-zstds-window-reads-without-checks-not-kept)).
Left for zstd:

- The FSE steps and `put_seqs`, 14 percent at level 1 on `webster`; the literals'
  Huffman coding on `x-ray`, about 1.8 times libzstd's time a byte.
- The tables against the 512 KB L2: libzstd's level 1 hash table is 32 KB, the
  package's 128 KB.

Left for DEFLATE, after zstd:

- Level 1's blocks as libdeflate's `deflate_compress_fastest` makes them: up to 64 KB
  of input or 8,192 matches, with literals counted as runs and read back from the
  window when the block is written, not stored a symbol each. It changes the output
  slightly; the gain is unmeasured.
- libdeflate's search costs less per position on `x-ray` with the same work, at
  levels 1 and 6.
- libdeflate's 3-byte matches and adaptive minimum length bring output within 1
  percent of its own, but cost up to 30 percent of the rate in the current table
  layout.

The `build/task005/port/` prototypes and sampler (`CLAUDE.local.md`) are the starting
point for each.

The package is slower than libdeflate and zlib-ng at every level on both machines
(`docs/results.md`). Its rate should at worst match theirs. If the Goose encoder can't get
there, the package proxies to the C libraries instead (requested 2026-10-13). This
task finds which of the two it is. It tunes for the Ryzen 7 5800X3D under Windows, as
goose-http does, and doesn't hold back a change for the M1 Pro's sake or for task 003's
earlier measurements. It covers DEFLATE first. zstd (task 004) is 2 to 3 times slower
than libzstd; step 5 applies the fixes found here to it, and the proxy decision covers
both.

## Where the gap is thought to be

libdeflate's matchfinder is plain C, with no assembly or SIMD. Its intrinsics are only
in CRC-32 and Adler-32. zlib-ng uses intrinsics: AVX2 to compare matches 32 bytes at a
time, carryless multiply for CRC folded into the copy, and SSE4.2 CRC for hashing. Both
libraries run the same kind of algorithm with the same parameters, yet levels 6 and 9
are 1.5 to 2.2 times slower than libdeflate. So the gap is assumed to lie in the C clang
gets from Goose, not in assembly:

1. Bounds checks in `search`'s inner loop: `z.win[c + best]`, `load32`'s slice,
   `z.prev`, and `z.head` (task 003 lists them). `865d359` took `match_len`'s down to
   one a call.
2. Encoder state reached through `z: Lz&`. `pos`, `nsym`, and `fill` share a struct with
   `syms`, `prev`, and `head`, so clang may reload them after every store into those
   arrays. libdeflate keeps its state in locals and writes it back once. A global
   `Encoder` moved level 6 by 2 to 7 percent, which shows how fragile this codegen is.
3. `match_len` compares a byte at a time, because std's `ctz` was a loop (until Goose
   `d687028`). libdeflate XORs 8 bytes and takes one `tzcnt`.
4. On `x-ray`, 44 percent of `search`'s samples land at the loop's exits. In libdeflate,
   no instruction takes more than 7 percent.
5. CRC-32 without carryless multiply, at 2.6 GB/s against about 17 GB/s.

SIMD pays where data is processed in lanes: checksums, long match compares, and the
slide. Walking a chain is one dependent load after another, which SIMD doesn't speed up.
Use SIMD where a measurement shows a gain, not as a goal in itself.

## Steps

1. Fetch Goose and move the pin past `a6249a4` if it lags (`dbc3e9f` moved it there
   from `c38dc0f`). Of the 8 commits between those two, `f13dfcd` fixes how the
   compiler names locals, which shouldn't change the generated code's speed, and
   `1e3efa4` (one C toolchain per build) may change the compiler a Windows build picks.
   Rerun `LEVELS="0 1 6 9" bench/run.sh` at `HEAD` as the Ryzen's baseline for this
   task. The Ryzen's latest run is at `43cb937`. The M1 Pro's is at `ce13855`, so
   `d71eb59`, `1f1ed62`, and `865d359` are unmeasured on the Ryzen. On the M1 Pro they
   left level 1 1.05 to 1.5 times slower than zlib-ng and level 6 1.25 to 1.7.
2. Check whether `simd fn` gets bit scans for free. Read the flags its AVX2 version is
   compiled with. If they enable `lzcnt` and `bmi` (x86-64-v3), clang may turn std's
   `ctz` loop into `tzcnt`. Then a `simd fn` `match_len` with an 8-byte compare costs
   no language change. Measure it.
3. Find the ceiling by hand-fixing the C Goose emits for `search`, `match_fast`, and
   `match_len`. Change codegen only: drop the bounds checks, keep the state in locals,
   and use `__builtin_ctzll`. Benchmark it against libdeflate.
   - If it reaches libdeflate, the algorithm holds. Restructure the Goose source toward
     that C, and record what the language can't express in `docs/goose-findings.md`.
   - If it stays well behind, the structure is the cause. Port libdeflate's matchfinder
     and level 1 loop line by line, and measure again.
4. Add Intel ISA-L's `igzip` to `bench/` beside libdeflate and zlib-ng, as the
   hand-written assembly reference at levels 0 to 3. Consider Chromium's zlib, which
   Node uses, and zlib-rs. Bun offers zlib and libdeflate through `Bun.gzipSync`'s
   `library` option; its default is unconfirmed.
5. Apply what DEFLATE taught to zstd, against libzstd and klauspost/compress:
   - Measure zstd levels 1 and 3 on the Ryzen; it has run only on the M1 Pro.
   - Profile the package and libzstd, built from source, with the sampler
     (`CLAUDE.local.md`). On the M1 Pro, the coding after the matcher took 4.3 times
     libzstd's time a byte on `webster` and the matcher 2.1 times, so the coding comes
     first.
   - Carry over the fixes kept for DEFLATE: the hot search inlined, bounds checks and
     encoder state out of the inner loops, and block writing. The 16-bit chain links
     don't apply: zstd's levels 1 and 3 keep hash tables and no chains.
   - Check the tables against the 512 KB L2: 128 KB and 256 KB of `u32`, beside a
     larger window than DEFLATE's.
6. Decide: keep the Goose encoders, or proxy. A proxy replaces the encoder whole. A C
   matchfinder inside a Goose package is a binding with extra steps. libdeflate has no
   streaming or sync flush, so `Encoder` would need zlib-ng; one-shot `compress` could
   use libdeflate. A proxy reverses "Pure Goose, not bindings" in
   `docs/architecture/README.md` and the `AGENTS.md` rule on C, so it starts on a
   branch.

## What counts as parity

Against libdeflate, compare level by level: at the same level both give the same ratio
to within a few percent. Against zlib-ng, compare rate at a matched ratio. Its level 1
codes with the fixed tables, and its output is 24 to 32 percent larger than the
package's on text (`webster` 0.456 against 0.345). Parity means the package's
rate-against-ratio curve on Silesia is no worse than either library's, in rates within
the run-to-run noise.

## How results are shown

Today's tables give rates and ratios in separate columns. A reader has to divide to see
that zlib-ng's faster level 1 costs a third more output. The results for this task show:

- Output size against libdeflate's at the same level, as a percentage (`+1.3%`), next
  to the rate. Raw ratios stay in the full tables.
- Rate against ratio for each library across its levels on one or two files, as a
  chart or a table sorted by ratio. This is the parity view above.
- Memory: the bytes each library holds per stream at each level, from its own
  allocation or formula, and peak RSS of `bench` for one stream. A program holds one
  stream per connection, so per-stream bytes matter for goose-http. The package holds
  459,122 bytes at every level, and zlib's defaults about 256 KB. libdeflate's figure
  is unmeasured, so whether memory favours the package is open.

## Acceptance criteria

- [x] Pin moved, and the Ryzen's baseline at `HEAD` recorded in `docs/results.md`
- [x] The `simd fn` bit-scan check done, and the result recorded
- [x] The hand-fixed C's rates recorded beside libdeflate's, with which outcome of step
      3 they point to
- [ ] Each change measured on its own against the build before it, kept or not, with the
      numbers in `docs/results.md`
- [ ] `igzip` in `bench/`, or the reason it isn't, recorded
- [ ] zstd levels 1 and 3 measured on the Ryzen against libzstd and klauspost/compress,
      and each fix carried over from DEFLATE measured on its own, kept or not
- [ ] Parity reached at levels 1, 6, and 9 on the Ryzen, and zstd's gap to libzstd
      closed or measured, or the proxy decision recorded in
      `docs/architecture/README.md` with the measurements behind it
- [ ] Results show output size against libdeflate's, rate against ratio, and per-stream
      memory and peak RSS for all three encoders, as in "How results are shown"
- [ ] Compiler and stdlib gaps found recorded in `docs/goose-findings.md`
