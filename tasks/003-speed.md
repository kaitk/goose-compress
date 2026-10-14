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

## Results and follow-up

The tuning added a range test for chain searches, code lookup tables, 2^16 hash
buckets, symbol counts collected during matching, a carried next-position hash,
encoder reuse through `reset`, and SIMD Adler-32. Each experiment and its method
are in [results history](../docs/results-history.md#task-003-each-change-measured-on-its-own).

The candidate list recorded on 2026-10-12 is superseded by
[task 005](005-parity.md). That task implemented inlined chain search and level-1
2-entry buckets; block layout and insertion costs remain performance candidates.
The old advice to avoid std's bit scans predates Goose `0bdbd18`, which provides
instructions for them. Keep or replace the package's tables based on measurements.

## Acceptance criteria

- [ ] Each remaining candidate measured on its own against the build before it, kept or
      not, with the numbers in `docs/results-history.md` (remaining insertion and
      block-layout experiments are tracked in task 005)
- [x] Kept changes committed one at a time, each with `scripts/test.sh` passing
- [x] Any change to a recorded decision or level parameter recorded in
      `docs/architecture/README.md`
- [x] Adler-32's rate measured, and whether `simd fn` applies recorded
- [x] `LEVELS="1 6 9" bench/run.sh` recorded in `docs/results.md`, with machine, OS,
      compiler, command, corpus, and run count (M1 Pro at `ce13855`)
- [x] Compiler and stdlib gaps found recorded in `docs/goose-findings.md`, and
      environment traps in `docs/development.md`
