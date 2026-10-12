# Results

The package against libdeflate and zlib-ng. Each section names its machine; numbers from
different machines aren't compared. How to run them is in
[development.md](development.md#benchmark).

## Machine

- MacBook Pro `MacBookPro18,3`, Apple M1 Pro (8 performance and 2 efficiency cores),
  macOS 26.3.1 (Darwin 25.3.0).
- Goose `5c83a5a`, `goose build` defaults (`-O2`), with Apple clang 21.0.0
  (`clang-2100.0.123.102`).
- libdeflate v1.26 and zlib-ng 2.3.3, CMake `Release` builds with their default
  options, which pick each CPU's fastest code at run time; `bench/ref.c` at `-O2`, same
  compiler.

## Level 0: stored blocks

2026-10-12, task 001 step 1, package at its first commit. `bench/run.sh` defaults: gzip
output, one-shot, the whole file in memory, 10 runs per cell, Silesia corpus files.
MB/s is 10^6 bytes of input per second, median of the 10 runs; ratio is output over
input.

| File | MB | goose | libdeflate | zlib-ng |
|---|---:|---:|---:|---:|
| dickens | 10.2 | 344.5 | 25,104.5 | 7,375.1 |
| webster | 41.5 | 344.4 | 20,970.5 | 7,044.8 |
| xml | 5.3 | 344.2 | 32,007.6 | 7,184.5 |
| nci | 33.6 | 343.1 | 21,830.5 | 7,223.6 |
| mozilla | 51.2 | 341.7 | 20,949.1 | 7,136.8 |
| samba | 21.6 | 342.7 | 21,038.4 | 7,001.4 |
| x-ray | 8.5 | 343.0 | 28,437.1 | 7,407.6 |

The ratio is 1.000 for all three. Goose loses every cell: 20 times slower than zlib-ng
and 60 to 90 times slower than libdeflate. Storing is a copy, so the rate is CRC-32's.
The package computes it a byte at a time from a table; both libraries use the CPU's
carryless multiply, which Goose can't reach
([findings](goose-findings.md#goose-has-no-carryless-multiply)).

The package stores at every level for now. For scale, on `dickens` with 3 runs, level 1
gave libdeflate 225 MB/s at ratio 0.414 and zlib-ng 200 MB/s at 0.591; level 6 gave
libdeflate 70 MB/s at 0.379 and zlib-ng 75 MB/s at 0.382.
