# Results

The package against libdeflate and zlib-ng. Each machine has a section of its own, which
starts with how the machine and its tools were set up; numbers from different machines
aren't compared. How to run them is in [development.md](development.md#benchmark).

- [Apple M1 Pro, macOS](#apple-m1-pro-macos)
- [AMD Ryzen 7 5800X3D, Windows](#amd-ryzen-7-5800x3d-windows)

## Apple M1 Pro, macOS

- MacBook Pro `MacBookPro18,3`, Apple M1 Pro (8 performance and 2 efficiency cores),
  macOS 26.3.1 (Darwin 25.3.0).
- Goose `5c83a5a`, `goose build` defaults (`-O2`), with Apple clang 21.0.0
  (`clang-2100.0.123.102`).
- libdeflate v1.26 and zlib-ng 2.3.3, CMake `Release` builds with their default
  options, which pick each CPU's fastest code at run time; `bench/ref.c` at `-O2`, same
  compiler.

### Level 0: stored blocks

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

### Levels 1 and 6: LZ77 with the fixed Huffman tables

2026-10-12, task 001 step 2: one hash probe a position, greedy matching, and each block
coded with the fixed tables or stored. The package's levels 1 and 6 are the same
encoder. zlib-ng's level 1 (`deflate_quick`) also codes with the fixed tables, and
libdeflate's codes dynamic ones; at level 6 both code dynamic tables and match lazily
over hash chains. `LEVELS="1 6" bench/run.sh`: gzip output, one-shot, the
whole file in memory, 10 runs per cell, same machine, compilers, and libraries as
above. MB/s is the median of the 10 runs.

#### Level 1

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

#### Level 6

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

### Levels 1 and 6: dynamic Huffman tables

2026-10-12, task 001 step 3: the step 2 matcher, and each block coded with a dynamic
code built from its symbol counts, the fixed code, or stored, whichever takes the fewest
bits. The package's levels 1 and 6 are still the same encoder. `LEVELS="1 6"
bench/run.sh`: gzip output, one-shot, the whole file in memory, 10 runs per cell, same
machine, compilers, and libraries as above. MB/s is the median of the 10 runs.

#### Level 1

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

#### Level 6

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

#### Where blocks end

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

### Levels 1, 6, and 9: step 4

2026-10-12, task 001 step 4, package at `a4c86dd`: CRC-32 by slice-by-16, the 8-byte
bit writer, the 4-byte candidate check, and at levels 2 to 9 hash chains, lazy from
level 5, with libdeflate's parameters. `LEVELS="1 6 9" bench/run.sh`: gzip output,
one-shot, the whole file in memory, 10 runs per cell, same machine, compilers, and
libraries as above. MB/s is the median of the 10 runs. Desktop apps ran beside it, at
a load average of 5.1 to 5.8, and no other benchmark.

#### Level 1

| File | MB | goose ratio | zlib-ng ratio | libdeflate ratio | goose MB/s | zlib-ng MB/s | libdeflate MB/s |
|---|---:|---:|---:|---:|---:|---:|---:|
| dickens | 10.2 | 0.429 | 0.591 | 0.414 | 159.3 | 199.1 | 227.9 |
| webster | 41.5 | 0.345 | 0.456 | 0.327 | 177.7 | 241.2 | 264.7 |
| xml | 5.3 | 0.200 | 0.221 | 0.166 | 285.8 | 460.8 | 469.5 |
| nci | 33.6 | 0.123 | 0.161 | 0.114 | 350.7 | 601.6 | 593.9 |
| mozilla | 51.2 | 0.401 | 0.468 | 0.394 | 170.4 | 242.5 | 244.2 |
| samba | 21.6 | 0.281 | 0.349 | 0.272 | 224.8 | 318.6 | 339.5 |
| x-ray | 8.5 | 0.753 | 0.929 | 0.743 | 112.2 | 127.1 | 144.0 |

Goose loses every rate: 1.1 to 1.7 times slower than zlib-ng and 1.3 to 1.7 times
slower than libdeflate, against 2.1 to 3.9 times at step 3. Its rate rose 86 to 140
percent over step 3's (83.2 to 159.3 MB/s on `dickens`, 60.4 to 112.2 on `x-ray`).
The output is as at step 3, but for a few bytes: smaller than zlib-ng's on all seven
files, and 1.3 to 20 percent larger than libdeflate's.

#### Level 6

| File | MB | goose ratio | zlib-ng ratio | libdeflate ratio | goose MB/s | zlib-ng MB/s | libdeflate MB/s |
|---|---:|---:|---:|---:|---:|---:|---:|
| dickens | 10.2 | 0.379 | 0.382 | 0.379 | 43.3 | 75.1 | 69.7 |
| webster | 41.5 | 0.294 | 0.294 | 0.293 | 61.1 | 91.2 | 97.0 |
| xml | 5.3 | 0.129 | 0.128 | 0.128 | 113.0 | 177.4 | 175.3 |
| nci | 33.6 | 0.093 | 0.094 | 0.092 | 114.2 | 217.6 | 218.0 |
| mozilla | 51.2 | 0.378 | 0.379 | 0.367 | 61.7 | 91.8 | 107.4 |
| samba | 21.6 | 0.252 | 0.255 | 0.247 | 78.7 | 123.9 | 129.6 |
| x-ray | 8.5 | 0.738 | 0.741 | 0.708 | 49.3 | 66.8 | 104.3 |

Level 6 is no longer level 1: it gives 2 to 35 percent less output than level 1
(`dickens` 0.429 to 0.379, `xml` 0.200 to 0.129). Its output is smaller than
zlib-ng's on five files, the same on `webster`, and 1 percent larger on `xml`; against
libdeflate's it ties on `dickens` and is up to 4 percent larger, on `x-ray`. Goose
loses every rate: 1.3 to 1.9 times slower than zlib-ng and 1.5 to 2.1 times slower
than libdeflate. At step 3 it lost every ratio, by 2 to 56 percent against zlib-ng.

#### Level 9

| File | MB | goose ratio | zlib-ng ratio | libdeflate ratio | goose MB/s | zlib-ng MB/s | libdeflate MB/s |
|---|---:|---:|---:|---:|---:|---:|---:|
| dickens | 10.2 | 0.374 | 0.379 | 0.374 | 21.8 | 30.6 | 34.7 |
| webster | 41.5 | 0.287 | 0.292 | 0.287 | 25.7 | 45.6 | 40.2 |
| xml | 5.3 | 0.122 | 0.124 | 0.122 | 37.7 | 84.1 | 67.8 |
| nci | 33.6 | 0.088 | 0.089 | 0.087 | 24.0 | 73.4 | 58.1 |
| mozilla | 51.2 | 0.376 | 0.372 | 0.365 | 15.7 | 26.5 | 27.3 |
| samba | 21.6 | 0.249 | 0.250 | 0.244 | 25.9 | 51.0 | 43.5 |
| x-ray | 8.5 | 0.738 | 0.703 | 0.706 | 46.5 | 41.3 | 90.7 |

Goose's output is smaller than zlib-ng's on five files and larger on `mozilla` (1
percent) and `x-ray` (5 percent); it ties libdeflate's on three text files and is up
to 4.5 percent larger elsewhere. It beats zlib-ng's rate on `x-ray`, 46.5 MB/s against
41.3, and loses every other rate: 1.4 to 3.1 times slower than zlib-ng and 1.6 to 2.4
times slower than libdeflate. On `x-ray` level 9 gives the same output as level 6,
and libdeflate's is 4.5 percent smaller. libdeflate also finds matches of length 3
and chooses block boundaries from the data, which the package doesn't; which of them
accounts for `x-ray` is untested.

#### Small inputs

2026-10-12, task 001 step 4, same machine and package. A program built with `goose
build` calls `compress::compress` (gzip) on the first N bytes of `dickens` 20,000,000 /
(N + 2,000) times in a row, 5 times over; a cell is the best of the 5 averages, in µs
a call.

| Level | 100 bytes | 1,000 bytes | 10,000 bytes |
|---:|---:|---:|---:|
| 1 | 23.9 | 27.8 | 62.7 |
| 6 | 24.5 | 31.7 | 136.1 |

At step 3's 262,484-byte stream, level 1 took 20.2, 23.9, and 66.9 µs. `sample` put
three quarters of the 100-byte call in building the `Encoder`, zeroing and copying it
([findings](goose-findings.md#a-struct-literal-copies-each-nested-fixed-array-whole)).

### Step 4: each change, measured on its own

2026-10-12, task 001 step 4. Each change was built with `goose build` into a binary of
its own and run against the build before it as `bench LEVEL FILE RUNS`, gzip, one-shot,
in 3 alternating rounds on the same machine; a cell is the best of the 3 rounds'
medians, in MB/s. `RUNS` was 5 until hash chains, 3 after. Two builds of the same code
differed by under 1 percent. The machine ran a virtual machine and desktop apps
throughout, at a load average of 5 to 7. Output sizes don't vary between runs; where a
change kept the bytes, only rates are shown.

| Change | Level | dickens | mozilla | x-ray | xml | Kept |
|---|---:|---|---|---|---|---|
| CRC-32 by slice-by-8 | 0 | 348 → 1,815 | | 346 → 1,840 | | |
| Slice-by-16 instead | 0 | 1,802 → 2,830 | | 1,826 → 2,874 | | yes |
| Table lookups for length and distance codes | 1 | 111.9 → 110.4 | 120.5 → 120.3 | 73.5 → 73.0 | 203.1 → 203.6 | no |
| Append 32 bits at once | 1 | 111.6 → 125.3 | 119.5 → 133.6 | 72.9 → 82.4 | 200.5 → 224.3 | yes |
| Code symbols with 8-byte stores | 1 | 126.7 → 134.3 | 133.5 → 141.2 | 82.3 → 85.2 | 226.4 → 242.4 | yes |
| The code tables again, after both | 1 | 134.7 → 137.4 | 141.5 → 143.2 | 85.6 → 86.2 | 242.3 → 241.8 | no |
| 8-byte match compare, with std's `ctz` | 1 | 134.3 → 115.0 | 142.2 → 126.3 | 86.3 → 75.4 | 242.6 → 222.1 | no |
| Compare the 4 hashed bytes first | 1 | 135.3 → 157.8 | 141.8 → 167.0 | 85.1 → 108.2 | 243.5 → 282.0 | yes |
| Then 8-byte extension, de Bruijn `ctz` | 1 | 157.8 → 136.3 | 165.8 → 159.9 | 107.6 → 104.9 | 286.7 → 269.3 | no |
| Then 8-byte extension, byte shifts | 1 | 157.5 → 155.2 | 166.2 → 168.7 | 107.6 → 108.5 | 282.1 → 290.2 | no |
| The same, after hash chains | 6 | 41.8 → 40.4 | 58.2 → 57.1 | 43.7 → 42.4 | 110.3 → 111.7 | no |
| The same, after hash chains | 9 | 20.9 → 20.2 | 15.3 → 15.7 | 40.9 → 39.9 | 37.3 → 39.2 | no |
| Load the next hash bucket early | 6 | 40.0 → 41.6 | 57.7 → 60.4 | 43.3 → 48.4 | 108.7 → 111.5 | yes |

Slice-by-16 also took level 1 from 87 to 110 MB/s on `dickens` and from 134 to 195 on
`xml`. Comparing the 4 hashed bytes first turns away a candidate from an empty bucket
whose first 3 bytes happen to match the stream's start, so it gave 1 to 2 bytes less
output on `dickens` and `mozilla`. The 8-byte compare lost with std's `ctz` because
`ctz` is a loop ([findings](goose-findings.md#clz-ctz-and-popcount-loop-over-the-bits)),
and without it moved rates by -3 to +5 percent, about the noise. Matches are short (at
level 6, the candidates extended on `dickens` match 5.7 bytes on average), and at
levels 6 and 9 the time goes into walking the chains.

#### Choices that trade ratio for rate

Same method. Output in bytes, rate in MB/s.

Hashing the positions inside a match, at level 1:

| File | Every position | None | Inside matches up to 32 bytes |
|---|---|---|---|
| dickens | 4,371,843 at 158.1 | 4,703,515 at 147.4 | 4,372,121 at 157.1 |
| mozilla | 20,556,637 at 167.1 | 21,238,427 at 183.7 | 20,620,251 at 169.0 |
| nci | 4,137,911 at 349.2 | 4,483,828 at 427.9 | 4,247,203 at 409.4 |
| samba | 6,072,417 at 221.2 | 6,500,387 at 241.5 | 6,134,154 at 229.9 |
| webster | 14,305,204 at 173.6 | 15,441,882 at 175.8 | 14,339,385 at 174.9 |
| x-ray | 6,383,613 at 108.9 | 6,463,921 at 104.6 | 6,383,621 at 108.9 |
| xml | 1,070,353 at 281.1 | 996,096 at 342.6 | 1,027,612 at 307.4 |

"None" ran against a round of "every position" at 156.4, 165.7, 349.1, 220.3, 174.0,
108.0, and 275.3. Every position is hashed: skipping them all gives 3 to 8 percent more
output on six files, and the 32-byte cut pays only on `nci` and `xml`, which level 1
already compresses fastest.

A hash table of 2^16 entries instead of 2^15, 131,072 more bytes a stream: at level 6,
`dickens` 41.9 → 42.0, `mozilla` 58.2 → 62.7, `x-ray` 43.8 → 52.4, and `xml` 109.9 →
111.3 MB/s, with output under 0.01 percent smaller. At level 1, output 0.3 to 0.8
percent smaller (`dickens` 4,371,843 → 4,342,576, `x-ray` 6,383,613 → 6,332,212) at
the same rate. Not taken: the gain is on two files of four, for 40 percent more
memory.

Search depth and nice length at level 6, with the next bucket loaded early, against
both libraries in the same rounds (ratio at MB/s). This ran after the per-change
measurements, with no virtual machine running, at a load average of 4.4 to 5.8:

| Depth, nice | dickens | mozilla | samba | x-ray | xml |
|---|---|---|---|---|---|
| 8, 16 | 0.3883 at 70.2 | 0.3825 at 89.1 | 0.2581 at 124.0 | 0.7383 at 50.3 | 0.1449 at 184.0 |
| 16, 32 | 0.3826 at 55.5 | 0.3798 at 75.2 | 0.2535 at 99.3 | 0.7383 at 49.7 | 0.1349 at 146.7 |
| 24, 48 | 0.3804 at 49.0 | 0.3789 at 68.3 | 0.2523 at 88.7 | 0.7383 at 50.0 | 0.1309 at 129.3 |
| 35, 65 (libdeflate's) | 0.3790 at 43.4 | 0.3782 at 61.7 | 0.2515 at 79.3 | 0.7383 at 49.9 | 0.1288 at 112.8 |
| zlib-ng 6 | 0.3822 at 75.5 | 0.3791 at 91.7 | 0.2546 at 123.3 | 0.7412 at 66.8 | 0.1276 at 175.4 |
| libdeflate 6 | 0.3787 at 70.8 | 0.3671 at 107.3 | 0.2470 at 129.0 | 0.7078 at 104.6 | 0.1280 at 179.1 |

In an earlier run under more load, nice 128 at depth 35 gave 0.1 to 0.5 percent less
output than nice 65 on `samba` and `xml`, 2 to 4 percent slower. Level 6 keeps
libdeflate's 35 and 65. No depth reaches zlib-ng's rate at its ratio: at depth 8 the
package is 7 percent slower than zlib-ng on `dickens` and 5 percent faster on `xml`,
with 1.6 and 13.6 percent more output. `x-ray`'s rate doesn't move with depth: its
chains are short (1.2 candidates a search), and its time goes into the search's fixed
cost.

The two changes nearest the noise were run again in the same session, against the
build with every kept change (MB/s, best of 3 rounds' medians):

| Variant | Level | dickens | mozilla | x-ray | xml |
|---|---:|---|---|---|---|
| Kept build | 1 | 160.0 | 170.4 | 113.0 | 283.9 |
| Code tables | 1 | 164.4 | 171.5 | 111.1 | 292.7 |
| 8-byte extension, byte shifts | 1 | 154.4 | 167.7 | 108.4 | 291.4 |
| Kept build | 6 | 43.8 | 61.5 | 49.7 | 113.6 |
| Code tables | 6 | 44.0 | 62.1 | 49.9 | 113.8 |
| 8-byte extension, byte shifts | 6 | 41.8 | 60.3 | 47.2 | 114.7 |

The tables stay out, at -1.7 to +3.1 percent; the 8-byte extension loses on three
files of four at both levels.

### Task 003: each change, measured on its own

2026-10-12, task 003, Goose `c38dc0f`, same machine, compilers, and libraries. Each
change was built with `goose build` into a binary of its own and run against the build
before it as `bench LEVEL FILE 3`, gzip, one-shot, in 3 alternating rounds; a cell is
the best of the 3 rounds' medians, in MB/s. Desktop apps and another agent session ran
beside it, at a load average of 3.9 to 7.2, and no other benchmark. Where a change kept
the bytes, only rates are shown.

Where the time goes first, by `sample` (4 s each) and, for `search`, by `xctrace`'s Time
Profiler at the instruction level:

| Share of time | Level 6 `x-ray` | Level 6 `dickens` | Level 1 `dickens` |
|---|---:|---:|---:|
| `search`, with `insert` inlined | 80% | 82% | |
| `match_chains`, the lazy loop and skip-insertion | 6% | 9% | |
| `lz_write`, level 1's matching inlined | | | 61% |
| `end_block`: coding the symbols (`put_syms`) | 11% | 7% | 17% |
| `end_block`: counting symbols, sizing the three forms | | | 13% |
| Building the codes, sorting, the header | 2% | 1% | 2% |
| CRC-32, inlined into `main` | 2% | 1% | 5% |

At level 6 the `end_block` rows aren't split; level 1's split came from a copy of the C
with `put_syms` kept out of line. Inside `search` on `x-ray`, 44 percent of its samples
fell where the loop's exits land, against no instruction above 7 percent in libdeflate's
`deflate_compress_lazy` on the same file.

| Change | Level | dickens | mozilla | x-ray | xml | Kept |
|---|---:|---|---|---|---|---|
| Test the 4 bytes ending at the best length, then the 4 hashed, as libdeflate does | 6 | 43.4 → 42.1 | 61.3 → 61.6 | 49.1 → 48.0 | 112.9 → 114.8 | no |
| 2^16 hash buckets of `u16` offsets, in the same 128 KB | 6 | 43.4 → 42.5 | 61.2 → 51.0 | 49.2 → 50.3 | 112.7 → 99.9 | no |
| One unsigned range test ends a chain; `nice` passed in | 6 | 43.2 → 43.5 | 61.4 → 63.4 | 49.4 → 53.9 | 112.2 → 112.4 | yes |
| The same, run again | 6 | | 61.3 → 63.3 | 49.2 → 53.8 | | |
| The same | 9 | 21.7 → 21.8 | | 46.9 → 50.8 | 37.5 → 37.9 | |
| The same, under `LC_ALL=C` | 6 | 43.4 → 43.7 | 61.0 → 63.5 | 49.0 → 53.7 | 112.4 → 112.6 | |

The `u16` table gave 488 to 595 bytes less output, but its offsets wrap every 64 KB, so
stale entries pass the distance test and cost a full probe, where the `u32` table turns
them away before any compare.

The rows above the last chose each cell's best round under a decimal-comma locale, in
which `awk` compared only the whole MB/s, so a cell may be a round up to 1 MB/s short
of the best. The last row is the range test run again with that fixed.

The Ryzen's changes, run here against the build before each (same method, under
`LC_ALL=C`, at a load average of 4.2 to 7.7):

| Change | Level | dickens | mozilla | x-ray | xml |
|---|---:|---|---|---|---|
| Length and distance codes from tables (`43cb937`) | 1 | 155.9 → 162.5 | 166.7 → 169.2 | 109.0 → 109.5 | 278.6 → 287.5 |
| The same | 6 | 43.7 → 44.1 | 63.6 → 63.9 | 53.6 → 54.2 | 111.8 → 113.1 |
| 2^16 buckets, and `compress` resetting one encoder (`042d72a`) | 1 | 163.0 → 164.0 | 172.2 → 175.6 | 109.0 → 106.7 | 289.5 → 295.1 |
| The same | 6 | 44.1 → 45.0 | 63.8 → 68.2 | 54.0 → 67.5 | 113.0 → 114.3 |

Both hold here. The tables gain 0.5 to 4.2 percent at level 1, where task 001 step 4
measured -1.7 to +3.1 percent. The 2^16 buckets make level 6 25 percent faster on
`x-ray` and 7 percent faster on `mozilla`, as task 001 step 4 measured them.

#### Small inputs

The Ryzen's method: a program built with `goose build` calls `compress::compress`
(gzip) on the first N bytes of `dickens` 20,000,000 / (N + 2,000) times in a row, 5
times over; a cell is the best of the 5 averages, in µs a call, over 3 alternating runs
of the two programs.

| Build | Level | 100 bytes | 1,000 bytes | 10,000 bytes |
|---|---:|---:|---:|---:|
| `43cb937`: a new `Encoder` a call | 1 | 23.8 | 27.0 | 59.1 |
| `042d72a`: one `Encoder`, `reset` a call | 1 | 7.8 | 11.4 | 42.5 |
| `43cb937` | 6 | 24.2 | 31.0 | 124.0 |
| `042d72a` | 6 | 8.1 | 14.9 | 102.5 |
| `042d72a` | 1 | 7.7 | 11.3 | 42.7 |
| `reset` leaving `syms` and `win` as they were | 1 | 6.6 | 10.2 | 43.2 |
| `042d72a` | 6 | 8.1 | 14.9 | 101.8 |
| `reset` leaving `syms` and `win` as they were | 6 | 7.0 | 13.7 | 111.1 |

`reset` takes a 100-byte call from 24 to 8 µs here, against 108 to 7.3 µs on the
Ryzen. Not clearing `syms` and `win` saves about 1.1 µs a call, but at 10,000 bytes
level 6 is 7 to 9 percent slower in each round; on whole Silesia files level 6 is
unchanged (-0.8 to +0.4 percent). The likely cause is that clearing the window left it
in the cache just before the input is copied in, after the 256 KB clear of the hash
table has pushed the rest out. Not kept.

#### After the Ryzen's changes

Same method as the changes above, under `LC_ALL=C`, at a load average of 6.3 to 6.7,
against `ededfce`:

| Change | Level | dickens | mozilla | x-ray | xml | Kept |
|---|---:|---|---|---|---|---|
| Count symbols as they're added, not in a pass at the block's end | 1 | 163.6 → 175.1 | 177.9 → 191.0 | 107.0 → 118.9 | 293.5 → 303.3 | yes |
| The same, run again | 1 | 162.7 → 176.5 | | 107.7 → 119.7 | | |
| The same | 6 | 44.9 → 45.7 | 68.0 → 69.7 | 66.9 → 69.4 | 112.6 → 116.3 | |

The counts add 1,272 bytes to a stream, 460,394 in all.

Then, against `d71eb59`, at a load average of 5.2 to 7.1:

| Change | Level | dickens | mozilla | x-ray | xml | Kept |
|---|---:|---|---|---|---|---|
| `search` returns length and distance packed in one value | 6 | 45.5 → 45.7 | 69.4 → 70.0 | 69.3 → 69.8 | 115.9 → 115.2 | no |
| Carry the next position's hash to the next search | 6 | 44.7 → 45.7 | 69.5 → 71.6 | 69.6 → 74.0 | 114.9 → 116.3 | yes |
| The same, run again | 6 | | 69.2 → 71.4 | 69.5 → 73.9 | | |
| The same | 9 | 22.5 → 22.7 | | 65.3 → 69.2 | 37.5 → 38.1 | |
| The same | 2 | 101.1 → 103.4 | | 75.7 → 80.1 | | |

The packed result moved rates by -0.6 to +0.9 percent: the second result was cheap.
The carried hash adds 12 bytes to a stream, 460,406 in all.

Then, against `1f1ed62`, at a load average of 4.2 to 5.5 (9.3 once, just after
`scripts/test.sh`):

| Change | Level | dickens | mozilla | x-ray | xml | Kept |
|---|---:|---|---|---|---|---|
| Also load the window byte the next search's first candidate starts at | 6 | 46.4 → 46.8 | 71.6 → 71.1 | 73.2 → 74.2 | 116.1 → 117.2 | no |
| Drop bounds checks: hash index, symbol store, `LEN_TAB`, `match_len` | 1 | 173.6 → 158.8 | 192.4 → 175.7 | 119.5 → 102.1 | 304.6 → 302.3 | no |
| The same | 6 | 46.2 → 46.7 | 71.3 → 73.1 | 74.6 → 73.9 | 116.9 → 121.8 | |
| Only the hash index masked to the table | 1 | 174.5 → 174.4 | | 119.0 → 119.9 | | no |
| The same | 6 | 46.2 → 46.0 | 70.7 → 70.9 | | 116.1 → 115.9 | |
| Only the symbol store and `LEN_TAB` masked | 1 | 173.4 → 158.3 | | 119.2 → 102.7 | | no |
| Only `match_len` slicing both runs first | 1 | 175.4 → 175.0 | | 120.0 → 120.4 | | yes |
| The same | 6 | 46.3 → 46.5 | 71.1 → 73.4 | | 116.0 → 123.0 | |
| The same, run again | 6 | | 71.1 → 72.9 | 73.4 → 73.4 | 114.7 → 121.9 | |
| The same | 9 | 22.6 → 22.8 | | 69.2 → 69.2 | 38.1 → 40.8 | |
| The same | 1 | | 192.2 → 194.1 | | 301.4 → 317.6 | |

Masking the symbol counter to `SYM_MAX` drops a bounds check that never fails, yet made
level 1 9 to 14 percent slower; how clang compiled the loop around it wasn't examined.
`match_len` keeps two slice checks a call in place of two index checks a byte.

Level 1 with the hash table as 2^15 buckets of 2 entries, as libdeflate's level 1
keeps them, in the same 256 KB: both candidates probed, the longer match taken. Against
`865d359`, same method, ratio at MB/s:

| Build | dickens | mozilla | x-ray | xml |
|---|---|---|---|---|
| 1 entry a bucket (`865d359`) | 0.4261 at 176.4 | 0.4003 at 195.7 | 0.7472 at 119.9 | 0.1997 at 317.2 |
| 2 entries a bucket | 0.4139 at 148.6 | 0.3936 at 152.5 | 0.7442 at 84.9 | 0.1650 at 279.9 |
| libdeflate 1 (step 4's run) | 0.414 at 227.9 | 0.394 at 244.2 | 0.743 at 144.0 | 0.166 at 469.5 |

Two entries reach libdeflate's level-1 ratio, with 0.4 to 17.4 percent less output,
and cost 12 to 29 percent of the rate. Not kept: this task is about rate, and level 2
already gives more ratio for less rate (`dickens` 0.398 at 103 MB/s).

## AMD Ryzen 7 5800X3D, Windows

- Desktop on an MSI `MS-7A34` board, AMD Ryzen 7 5800X3D (Zen 3, 8 cores, 16 threads,
  AVX2 and no AVX-512), 32 GB, Windows 11 Pro 10.0.26200.
- Goose `c38dc0f`, `goose build` defaults: `clang-cl` 22.1.3 at `/O2`, from Visual
  Studio Build Tools 2026 (18). `simd fn`s get an AVX2 version.
- libdeflate v1.26 and zlib-ng 2.3.3, CMake `Release` builds with Ninja and clang
  22.1.3 and their default options, which pick each CPU's fastest code at run time;
  `bench/ref.c` at `-O2`, same compiler.
- Run from Git Bash. Docker Desktop, a WSL distribution, and desktop apps ran beside
  the benchmarks, at about 13 percent CPU load before they started, and no other
  benchmark.

### Levels 0, 1, 6, and 9 at `540ae3c`

2026-10-12, task 003, package at `540ae3c`: task 001's encoder with Adler-32 as a
`simd fn`. `LEVELS="0 1 6 9" bench/run.sh`, then `FORMAT=zlib bench/run.sh`: one-shot,
the whole file in memory, 10 runs per cell. MB/s is the median of the 10 runs. The
ratios are the M1 Pro's at step 4, to the byte.

| File | MB | Level 0 goose | zlib-ng | libdeflate | Level 0 zlib goose | zlib-ng | libdeflate |
|---|---:|---:|---:|---:|---:|---:|---:|
| dickens | 10.2 | 2,672.8 | 17,369.5 | 19,158.7 | 13,195.8 | 43,335.2 | 24,703.0 |
| webster | 41.5 | 2,656.0 | 15,274.7 | 15,980.1 | 13,941.8 | 24,123.5 | 17,149.4 |
| xml | 5.3 | 2,514.1 | 17,209.5 | 16,693.6 | 9,876.7 | 42,355.6 | 21,441.2 |
| nci | 33.6 | 2,713.3 | 16,193.7 | 16,137.7 | 14,335.4 | 28,439.9 | 20,152.2 |
| mozilla | 51.2 | 2,640.4 | 15,134.7 | 13,620.3 | 13,134.8 | 20,419.6 | 16,175.7 |
| samba | 21.6 | 2,769.6 | 17,064.0 | 19,690.5 | 15,376.0 | 37,773.4 | 24,889.3 |
| x-ray | 8.5 | 2,629.8 | 17,266.2 | 18,882.0 | 12,111.2 | 43,060.2 | 24,115.7 |

Level 0 is a copy and the checksum. With CRC-32 (gzip), Goose is 5.2 to 7.2 times
slower than both libraries, which use the CPU's carryless multiply. With Adler-32
(zlib), it's 1.6 to 4.3 times slower than zlib-ng and 1.2 to 2.2 times slower than
libdeflate.

| File | Level 1 goose | zlib-ng | libdeflate | Level 6 goose | zlib-ng | libdeflate | Level 9 goose | zlib-ng | libdeflate |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| dickens | 84.6 | 284.7 | 259.0 | 36.3 | 66.6 | 74.0 | 18.9 | 27.5 | 32.5 |
| webster | 98.5 | 338.8 | 288.2 | 49.6 | 82.6 | 104.0 | 22.4 | 43.0 | 38.6 |
| xml | 143.7 | 684.6 | 505.3 | 91.1 | 163.3 | 189.2 | 35.3 | 79.7 | 64.0 |
| nci | 197.8 | 876.7 | 650.4 | 97.6 | 210.7 | 235.7 | 25.8 | 71.1 | 63.1 |
| mozilla | 115.7 | 313.5 | 268.6 | 54.0 | 92.4 | 117.3 | 16.9 | 27.7 | 31.5 |
| samba | 136.7 | 440.5 | 363.6 | 66.5 | 118.5 | 137.4 | 26.1 | 50.8 | 47.1 |
| x-ray | 103.3 | 158.0 | 159.7 | 47.7 | 74.7 | 120.7 | 43.2 | 43.4 | 101.9 |

Goose loses every rate. At level 1 it's 1.5 to 4.8 times slower than zlib-ng, and 1.5
to 3.5 times slower than libdeflate; on the M1 Pro it was 1.1 to 1.7 times slower than
either. At level 6 it's 1.6 to 2.2 times slower than zlib-ng and 2.0 to 2.5 times
slower than libdeflate; at level 9, 1.0 (`x-ray`) to 2.8 and 1.7 to 2.5 times. Both
libraries ran faster here than on the M1 Pro, and the package's level 1 at half the
rate: `bench` built in WSL on the same CPU with `--cc clang` ran level 1 on `dickens`
at 83.4 MB/s, so the cause is the x86-64 code, not Windows. `perf` there put 66 percent
of level 1's time in `end_block`, in a loop that shifts one bit an iteration: std's
`clz`, which clang turns into one instruction on arm64 but not on x86-64
([findings](goose-findings.md#clz-ctz-and-popcount-loop-over-the-bits)).

### Levels 1, 6, and 9 at `43cb937`

2026-10-12, task 003, package at `43cb937`: the chain search's one range test and the
code tables on top of `540ae3c`. `LEVELS="1 6 9" bench/run.sh`: gzip output, one-shot,
the whole file in memory, 10 runs per cell, same machine, compilers, and libraries.
MB/s is the median of the 10 runs; the ratios are as at `540ae3c`.

| File | Level 1 goose | zlib-ng | libdeflate | Level 6 goose | zlib-ng | libdeflate | Level 9 goose | zlib-ng | libdeflate |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| dickens | 174.3 | 284.4 | 261.7 | 47.7 | 66.9 | 74.8 | 22.1 | 27.5 | 32.9 |
| webster | 195.3 | 334.2 | 291.0 | 66.4 | 84.4 | 105.1 | 26.3 | 43.1 | 38.9 |
| xml | 306.5 | 671.9 | 504.9 | 117.8 | 163.1 | 188.6 | 39.6 | 79.9 | 64.3 |
| nci | 379.2 | 881.2 | 629.7 | 123.7 | 212.7 | 238.0 | 28.6 | 71.5 | 63.5 |
| mozilla | 192.1 | 316.5 | 268.4 | 70.2 | 92.3 | 119.0 | 18.7 | 27.6 | 31.4 |
| samba | 248.8 | 434.8 | 366.8 | 86.3 | 118.5 | 136.6 | 29.7 | 50.9 | 47.1 |
| x-ray | 129.8 | 158.1 | 160.5 | 60.7 | 74.3 | 119.1 | 58.0 | 43.3 | 101.6 |

Goose beats zlib-ng's rate on `x-ray` at level 9, 58.0 MB/s against 43.3, and loses
every other rate. At level 1 it's 1.2 to 2.3 times slower than zlib-ng and 1.2 to 1.7
times slower than libdeflate (1.5 to 4.8 and 1.5 to 3.5 at `540ae3c`); at level 6, 1.2
to 1.7 and 1.6 to 2.0 times; at level 9, up to 2.5 and 1.5 to 2.2 times.

### Task 003: each change, measured on its own

2026-10-12, task 003, Goose `c38dc0f`, same machine, compilers, and libraries. Each
change was built with `goose build` into a binary of its own and run against the build
before it as `bench LEVEL FILE RUNS FORMAT`, one-shot, in 3 alternating rounds; a cell
is the best of the 3 rounds' medians, in MB/s. Where a change kept the bytes, only
rates are shown.

Adler-32, as level 0 zlib output (a copy and the checksum), `RUNS` 10, against both
libraries in the same rounds. The lanes sum each byte into one of 32 lanes and fold
the lanes once a run of 5,552 bytes:

| Build | dickens | mozilla | x-ray | xml |
|---|---:|---:|---:|---:|
| A byte at a time | 3,667.8 | 3,691.1 | 3,574.4 | 3,361.0 |
| 32 lanes | 7,787.6 | 8,146.1 | 7,516.0 | 6,546.6 |
| 32 lanes, `simd fn` (AVX2) | 13,377.7 | 13,238.3 | 12,322.6 | 10,121.7 |
| zlib-ng | 43,464.6 | 24,438.4 | 42,951.0 | 42,830.8 |
| libdeflate | 25,329.1 | 17,637.9 | 24,344.3 | 21,978.9 |

Kept as the `simd fn` (`540ae3c`): 3.0 to 3.6 times the byte-at-a-time rate. The lanes
alone doubled it, by letting clang vectorize at SSE2; AVX2 gave another 1.5 to 1.7
times.

The length and distance codes, and the logarithms `better` compares, from tables
instead of std's `clz`, against `b44ed4f`, gzip, `RUNS` 5:

| Level | dickens | mozilla | x-ray | xml |
|---:|---|---|---|---|
| 1 | 86.9 → 177.6 | 118.2 → 193.9 | 105.2 → 130.8 | 147.9 → 312.1 |
| 6 | 37.8 → 47.9 | 56.9 → 70.5 | 51.1 → 58.5 | 94.3 → 120.1 |
| 9 | 19.3 → 22.0 | 17.2 → 18.8 | 52.9 → 61.3 | 36.5 → 40.2 |

Kept: 1.2 to 2.1 times faster at level 1, 14 to 27 percent at level 6, and 9 to 16
percent at level 9, with the same bytes. On the M1 Pro the code tables were within the
noise, at -1.7 to +3.1 percent (step 4).

Two changes the M1 Pro turned down at step 4, run again against `43cb937`, gzip,
`RUNS` 5, in the same 3 rounds:

| Change | Level | dickens | mozilla | x-ray | xml | Kept |
|---|---:|---|---|---|---|---|
| A hash table of 2^16 `u32` entries instead of 2^15 | 1 | 177.7 → 180.9 | 192.6 → 199.4 | 130.3 → 131.6 | 311.1 → 312.2 | yes |
| | 6 | 48.2 → 48.6 | 70.3 → 74.3 | 61.4 → 73.4 | 120.4 → 121.4 | |
| | 9 | 22.2 → 22.6 | 18.8 → 19.1 | 58.3 → 71.1 | 40.1 → 40.5 | |
| 8-byte extension, first differing byte by shifts | 1 | 177.7 → 177.7 | 192.6 → 188.7 | 130.3 → 127.8 | 311.1 → 325.2 | no |
| | 6 | 48.2 → 48.4 | 70.3 → 71.5 | 61.4 → 60.0 | 120.4 → 125.8 | |
| | 9 | 22.2 → 21.9 | 18.8 → 19.6 | 58.3 → 57.0 | 40.1 → 42.7 | |

The larger hash table is faster in all 12 cells, by 19 and 22 percent on `x-ray` at
levels 6 and 9 and 6 percent on `mozilla` at level 6, and its output is 0.3 to 0.8
percent smaller at level 1 (`dickens` 4,371,843 to 4,342,576 bytes, `x-ray` 6,383,613
to 6,332,212) and within a few hundred bytes at 6 and 9. It costs 131,072 more bytes a
stream, as on the M1 Pro, where it gained on two files of four. Kept afterwards, for the
memory (2026-10-12). The 8-byte extension gains on `xml` and loses on `x-ray`
at every level, as on the M1 Pro.

#### Small inputs

A program built with `goose build` calls `compress::compress` (gzip, level 1) on the
first N bytes of `dickens` 20,000,000 / (N + 2,000) times in a row, 5 times over; a
cell is the best of the 5 averages, in µs a call, best of 3 runs of the program.

| Build | 100 bytes | 1,000 bytes | 10,000 bytes |
|---|---:|---:|---:|
| `43cb937`: 2^15 hash table, a new `Encoder` a call | 108.0 | 117.1 | 147.2 |
| 2^16 hash table, a new `Encoder` a call | 152.4 | 158.3 | 189.5 |
| 2^16, one global `Encoder`, `reset` a call | 7.3 | 11.9 | 41.6 |
| 2^16, one `Encoder` in a global resizable, `reset` a call | 7.3 | 11.6 | 41.4 |

Building an `Encoder` copies each of its arrays several times
([findings](goose-findings.md#a-struct-literal-copies-each-nested-fixed-array-whole)),
and the Windows C runtime's `memcpy` is slow on this CPU for the copies Goose makes:
the same 100-byte call took 30 µs under Linux on the same CPU. Kept: `reset`, and
`compress` resetting one encoder per program instance. As a plain global `Encoder` it
made level 6 slower, against the build with a new `Encoder` a call (`bench 6 FILE 3`,
3 alternating rounds, best median, MB/s):

| Build | dickens | mozilla | x-ray | xml |
|---|---:|---:|---:|---:|
| A new `Encoder` a call | 48.3 | 74.0 | 72.2 | 121.2 |
| A global `Encoder` | 47.3 | 71.3 | 67.3 | 119.6 |
| An `Encoder` in a global resizable | 48.8 | 74.4 | 72.5 | 120.9 |

Padding of 32 or 2,048 bytes before the global `Encoder` left `x-ray` at 69.4 to 70.0,
so its placement isn't the cause: with the address known, clang compiles the matcher
differently. In a resizable, the address is loaded at run time, and the rate is the
same as before.
