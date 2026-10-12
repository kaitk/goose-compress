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

## Levels 1 and 6: dynamic Huffman tables

2026-10-12, task 001 step 3: the step 2 matcher, and each block coded with a dynamic
code built from its symbol counts, the fixed code, or stored, whichever takes the fewest
bits. The package's levels 1 and 6 are still the same encoder. `LEVELS="1 6"
bench/run.sh`: gzip output, one-shot, the whole file in memory, 10 runs per cell, same
machine, compilers, and libraries as above. MB/s is the median of the 10 runs.

### Level 1

| File | MB | goose ratio | zlib-ng ratio | libdeflate ratio | goose MB/s | zlib-ng MB/s | libdeflate MB/s |
|---|---:|---:|---:|---:|---:|---:|---:|
| dickens | 10.2 | 0.429 | 0.591 | 0.414 | 83.2 | 191.2 | 218.3 |
| webster | 41.5 | 0.345 | 0.456 | 0.327 | 91.7 | 233.6 | 256.5 |
| xml | 5.3 | 0.200 | 0.221 | 0.166 | 129.3 | 455.9 | 451.8 |
| nci | 33.6 | 0.123 | 0.161 | 0.114 | 146.0 | 575.3 | 552.3 |
| mozilla | 51.2 | 0.401 | 0.468 | 0.394 | 88.5 | 237.5 | 239.2 |
| samba | 21.6 | 0.281 | 0.349 | 0.272 | 112.4 | 315.1 | 334.0 |
| x-ray | 8.5 | 0.753 | 0.929 | 0.743 | 60.4 | 125.0 | 141.3 |

The package's output is smaller than zlib-ng's on all seven files, and larger than
libdeflate's on all seven, by 1.3 percent on `x-ray` to 20 percent on `xml`; at step 2
libdeflate's was 13 to 32 percent smaller. Goose loses every rate: 2.1 to 3.9 times
slower than zlib-ng, and 2.3 to 3.8 times slower than libdeflate. Its rates are 3 to 8
percent below step 2's. Counting and building the codes costs some of that; the
libraries also ran about 4 percent slower than in the step 2 session, so part of it is
the machine.

### Level 6

| File | MB | goose ratio | zlib-ng ratio | libdeflate ratio | goose MB/s | zlib-ng MB/s | libdeflate MB/s |
|---|---:|---:|---:|---:|---:|---:|---:|
| dickens | 10.2 | 0.429 | 0.382 | 0.379 | 83.2 | 71.2 | 67.3 |
| webster | 41.5 | 0.345 | 0.294 | 0.293 | 92.0 | 87.9 | 93.4 |
| xml | 5.3 | 0.200 | 0.128 | 0.128 | 128.5 | 169.6 | 170.3 |
| nci | 33.6 | 0.123 | 0.094 | 0.092 | 142.4 | 206.6 | 208.2 |
| mozilla | 51.2 | 0.401 | 0.379 | 0.367 | 90.4 | 90.1 | 105.3 |
| samba | 21.6 | 0.281 | 0.255 | 0.247 | 112.5 | 121.2 | 126.4 |
| x-ray | 8.5 | 0.753 | 0.741 | 0.708 | 60.6 | 65.3 | 102.3 |

Goose loses every ratio, with 2 to 56 percent more output than zlib-ng (20 to 91
percent at step 2). Its rate beats both libraries' on `dickens`, zlib-ng's on `webster`,
and ties zlib-ng's on `mozilla`, only because it still does a level 1's work. Lazy
matching over hash chains (step 4) is what this level is waiting on.

### Where blocks end

2026-10-12, task 001 step 3. Two choices were measured against each other: whether a
block ends at a slide that would drop its first bytes (so it can still be stored), and
how many symbols a block holds. Without the slide rule, a block runs on and only loses
the stored option once its first bytes are gone, as zlib's does. Each variant was built
with `goose build` and run as `build/bench/bench 1 FILE 3` on the same machine: level 1,
gzip, one-shot. Output sizes don't vary between runs. The variants' median rates were
within 6 percent of each other on every file, in no consistent order.

| Variant | Stream holds | Output, 7 files | dickens | xml | mozilla | x-ray |
|---|---:|---:|---:|---:|---:|---:|
| Slide rule, 16,384 symbols | 262,484 B | 56,897,983 B | 0.4289 | 0.2002 | 0.4013 | 0.7533 |
| Slide rule, 32,768 symbols | 328,020 B | +0.02% | 0.4287 | 0.2003 | 0.4017 | 0.7521 |
| No slide rule, 16,384 | 262,484 B | +0.05% | 0.4288 | 0.2004 | 0.4020 | 0.7533 |
| No slide rule, 32,768 | 328,020 B | +0.26% | 0.4284 | 0.2014 | 0.4045 | 0.7521 |
| No slide rule, 65,536 | 459,092 B | +0.55% | 0.4282 | 0.2031 | 0.4071 | 0.7517 |

The 7 files hold 171,850,994 bytes. The current choice, the slide rule and 16,384
symbols, gives the least output in all and holds the least memory. Larger blocks help
text by under 0.2 percent and cost mixed files more (`mozilla` 1.4 percent at 65,536),
because a smaller block's code follows the data more closely; a dynamic header of a few
dozen bytes is small beside a block of 16,384 symbols.
