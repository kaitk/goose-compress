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

| File | MB | goose | zlib-ng | libdeflate |
|---|---:|---:|---:|---:|
| dickens | 10.2 | 344.5 | 7,375.1 | 25,104.5 |
| webster | 41.5 | 344.4 | 7,044.8 | 20,970.5 |
| xml | 5.3 | 344.2 | 7,184.5 | 32,007.6 |
| nci | 33.6 | 343.1 | 7,223.6 | 21,830.5 |
| mozilla | 51.2 | 341.7 | 7,136.8 | 20,949.1 |
| samba | 21.6 | 342.7 | 7,001.4 | 21,038.4 |
| x-ray | 8.5 | 343.0 | 7,407.6 | 28,437.1 |

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

| File | MB | goose ratio | zlib-ng ratio | libdeflate ratio | goose MB/s | zlib-ng MB/s | libdeflate MB/s |
|---|---:|---:|---:|---:|---:|---:|---:|
| dickens | 10.2 | 0.547 | 0.591 | 0.414 | 88.1 | 200.1 | 229.0 |
| webster | 41.5 | 0.421 | 0.456 | 0.327 | 96.6 | 239.4 | 262.6 |
| xml | 5.3 | 0.244 | 0.221 | 0.166 | 134.9 | 462.6 | 467.1 |
| nci | 33.6 | 0.149 | 0.161 | 0.114 | 158.9 | 591.3 | 588.2 |
| mozilla | 51.2 | 0.453 | 0.468 | 0.394 | 95.8 | 241.8 | 241.0 |
| samba | 21.6 | 0.326 | 0.349 | 0.272 | 116.6 | 316.4 | 336.8 |
| x-ray | 8.5 | 0.920 | 0.929 | 0.743 | 65.4 | 126.7 | 144.0 |

Goose loses every rate: 1.9 to 3.7 times slower than zlib-ng, and 2.2 to 3.7 times
slower than libdeflate. With the same fixed tables, its output is smaller than
zlib-ng's on six files of seven, all but `xml`. libdeflate's dynamic tables give output
smaller than the package's on all seven, by 13 to 32 percent. CRC-32, at 345 MB/s, takes about a quarter of the
package's time on `dickens`; the rest is matching and coding a symbol at a time,
which step 4 takes on.

### Level 6

| File | MB | goose ratio | zlib-ng ratio | libdeflate ratio | goose MB/s | zlib-ng MB/s | libdeflate MB/s |
|---|---:|---:|---:|---:|---:|---:|---:|
| dickens | 10.2 | 0.547 | 0.382 | 0.379 | 88.4 | 75.1 | 69.8 |
| webster | 41.5 | 0.421 | 0.294 | 0.293 | 96.8 | 90.6 | 95.9 |
| xml | 5.3 | 0.244 | 0.128 | 0.128 | 135.5 | 172.2 | 175.6 |
| nci | 33.6 | 0.149 | 0.094 | 0.092 | 157.4 | 214.0 | 214.2 |
| mozilla | 51.2 | 0.453 | 0.379 | 0.367 | 96.7 | 90.9 | 106.4 |
| samba | 21.6 | 0.326 | 0.255 | 0.247 | 116.0 | 122.3 | 127.4 |
| x-ray | 8.5 | 0.920 | 0.741 | 0.708 | 65.3 | 66.7 | 104.2 |

Goose loses every ratio, with 20 to 91 percent more output than zlib-ng: its level 6 is
its level 1. It beats both libraries' rate on `dickens` and `webster` and zlib-ng's
on `mozilla`, only because it does a level 1's work. Dynamic tables (step 3) and lazy
matching (step 4) are what this level is waiting on.
