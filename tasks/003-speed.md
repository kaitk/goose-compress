# 003: Speed past task 001

Status: in-progress

Task 001 left level 1 1.1 to 1.7 times slower than zlib-ng and level 6 1.3 to 1.9
times slower, on an M1 Pro (`docs/results.md`). This task takes the encoder further
without changing its API or its contracts: output depends only on the input and the
flush points, a flush ends in an empty stored block, and functions only append to
`out` (requested 2026-10-12).

## Method

Each change is built into a binary of its own and run against the build before it, in
alternating rounds on a quiet machine (`docs/development.md`, "Benchmark"). A change
is kept only where it pays, and committed once `scripts/test.sh` passes. Every
measurement, kept or not, goes in `docs/results.md` with how it was taken. The level
parameters stay unless a measurement argues otherwise; a change to them, or to any
other recorded decision, goes in the architecture doc in the same commit.

## Candidates

In rough order of expected payoff:

1. The chain search's fixed cost a position at levels 2 to 9, about 80 percent of
   level 6's time. On `x-ray`, depth 8 runs no faster than depth 35, at 1.2
   candidates a search, so the cost is per search: the call, the insert, and the
   loop's exits. Profile first (`docs/development.md`, "Profile"). Ideas: inline the
   search, test the first candidate before entering the loop, drop bounds checks that
   `goose check --bce-lines` shows kept, and cheaper insertion of the positions
   inside a match.
2. `end_block` at level 1: counting symbols, building two codes, and planning the
   header, every 16,384 symbols.
3. Level 1's ratio, 1.3 to 20 percent behind libdeflate's. libdeflate uses 2-entry
   hash buckets at level 1 and chooses where blocks end from the data. Measure either
   only if it fits the memory budget, and record the trade.
4. Small inputs: `compress` of 100 bytes takes 24 µs, mostly building the `Encoder`
   ([findings](../docs/goose-findings.md#a-struct-literal-copies-each-nested-fixed-array-whole)).
   Look for a way within the language that the findings entry doesn't rule out
   already; if there is none, leave it to the maintainer.
5. Adler-32 for zlib output: done on the Windows machine, as a `simd fn` summing 32
   lanes (540ae3c), and measured there (`docs/results.md`).
6. std's `clz` on x86-64, where clang leaves it a loop: done on the Windows machine.
   The length and distance codes and `better`'s logarithms come from tables, which
   doubled level 1 there. Keep `clz`, `ctz`, and `popcount` out of hot paths.

Bounds checks the hot paths keep at `c38dc0f` (`goose check --bce-lines
bench/bench.goose`, 2026-10-12): the hash-table index in `match_fast`, `insert`, and
`search` (`hash4` returns an `i64` the checker can't bound), `search`'s candidate and
`prev` loads, `load32`'s slice, `match_len`'s two loads, `add_sym`'s store, and the
`NICE`, `DEPTH`, and `LAZY` lookups.

## Acceptance criteria

- [ ] Each candidate above measured on its own against the build before it, kept or
      not, with the numbers in `docs/results.md`
- [ ] Kept changes committed one at a time, each with `scripts/test.sh` passing
- [ ] Any change to a recorded decision or level parameter recorded in
      `docs/architecture/README.md`
- [ ] Adler-32's rate measured, and whether `simd fn` applies recorded
- [ ] `LEVELS="1 6 9" bench/run.sh` recorded in `docs/results.md` as a section beside
      task 001's, with machine, OS, compiler, command, corpus, and run count
- [ ] Compiler and stdlib gaps found recorded in `docs/goose-findings.md`, and
      environment traps in `docs/development.md`
