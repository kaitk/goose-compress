# 003: Speed past task 001

Status: in-progress

Task 001 left level 1 1.1 to 1.7 times slower than zlib-ng and level 6 1.3 to 1.9
times slower, on an M1 Pro. This task takes the encoder further without changing its
API or its contracts: output depends only on the input and the flush points, a flush
ends in an empty stored block, and functions only append to `out` (requested
2026-10-12).

## Method

Each change is built into a binary of its own and run against the build before it, in
alternating rounds on a quiet machine (`docs/development.md`, "Benchmark"). A change
is kept only where it pays, and committed once `scripts/test.sh` passes. Every
measurement, kept or not, goes in `docs/results-history.md` with how it was taken. The
level parameters stay unless a measurement argues otherwise; a change to them, or to
any other recorded decision, goes in the architecture doc in the same commit.

## Candidates

In rough order of expected payoff, with where each stands (2026-10-12):

1. The chain search's fixed cost a position at levels 2 to 9, about 80 percent of
   level 6's time. Kept: one unsigned range test ends a chain (`x-ray` +9.6 percent at
   level 6), 2^16 hash buckets (+25 percent), the next position's hash carried to the
   next search (+6 percent), and a match extension's bounds checked once a call
   (`xml` +6 percent). Not kept: libdeflate's candidate test, `u16` buckets, a packed
   result, loading the next candidate's window byte early, and masking indexes to drop
   bounds checks. Not tried: inlining the search, and cheaper insertion of the
   positions inside a match.
2. `end_block` at level 1. Kept: the length and distance codes from tables (Ryzen),
   and symbols counted as they're added (+3 to 11 percent). Coding the symbols
   (`put_syms`) is still about 17 percent of level 1.
3. Level 1's ratio, 0.5 to 20 percent behind libdeflate's. 2-entry buckets in the same
   256 KB reach libdeflate's ratio at 12 to 29 percent of the rate; not kept, a trade
   left to decide. Choosing where blocks end from the data is untried.
4. Small inputs: done on the Windows machine. `reset` zeroes an encoder in place, and
   `compress` resets one it keeps per program instance: 108 to 7.3 µs for 100 bytes
   there, 24 to 8 µs on the M1 Pro. Leaving `syms` and `win` uncleared in `reset`
   saved 1.1 µs a call but made 10,000 bytes at level 6 slower on the M1 Pro; not
   kept. `var e: Encoder;` as a local doesn't compile ("may be used before it is
   assigned").
5. Adler-32 for zlib output: done on the Windows machine, as a `simd fn` summing 32
   lanes (540ae3c), and measured there.
6. std's `clz` on x86-64, where clang leaves it a loop: done on the Windows machine.
   The length and distance codes and `better`'s logarithms come from tables, which
   doubled level 1 there and gained 0.5 to 4 percent on the M1 Pro. Keep `clz`,
   `ctz`, and `popcount` out of hot paths.

## Acceptance criteria

- [ ] Each candidate above measured on its own against the build before it, kept or
      not, with the numbers in `docs/results-history.md` (open: inlining the search,
      cheaper skip-insertion, and block ends chosen from the data)
- [x] Kept changes committed one at a time, each with `scripts/test.sh` passing
- [x] Any change to a recorded decision or level parameter recorded in
      `docs/architecture/README.md`
- [x] Adler-32's rate measured, and whether `simd fn` applies recorded
- [x] `LEVELS="1 6 9" bench/run.sh` recorded in `docs/results.md`, with machine, OS,
      compiler, command, corpus, and run count (M1 Pro at `ce13855`)
- [x] Compiler and stdlib gaps found recorded in `docs/goose-findings.md`, and
      environment traps in `docs/development.md`
