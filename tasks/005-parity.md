# 005: Parity with the C libraries, Ryzen first

Status: in-progress

Measure and close the DEFLATE and zstd performance gaps against the C libraries on
an AMD Ryzen 7 5800X3D under Windows (requested 2026-10-13). If the Goose encoders
cannot reach parity, decide whether to replace them with C-library proxies. The
package remains pure Goose until that decision is recorded.

## Current results

Steps 1 to 3 are complete; zstd tuning in step 5 is in progress (2026-10-14).
The [latest results](../docs/results.md#amd-ryzen-7-5800x3d-windows) give the
hardware, tools, corpus, commands, and run counts:

- DEFLATE at `8ec4538`: level 1 runs at 0.56 to 0.66 of libdeflate's rate for output
  within 0.2 percent of its size; level 6 at 0.74 to 0.88; level 9 at 0.85 to 1.12,
  within 1 percent of libdeflate or faster on six files of seven.
- zstd at `7a96425`: libzstd is 1.32 to 1.40 times faster at level 1 on six files and
  1.03 times on `x-ray`. Level 3 is within the previous run's noise: libzstd is
  1.11 to 1.26 times faster on six files; the package is faster on `x-ray`.

The [measurements behind each change](../docs/results-history.md#task-005-steps-2-and-3-simd-fn-and-the-codegen-ceiling)
record the hand-fixed C, matcher ports, code-generation experiments, and zstd tuning.

## Measured for every matcher change

A server gzips small bodies at level 1, so each matcher or block-coding change is
measured on the small JSON bodies in `bench/json/` as well as on Silesia, by
`bench/compare.sh` before and after it (requested 2026-10-23). A change that pays on
Silesia but costs the bodies isn't kept without a recorded reason. Their output
sizes are `test/deflate/json_bodies.goose`'s golden file.

## Remaining work

- zstd: FSE steps and `put_seqs`, and Huffman coding of literals. At `e1a9800`, they
  took 1.8 times libzstd's time per byte on `webster` and 1.7 times on `x-ray`,
  respectively; later changes and their gains are in
  [results history](../docs/results-history.md#task-005-zstds-literals-and-sequences-at-257090f).
- DEFLATE level 1: measure libdeflate's block layout, up to 64 KB of input or 8,192
  matches, with literals counted as runs and read from the window when written.
- DEFLATE matching: reduce per-position search cost on `x-ray`. Three-byte matches
  and adaptive minimum length improve output but cost up to 30 percent of the rate
  in the tested table layout; see the
  [prototypes](../docs/results-history.md#the-c-prototypes-behind-it).
- Add Intel ISA-L's `igzip` to `bench/` at levels 0 to 3, or record why it is excluded.
- Compare rate against output size across levels, and measure per-stream memory and
  peak RSS for the package, libdeflate, and zlib-ng.
- Decide whether to keep the Goose encoders or replace them with proxies.

## What counts as parity

Against libdeflate, compare the same level and report the output-size difference.
Against zlib-ng, compare rate at a matched output size: its level 1 uses fixed
Huffman tables and can produce substantially more output. Parity means the
rate-against-ratio curve on Silesia is no worse than either library's within
run-to-run noise. Apply the same rate and size comparison to zstd against libzstd.

Results must include output size against the reference library, rate against ratio,
and per-stream memory and peak RSS. `Encoder` holds 460,406 bytes and `ZstdEncoder`
1,010,955 bytes at every level; the comparison libraries' allocations and peak RSS
remain to be measured.

## Proxy decision

A proxy replaces an encoder whole. libdeflate has no streaming or sync flush, so a
DEFLATE `Encoder` proxy would need zlib-ng; one-shot `compress` could use libdeflate.
A proxy reverses the pure-Goose architecture decision and the rule on C in `AGENTS.md`,
so any implementation starts on a separate branch after the decision and its evidence
are recorded in [decisions](../docs/decisions.md).

## Acceptance criteria

- [x] Goose pin checked and the Ryzen baseline recorded with its measurement method
- [x] `simd fn` bit-scan behavior checked and the result recorded
- [x] Hand-fixed C measured against libdeflate and the outcome recorded
- [ ] Each change measured independently, kept or not, in `docs/results-history.md`
- [ ] `igzip` added or its exclusion explained
- [ ] zstd levels 1 and 3 measured on the Ryzen, with each proposed improvement measured
- [ ] Parity reached at DEFLATE levels 1, 6, and 9 and zstd's gap closed or measured,
      or a proxy decision recorded with its evidence
- [ ] Results include rate against ratio, per-stream memory, and peak RSS
- [ ] Compiler and stdlib gaps found recorded in `docs/goose-findings.md`
