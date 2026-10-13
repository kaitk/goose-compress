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
Next:

- Codegen, for levels 1 and 6: the hand-fixed C of the same matchers runs 10 to 14
  percent faster than the Goose build at level 6 and up to 23 percent at level 1, from
  bounds checks and state kept through `z`. Then `end_block`, 11.2 ms of a level 1
  `dickens` run against libdeflate's 7.2. The `build/task005/port/` prototypes and
  sampler (`CLAUDE.local.md`) are the starting point.
- libdeflate's search costs less per position on `x-ray` with the same work, at both
  levels.
- libdeflate's 3-byte matches and adaptive minimum length bring output within 1
  percent of its own, but cost up to 30 percent of the rate in the current table
  layout; revisit after the above.

The package is slower than libdeflate and zlib-ng at every level on both machines
(`docs/results.md`). Its rate should at worst match theirs. If the Goose encoder can't get
there, the package proxies to the C libraries instead (requested 2026-10-13). This
task finds which of the two it is. It tunes for the Ryzen 7 5800X3D under Windows, as
goose-http does, and doesn't hold back a change for the M1 Pro's sake or for task 003's
earlier measurements. It covers DEFLATE. zstd (task 004) is 2 to 3 times slower than
libzstd; the codegen fixes found here are applied to it after DEFLATE, and the proxy
decision covers both.

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
3. `match_len` compares a byte at a time, because std's `ctz` is a loop
   ([findings](../docs/goose-findings.md#clz-ctz-and-popcount-loop-over-the-bits)).
   libdeflate XORs 8 bytes and takes one `tzcnt`.
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
5. Decide: keep the Goose encoder, or proxy. A proxy replaces the encoder whole. A C
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
- [ ] Parity reached at levels 1, 6, and 9 on the Ryzen, or the proxy decision recorded
      in `docs/architecture/README.md` with the measurements behind it
- [ ] Results show output size against libdeflate's, rate against ratio, and per-stream
      memory and peak RSS for all three encoders, as in "How results are shown"
- [ ] Compiler and stdlib gaps found recorded in `docs/goose-findings.md`
