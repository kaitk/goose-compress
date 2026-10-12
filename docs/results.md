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

At step 1 the package stored at every level. For scale, on `dickens` with 3 runs, level 1
gave libdeflate 225 MB/s at ratio 0.414 and zlib-ng 200 MB/s at 0.591; level 6 gave
libdeflate 70 MB/s at 0.379 and zlib-ng 75 MB/s at 0.382.

## Levels 1 and 6: LZ77 with the fixed Huffman tables

2026-10-12, task 001 step 2: one hash probe a position, greedy matching, and each block
coded with the fixed tables or stored. The package's levels 1 and 6 are the same
encoder. zlib-ng's level 1 (`deflate_quick`) also codes with the fixed tables, and
libdeflate's codes dynamic ones; at level 6 both code dynamic tables and match lazily
over hash chains. `LEVELS="1 6" bench/run.sh`: gzip output, one-shot, the
whole file in memory, 10 runs per cell, same machine, compilers, and libraries as
above. MB/s is the median of the 10 runs.

### Level 1

| File | MB | goose ratio | libdeflate ratio | zlib-ng ratio | goose MB/s | libdeflate MB/s | zlib-ng MB/s |
|---|---:|---:|---:|---:|---:|---:|---:|
| dickens | 10.2 | 0.547 | 0.414 | 0.591 | 88.1 | 229.0 | 200.1 |
| webster | 41.5 | 0.421 | 0.327 | 0.456 | 96.6 | 262.6 | 239.4 |
| xml | 5.3 | 0.244 | 0.166 | 0.221 | 134.9 | 467.1 | 462.6 |
| nci | 33.6 | 0.149 | 0.114 | 0.161 | 158.9 | 588.2 | 591.3 |
| mozilla | 51.2 | 0.453 | 0.394 | 0.468 | 95.8 | 241.0 | 241.8 |
| samba | 21.6 | 0.326 | 0.272 | 0.349 | 116.6 | 336.8 | 316.4 |
| x-ray | 8.5 | 0.920 | 0.743 | 0.929 | 65.4 | 144.0 | 126.7 |

Goose loses every rate: 1.9 to 3.7 times slower than zlib-ng, and 2.2 to 3.7 times
slower than libdeflate. With the same fixed tables, its output is smaller than
zlib-ng's on six files of seven, all but `xml`. libdeflate's dynamic tables give output
smaller than the package's on all seven, by 13 to 32 percent. CRC-32, at 345 MB/s, takes about a quarter of the
package's time on `dickens`; the rest is matching and coding a symbol at a time,
which step 4 takes on.

### Level 6

| File | MB | goose ratio | libdeflate ratio | zlib-ng ratio | goose MB/s | libdeflate MB/s | zlib-ng MB/s |
|---|---:|---:|---:|---:|---:|---:|---:|
| dickens | 10.2 | 0.547 | 0.379 | 0.382 | 88.4 | 69.8 | 75.1 |
| webster | 41.5 | 0.421 | 0.293 | 0.294 | 96.8 | 95.9 | 90.6 |
| xml | 5.3 | 0.244 | 0.128 | 0.128 | 135.5 | 175.6 | 172.2 |
| nci | 33.6 | 0.149 | 0.092 | 0.094 | 157.4 | 214.2 | 214.0 |
| mozilla | 51.2 | 0.453 | 0.367 | 0.379 | 96.7 | 106.4 | 90.9 |
| samba | 21.6 | 0.326 | 0.247 | 0.255 | 116.0 | 127.4 | 122.3 |
| x-ray | 8.5 | 0.920 | 0.708 | 0.741 | 65.3 | 104.2 | 66.7 |

Goose loses every ratio, with 20 to 91 percent more output than zlib-ng: its level 6 is
its level 1. It beats both libraries' rate on `dickens` and `webster` and zlib-ng's
on `mozilla`, only because it does a level 1's work. Dynamic tables (step 3) and lazy
matching (step 4) are what this level is waiting on.
