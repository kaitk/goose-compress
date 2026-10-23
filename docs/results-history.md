# Results history

Earlier benchmark runs and the measurements behind each change, moved out of
[results.md](results.md), which keeps each machine's latest run. Each machine's section
starts with how it was set up when these ran; a run names its own package commit and
Goose pin where they differ.

## Apple M1 Pro, macOS

- Apple M1 Pro (8 performance and 2 efficiency cores),
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
libraries as above. MB/s is the median of the 10 runs. Background load was
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
differed by under 1 percent. Background load average was 5 to 7 throughout.
Output sizes don't vary between runs; where a
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
`ctz` was a loop (until Goose `d687028`),
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
the best of the 3 rounds' medians, in MB/s. Background load average was 3.9 to 7.2;
no other benchmark ran. Where a change kept
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

### zstd level 1: task 004 step 2

2026-10-13, Goose `a6249a4`, `goose build` defaults with Apple clang 21.0.0. Level 1
matches with one probe a position into compressed blocks, with raw literals and the
predefined FSE tables. `bench/bench.goose` compresses each file one-shot, whole, in
memory, with `compress::compress(data, out, compress::ZSTD, 1)`. The machine was
otherwise idle (`ps`). libzstd isn't in `bench/` yet (step 6), so ratios are compared
with the zstd 1.5.7 command line (Homebrew) and rates with step 1's encoder.

Ratio, output over input, on the 12 Silesia files, `bench 1 FILE 1 zstd` against
`zstd -1 --no-check -c FILE`, and against the same with `--no-compress-literals`,
which leaves libzstd's literals raw as here. The total is all 12 files' output over
their input.

| File | goose | zstd -1 | zstd -1, raw literals |
|---|---:|---:|---:|
| dickens | 0.5513 | 0.4182 | 0.5752 |
| webster | 0.4287 | 0.3297 | 0.4277 |
| xml | 0.1884 | 0.1300 | 0.1576 |
| nci | 0.1298 | 0.0851 | 0.1037 |
| mozilla | 0.4558 | 0.3901 | 0.4306 |
| samba | 0.3150 | 0.2546 | 0.2960 |
| x-ray | 0.9972 | 0.7992 | 0.9994 |
| mr | 0.5238 | 0.3829 | 0.5165 |
| ooffice | 0.6522 | 0.5841 | 0.6847 |
| osdb | 0.4174 | 0.3697 | 0.4133 |
| reymont | 0.4250 | 0.3245 | 0.3825 |
| sao | 0.8784 | 0.8617 | 0.9045 |
| total | 0.4246 | 0.3457 | 0.4127 |

With literals raw on both sides, the output is 2.9 percent larger than libzstd's in
total, from 4.7 percent smaller (`ooffice`) to 25 percent larger (`nci`). libzstd
still codes its sequences with FSE tables built per block (step 4), from a 512 KB
window, and Huffman literals (step 3) take the rest of the gap.

Rate, MB/s, `bench 1 FILE 10 zstd`, 5 alternating rounds of the two builds, the
median of each round's 10 runs; the rounds varied by under 1 percent.

| File | Step 1 (raw blocks) | Step 2 |
|---|---:|---:|
| dickens | 8,652 | 168.7 |
| webster | 8,730 | 208.9 |
| xml | 8,909 | 421.3 |
| nci | 8,715 | 559.9 |
| mozilla | 8,727 | 292.4 |
| samba | 8,755 | 322.5 |
| x-ray | 8,809 | 2,278.6 |

Step 1 copies and hashes its input. Step 2 spends about two thirds of its time in the
matcher and a quarter coding sequences (`sample` on `webster`). `x-ray`, which barely
compresses, runs fast because the step grows over input that doesn't match.

#### The window and the matcher's parameters

The same ratio command on the 12 files, one constant changed at a time from the build
above (128 KB window, 2^15 hash entries of 6 bytes, step growing by 1 every 2^7
bytes without a match), and rates from 3 alternating rounds of `bench 1 FILE 5 zstd`
on 7 files. `ZstdEncoder` sizes are from its C layout: the window buffer is the
window, a block, and 32 KB.

| Build | Bytes held | Total ratio | Rate against the build above |
|---|---:|---:|---|
| 128 KB window (kept) | 557,232 | 0.4246 | |
| 256 KB window | 688,304 | 0.4188 | +1 to +11 percent, `nci` -2, `x-ray` -43 |
| 512 KB window | 950,448 | 0.4159 | +2 to +16 percent, `nci` -4, `x-ray` -51 |
| 2^14 hash entries | 491,696 | 0.4319 | not run |
| 5-byte hash | 557,232 | 0.4174 | -2 to -9 percent, `x-ray` -88 |
| 7-byte hash | 557,232 | 0.4357 | not run |
| Step grows every 2^6 bytes | 557,232 | 0.4252 | within 3 percent, `x-ray` +170 |
| Step grows every 2^8 bytes | 557,232 | 0.4242 | within 3 percent, `x-ray` -73 |

A larger window shrinks output 1.4 percent at 256 KB and 2.0 percent at 512 KB (`xml`
7 and 9 percent, `dickens` 2 and 2.5), but only on inputs past 128 KB. Kept at 128 KB
([decisions](decisions.md)). The 5-byte hash's gain is almost all
`x-ray` (0.927 against 0.997), whose literals step 3 will code. On the text files
its output is within 3 percent either way, and it's slower.

Computing an upper bound of the sequences' bits, so each block is written without the
pass that counts them, was 2 to 3 percent slower on 5 files: the bound needs each
sequence's codes in the forward pass. Not kept.

`compress::compress` on the first N bytes of `dickens`, level 1, best of 5 averages of
20,000,000 / (N + 2,000) calls, µs a call (`goose build`, outside the repository):

| Format | 100 bytes | 1,000 bytes | 10,000 bytes |
|---|---:|---:|---:|
| gzip | 7.7 | 11.0 | 41.0 |
| zstd | 1.4 | 3.2 | 23.8 |

A zstd `reset` clears only the hash table, 131,072 bytes.

### zstd Huffman literals: task 004 step 3

2026-10-13, Goose `a6249a4`, `goose build` defaults with Apple clang 21.0.0. Step 2's
level 1 and predefined FSE tables, with each block's literals Huffman coded from the
block's counts, RLE where they're one byte, or raw where that's shorter. A block of
literals alone is compressed too. Measured as for step 2, with the same commands; the
machine was otherwise idle (`ps`).

Ratio, output over input, on the 12 Silesia files. The `zstd -1` columns are step 2's,
from the zstd 1.5.7 command line.

| File | Step 2 | Step 3 | zstd -1 | zstd -1, raw literals |
|---|---:|---:|---:|---:|
| dickens | 0.5513 | 0.4748 | 0.4182 | 0.5752 |
| webster | 0.4287 | 0.3675 | 0.3297 | 0.4277 |
| xml | 0.1884 | 0.1670 | 0.1300 | 0.1576 |
| nci | 0.1298 | 0.1097 | 0.0851 | 0.1037 |
| mozilla | 0.4558 | 0.4242 | 0.3901 | 0.4306 |
| samba | 0.3150 | 0.2866 | 0.2546 | 0.2960 |
| x-ray | 0.9972 | 0.7986 | 0.7992 | 0.9994 |
| mr | 0.5238 | 0.4278 | 0.3829 | 0.5165 |
| ooffice | 0.6522 | 0.5786 | 0.5841 | 0.6847 |
| osdb | 0.4174 | 0.3877 | 0.3697 | 0.4133 |
| reymont | 0.4250 | 0.3965 | 0.3245 | 0.3825 |
| sao | 0.8784 | 0.8499 | 0.8617 | 0.9045 |
| total | 0.4246 | 0.3768 | 0.3457 | 0.4127 |

The output is 11 percent smaller than step 2's and 9.0 percent larger than libzstd's,
from 1.4 percent smaller (`sao`) to 29 percent larger (`nci`). On `x-ray`, nearly all
literals, the two are within 0.1 percent. libzstd still codes its sequences with FSE
tables built per block (step 4), from a 512 KB window.

Rate, MB/s, `bench 1 FILE 10 zstd`, 5 alternating rounds of the two builds, the median
of the rounds' medians; each file's rounds varied by under 1 percent, `x-ray`'s by 1.9.

| File | Step 2 | Step 3 | Change |
|---|---:|---:|---:|
| dickens | 168.6 | 134.4 | -20% |
| webster | 208.7 | 166.8 | -20% |
| xml | 421.2 | 347.6 | -17% |
| nci | 560.3 | 459.2 | -18% |
| mozilla | 292.1 | 226.6 | -22% |
| samba | 322.3 | 261.8 | -19% |
| x-ray | 2,275.6 | 596.4 | -74% |

On `webster`, counting the literals and coding them take about a fifth of the time,
as much as the sequences (`sample`). `x-ray`'s blocks were stored raw in step 2, so its
rate was a copy's; now nearly all of it is literals to code. Three changes made step 3
faster before the numbers above, measured with `bench 1 FILE 10 zstd` on `x-ray` and
`webster`, and for small inputs with the program below:

- Counting the bytes 4 at a time into 4 tables, as libzstd's `HIST_count_parallel`
  does: `x-ray` 428 to 583 MB/s, since its 16-bit samples repeat bytes and each count
  of one table waited on the one before. `webster` within 2 percent.
- Coding 4 literals between stores of the bit buffer, from a slice, in place of a store
  checked after each: `x-ray` 375 to 428 MB/s, `webster` 163 to 166.
- Literals-only and small blocks pay a fixed cost: building the code, its description,
  and zeroing the tables. `compress` of the first 100 bytes of `dickens` took 6.6 µs
  at first. Lengths without DEFLATE's bit-reversed codes, codes assigned in one pass
  over the bytes used, a weights table of 12 symbols in place of the 53 of the
  sequences' `Fse`, counts summed as the streams' tables merge, and FSE coding the
  weights at accuracy 5 only, brought it to 3.5 µs.

Accuracy 5 for the weights is the log libzstd's `FSE_optimalTableLog` gives any count
of Huffman weights. Trying 6 too and keeping the smaller saved at most 116 bytes on a
file (`mozilla`), out of 21.7 MB.

`compress::compress` on the first N bytes of `dickens`, level 1, best of 5 averages of
20,000,000 / (N + 2,000) calls, µs a call, as for step 2:

| Format | 100 bytes | 1,000 bytes | 10,000 bytes |
|---|---:|---:|---:|
| gzip | 7.6 | 10.9 | 38.6 |
| zstd, step 2 | 1.3 | 3.2 | 24.5 |
| zstd, step 3 | 3.5 | 7.0 | 35.0 |

### zstd FSE tables per block: task 004 step 4

2026-10-13, Goose `a6249a4`, `goose build` defaults with Apple clang 21.0.0. Step 3,
with each kind of sequence code (literal lengths, offsets, match lengths) coded with
the table that takes the fewest estimated bits: one built from the block's counts, the
predefined one, an RLE table, or the last block's repeated. Measured with step 2's
commands. Unlike step 3's run, the machine wasn't idle: Chrome and a virtual machine
ran, at a load average of 5 to 9, so the builds ran in alternating rounds.

Ratio, output over input, on the 12 Silesia files, `bench 1 FILE 1 zstd`. The
`zstd -1` column is step 2's, from the zstd 1.5.7 command line.

| File | Step 3 | Step 4 | zstd -1 |
|---|---:|---:|---:|
| dickens | 0.4748 | 0.3955 | 0.4182 |
| webster | 0.3675 | 0.3201 | 0.3297 |
| xml | 0.1670 | 0.1417 | 0.1300 |
| nci | 0.1097 | 0.0873 | 0.0851 |
| mozilla | 0.4242 | 0.3848 | 0.3901 |
| samba | 0.2866 | 0.2537 | 0.2546 |
| x-ray | 0.7986 | 0.7978 | 0.7992 |
| mr | 0.4278 | 0.3680 | 0.3829 |
| ooffice | 0.5787 | 0.5543 | 0.5841 |
| osdb | 0.3877 | 0.3492 | 0.3697 |
| reymont | 0.3965 | 0.3173 | 0.3245 |
| sao | 0.8499 | 0.8200 | 0.8617 |
| total | 0.3768 | 0.3378 | 0.3457 |

The output is 10.4 percent smaller than step 3's and 2.3 percent smaller than
libzstd's, with a 128 KB window against its 512 KB: smaller on 10 files, and larger
on `xml` (9.0 percent) and `nci` (2.6). Where the difference comes from isn't measured
here: libzstd's fast levels choose their tables by rules of thumb
(`ZSTD_selectEncodingType`), and its matcher's parameters differ. Step 6 builds
libzstd in `bench/`, where its blocks can be compared directly. Step 3's build gave
`ooffice` 0.5787 here, against 0.5786 in its own table.

Rate, MB/s, `bench 1 FILE 10 zstd`, 5 alternating rounds of the two builds, the median
of the rounds' medians. Each file's rounds varied by 1.5 to 2.8 percent, under the
load above, so the step 3 column sits 1 to 4 percent below step 3's own run.

| File | Step 3 | Step 4 | Change |
|---|---:|---:|---:|
| dickens | 129.2 | 128.6 | -0.5% |
| webster | 161.8 | 160.9 | -0.6% |
| xml | 335.7 | 332.1 | -1.1% |
| nci | 444.4 | 435.5 | -2.0% |
| mozilla | 220.4 | 216.9 | -1.6% |
| samba | 251.7 | 251.6 | 0.0% |
| x-ray | 575.7 | 580.5 | +0.8% |

Each change is within its rounds' spread. A block's sequences now take three passes:
one computes and counts their codes, one counts the bits with the chosen tables, and
one writes them. Before, two passes computed the codes, with nothing to count.

`compress::compress` on the first N bytes of `dickens`, level 1, best of 3 runs of 5
averages of 20,000,000 / (N + 2,000) calls, µs a call, the two builds alternating, as
for step 2:

| Format | 100 bytes | 1,000 bytes | 10,000 bytes |
|---|---:|---:|---:|
| zstd, step 3 | 3.55 | 7.08 | 35.2 |
| zstd, step 4 | 3.55 | 7.78 | 36.8 |

Planning three tables a block costs about 0.7 µs at 1,000 bytes. Normalizing counts
was 6 percent of a 1,000-byte call (`sample`) while it started from each share rounded
down; starting from the share rounded to nearest leaves the greedy adjustment fewer
steps, cut that call by about 0.2 µs, and left Silesia's output the same to the byte.

### zstd level 3: task 004 step 5

2026-10-13, Goose `a6249a4`, `goose build` defaults with Apple clang 21.0.0. Step 4,
with level 3 matching as libzstd's `ZSTD_dfast` does: a 2^16-entry table of 8-byte
hashes and a 2^15-entry table of 5-byte ones. Levels 2 and up run it. Measured with
step 2's commands. Chrome and a virtual machine ran beside the benchmarks, at a load
average of 3 to 8, so the builds ran in alternating rounds.

Ratio, output over input, on the 12 Silesia files, `bench 1 FILE 1 zstd` and
`bench 3 FILE 1 zstd`, against `zstd -3 --no-check -c FILE` from the zstd 1.5.7
command line (Homebrew), with its 2 MB window and with this package's 128 KB one
(`--zstd=wlog=17`). Level 1's ratios are step 4's to four places.

| File | Level 1 | Level 3 | zstd -3 | zstd -3, 128 KB window |
|---|---:|---:|---:|---:|
| dickens | 0.3955 | 0.3781 | 0.3596 | 0.3955 |
| webster | 0.3201 | 0.3045 | 0.2920 | 0.3187 |
| xml | 0.1417 | 0.1341 | 0.1190 | 0.1411 |
| nci | 0.0873 | 0.0866 | 0.0845 | 0.0919 |
| mozilla | 0.3848 | 0.3757 | 0.3569 | 0.3767 |
| samba | 0.2537 | 0.2459 | 0.2295 | 0.2564 |
| x-ray | 0.7978 | 0.7407 | 0.7182 | 0.7510 |
| mr | 0.3680 | 0.3582 | 0.3559 | 0.3637 |
| ooffice | 0.5543 | 0.5262 | 0.5085 | 0.5287 |
| osdb | 0.3492 | 0.3481 | 0.3472 | 0.3806 |
| reymont | 0.3173 | 0.3007 | 0.2924 | 0.3141 |
| sao | 0.8200 | 0.7808 | 0.7628 | 0.7707 |
| total | 0.3378 | 0.3251 | 0.3124 | 0.3335 |

Level 3's output is 3.8 percent smaller than level 1's, and 4.1 percent larger than
`zstd -3`'s. With the same 128 KB window, it's 2.5 percent smaller than libzstd's, and
larger only on `sao`. On `roundtrip.py`'s JSON, level 3 writes 30,551 bytes against
level 1's 29,274, as `zstd -3` writes 33,568 against `zstd -1`'s 28,910: both take
short matches inside its random digits.

One constant changed at a time, level 3's Silesia total: a 2^17-entry long table, as
libzstd's for inputs past 256 KB, 0.3246 for 256 KB more; a 6-byte short hash 0.3316;
a 4-byte one 0.3250.

Rate, MB/s, `bench 1 FILE 10 zstd` and `bench 3 FILE 10 zstd`, 5 alternating rounds of
step 4's build at level 1 and this step's at levels 1 and 3, the median of the rounds'
medians. Each file's rounds varied by 1.0 to 5.2 percent, and by 8 to 10 percent on
`x-ray` at level 1.

| File | Step 4, level 1 | Level 1 | Level 3 | Level 3 over level 1 |
|---|---:|---:|---:|---:|
| dickens | 126.5 | 127.8 | 108.9 | -14.8% |
| webster | 159.9 | 159.9 | 135.0 | -15.6% |
| xml | 335.5 | 334.1 | 307.4 | -8.0% |
| nci | 436.2 | 428.9 | 420.8 | -1.9% |
| mozilla | 216.5 | 215.7 | 164.2 | -23.9% |
| samba | 250.7 | 251.2 | 213.3 | -15.1% |
| x-ray | 580.1 | 584.3 | 119.5 | -79.5% |

Level 1 is within its rounds' spread of step 4's. Level 3 runs slowest where it finds
more short matches than level 1: on `x-ray`, which level 1 skips through fast for want
of 6-byte matches, its output is 7.2 percent smaller. libzstd shows the same: `zstd
-b1e3 --no-check FILE` (3 seconds a level) gave `x-ray` 1,304 MB/s at level 1 and 207
at level 3, `dickens` 677 and 264, and `mozilla` 1,105 and 699.

`compress::compress` on the first N bytes of `dickens`, best of 3 runs of 5 averages
of 20,000,000 / (N + 2,000) calls, µs a call, the median of 3 rounds of the two builds
alternating, as for step 2, at a load average of 3 to 6:

| Build | 100 bytes | 1,000 bytes | 10,000 bytes |
|---|---:|---:|---:|
| Step 4, level 1 | 3.63 | 7.93 | 37.5 |
| Level 1 | 2.48 | 6.35 | 36.0 |
| Level 3 | 2.57 | 7.41 | 45.3 |

`reset` no longer clears the hash tables: each stream starts out of their entries'
reach. Clearing level 3's 384 KB of them made 100 bytes take 6.2 µs at level 3, and
level 1's 128 KB took about 1.1 µs at step 4.

### zstd against libzstd and klauspost: task 004 step 6

2026-10-13, package at `237de3a`, Goose `a6249a4`. The run against libzstd v1.5.7 and
klauspost/compress v1.20.3, with its setup, is in
[results.md](results.md#zstd-levels-1-and-3-at-237de3a). Below is what was measured
around it.

The `zstd -b` rates quoted in step 5 were multithreaded: the zstd 1.5.7 command line
compresses with worker threads by default, in `-b` too. `zstd -b1 -i3 --no-check` gave
`dickens` 681 MB/s, and with `-T1` 421, the rate of libzstd in `bench/ref.c`, 420 MB/s.
A static libzstd built with its Makefile in place of CMake gave `ref` the same 420.
Measured with one thread, libzstd's level 1 is 2.3 to 3.2 times faster than the
package's on six files, where step 5's numbers suggested 5 times on `dickens` and
`mozilla`.

Where the time goes at level 1 on `webster`, from `sample bench 4` while `bench 1
webster 30 zstd` ran, and `sample ref 4` while `ref libzstd 1 webster 80 zstd` ran.
Shares are of each profile's samples, inlined callees counted in their callers; ms/MB
is the share times each one's time per MB of input from the run (166.0 and 457.5
MB/s).

| Work | Package | Share | ms/MB | libzstd | Share | ms/MB |
|---|---|---:|---:|---|---:|---:|
| Matching | `match_zstd_fast` | 53% | 3.22 | `ZSTD_compressBlock_fast` | 70% | 1.53 |
| Everything after | `zstd_block`, `put_huff_literals`, `put_seqs`, `write` | 47% | 2.80 | `ZSTD_encodeSequences`, `HIST_count_parallel_wksp`, `HUF_compress1X_usingCTable_internal`, `ZSTD_XXH64_update`, and table builds | 30% | 0.65 |

The package's matcher takes 2.1 times libzstd's time a byte, and the rest 4.3 times.
Of the package's rest, `zstd_block` (computing and counting each sequence's codes,
choosing and building tables, and counting the literals) is 23 percent of the
samples, writing the Huffman literals 11, and writing the sequences 10; libzstd's
writing of sequences is 13, and counting and coding literals 11. At level 3 on
`webster`, the package's double-fast matcher is 61 percent of the samples,
`zstd_block` 19, and the sequences and literals 9 each.

### Small JSON bodies: reset, Huffman codes, level 1's loop, and CRC-32

2026-10-23, branch `json-speed` against `ecc06fe`, Goose `v2026.3` with Apple clang
21.0.0, `goose build` defaults. The bodies are JSON responses of the shape HttpArena's
`/json/:count` asks for: 25, 40, and 50 items (4,190, 6,707, and 8,397 bytes), and the
first 100 bytes of a one-item one. A program built with `goose build` calls
`compress::compress` (gzip) on a body 500 times a batch, 41 batches, and takes the
median batch; each build ran 3 times, alternating with the other, and a cell is the
best of the 3, in µs a call. Other work kept the load average between 23 and 35
throughout, so the cells are noisier than earlier sections'. The output is the same
before and after, byte for byte.

| Body | Level | Bytes out | `ecc06fe` | `json-speed` | Change |
|---|---:|---:|---:|---:|---:|
| 100 bytes | 1 | 108 | 7.95 | 2.23 | −72% |
| 100 bytes | 6 | 108 | 8.13 | 2.40 | −70% |
| 25 items | 1 | 1,008 | 18.62 | 11.27 | −39% |
| 25 items | 6 | 938 | 24.52 | 17.43 | −29% |
| 40 items | 1 | 1,420 | 24.16 | 15.87 | −34% |
| 40 items | 6 | 1,273 | 33.98 | 26.08 | −23% |
| 50 items | 1 | 1,703 | 27.98 | 18.91 | −32% |
| 50 items | 6 | 1,483 | 39.98 | 31.73 | −21% |

The reset that keeps the tables, alone, by the same method: 100 bytes at level 1 went
from 7.40 to 3.75 µs and at level 6 from 7.70 to 3.91; 50 items at level 1 from 26.44
to 21.69 and at level 6 from 38.36 to 32.99. CRC-32 alone, a program calling
`compress::crc32` 2,000 times on random bytes, the best of 31 rounds: 2,048 bytes took
0.46 µs against 0.64, 8,397 bytes 1.87 against 2.69, and 65,536 bytes 13.1 against
20.8; 1,024 and 1,500 bytes, below the two halves' threshold, didn't change.

### Level 1's `load32` and next bucket, not kept

2026-10-23, Apple M1 Pro, macOS 26.3.1, Goose `v2026.3` with Apple clang 21.0.0,
`goose build` defaults. A Linux x86-64 profile of a server that gzips small JSON
bodies at level 1 put `match_fast` at 32.9 percent of its time and `load32`, a call
there, at 5.9. Two changes were tried against `7e9e2d8`, each by
`bench/compare.sh` (`docs/development.md`, "Benchmark"): the bodies in `bench/json/`
in 5 alternating rounds, and Silesia files in 3 rounds of `RUNS` 3 or 5. Other work
kept the load average between 10 and 27. Every build gave the same output, byte for
byte, as `7e9e2d8`'s on each input and level.

- `8378681` (branch `match-fast-load32`): `load32` an `inline fn`. On this machine,
  clang already inlines the C function, which has no symbol in the binary; Goose's
  own inlining gives other C, and it is slower everywhere it is used.
- `e7f03e2` (branch `match-fast-next-bucket`): `match_fast` finds the bucket of
  `p + 1` before it reads `p`'s, as libdeflate's `ht_matchfinder` does, so the read
  doesn't wait on a hash. After a match, the bucket of `p + len` is found again.
  Goose has no prefetch, so libdeflate's prefetch of that bucket has no counterpart.
- `eed8bf9`, on `e7f03e2`: the loop that inserts the positions a match skips carries
  the next bucket too, so no bucket is found twice.

The bodies, in µs a call:

| Body | Level | Bytes out | `7e9e2d8` | `8378681` |
|---|---:|---:|---:|---:|
| 100 bytes | 1 | 108 | 2.16 | 2.17 |
| 100 bytes | 6 | 108 | 2.33 | 2.35 |
| 25 items | 1 | 1,008 | 11.27 | 11.42 |
| 25 items | 6 | 938 | 17.18 | 19.26 |
| 40 items | 1 | 1,420 | 15.46 | 16.01 |
| 40 items | 6 | 1,273 | 25.41 | 29.02 |
| 50 items | 1 | 1,703 | 18.32 | 18.94 |
| 50 items | 6 | 1,483 | 31.43 | 36.40 |

| Body | Level | Bytes out | `7e9e2d8` | `e7f03e2` | `eed8bf9` |
|---|---:|---:|---:|---:|---:|
| 100 bytes | 1 | 108 | 2.17 | 2.17 | 2.15 |
| 25 items | 1 | 1,008 | 11.02 | 11.21 | 11.53 |
| 40 items | 1 | 1,420 | 15.56 | 15.93 | 16.42 |
| 50 items | 1 | 1,703 | 18.54 | 18.98 | 19.75 |

`e7f03e2` against `7e9e2d8` alone, run twice more, the second time with `e7f03e2`
first in each round: 25 items 11.03 against 11.23, then 10.93 against 11.18; 50 items
18.49 against 18.97, then 18.41 against 18.93.

Silesia, in MB/s:

| File | Level | `7e9e2d8` | `8378681` |
|---|---:|---:|---:|
| `dickens` | 1 | 148.9 | 147.8 |
| `dickens` | 6 | 64.2 | 58.3 |
| `dickens` | 9 | 34.5 | 31.0 |
| `x-ray` | 1 | 92.1 | 93.1 |
| `x-ray` | 6 | 87.3 | 86.4 |
| `x-ray` | 9 | 82.6 | 81.2 |
| `xml` | 1 | 316.7 | 305.6 |
| `xml` | 6 | 171.6 | 155.6 |
| `xml` | 9 | 69.5 | 61.7 |
| `mozilla` | 1 | 163.3 | 161.3 |
| `mozilla` | 6 | 100.3 | 91.7 |
| `mozilla` | 9 | 28.8 | 25.7 |
| `dickens`, zstd | 1 | 271.9 | 265.5 |
| `dickens`, zstd | 3 | 155.4 | 155.5 |
| `x-ray`, zstd | 1 | 695.9 | 693.3 |
| `x-ray`, zstd | 3 | 146.4 | 147.8 |

| File | Level | `7e9e2d8` | `e7f03e2` | `eed8bf9` |
|---|---:|---:|---:|---:|
| `dickens` | 1 | 147.4 | 149.7 | 156.5 |
| `x-ray` | 1 | 92.3 | 98.8 | 97.3 |
| `xml` | 1 | 312.2 | 315.5 | 317.7 |
| `mozilla` | 1 | 162.7 | 168.7 | 167.8 |

The inline `load32` costs 3 to 15 percent at levels 6 and 9 and up to 3 at level 1.
The next bucket found early gains 1 to 7 percent on Silesia at level 1, but costs the
bodies 2 to 3 percent, and carrying it through skipped positions 4 to 7. A body
touches few of the table's lines, so its reads likely hit the cache, where the
extra hash is only cost; whether the M1's large out-of-order window also hides the
wait wasn't measured. Neither is kept, since the bodies are what the change was for.
libdeflate, tuned on x86-64, finds the next bucket early, so both variants are left
on their branches to measure there.

### CRC-32 on PMULL

2026-10-23, branch `crc-clmul` against `e762653` (`origin/main`, CRC-32 on Goose's
tables), Goose `v2026.3` with Apple clang 21.0.0, `goose build` defaults; macOS 26.3.1.
`crc-clmul` folds CRC-32 with `PMULL` in `shim/crc32.c`
([decisions](decisions.md)). `LEVELS="0 1" ROUNDS=3
FILES=build/bench/corpus/dickens bench/compare.sh e762653 .`: the bodies are those of
[the section above](#small-json-bodies-reset-huffman-codes-level-1s-loop-and-crc-32),
timed as there, in µs a call; `dickens` is the median of 5 runs, in MB/s; each cell is
the best of 3 rounds, alternating with the other build. The output is the same,
byte for byte. Other work kept the 1-minute load average between 4.5 and 4.8.

| Input | Level | Bytes out | Unit | `e762653` | `crc-clmul` | Change |
|---|---:|---:|---|---:|---:|---:|
| 100 bytes | 0 | 123 | µs a call | 0.06 | 0.06 | 0% |
| 100 bytes | 1 | 108 | µs a call | 2.13 | 2.12 | 0% |
| 25 items | 0 | 4,213 | µs a call | 1.24 | 0.37 | −70% |
| 25 items | 1 | 1,008 | µs a call | 10.77 | 9.89 | −8% |
| 40 items | 0 | 6,730 | µs a call | 1.80 | 0.51 | −72% |
| 40 items | 1 | 1,420 | µs a call | 15.21 | 13.77 | −9% |
| 50 items | 0 | 8,420 | µs a call | 2.23 | 0.65 | −71% |
| 50 items | 1 | 1,703 | µs a call | 18.18 | 16.39 | −10% |
| `dickens` | 0 | 10,193,244 | MB/s | 4,277.1 | 16,987.4 | 3.97× |
| `dickens` | 1 | 4,219,080 | MB/s | 149.0 | 153.5 | +3% |

Level 0 is a copy and CRC-32, and runs 3.4 to 4.0 times as fast from 4 KB up.
CRC-32 is the same on both paths, and equal to Python's `zlib.crc32`, on all 12
Silesia files, whole, from each start offset 1 to 15, and over random cuts. At
level 1 the bodies take 8 to 10 percent less time; `dickens`, where matching
dominates, gains 3 percent. The 100-byte body folds one 64-byte block and is
unchanged.

## AMD Ryzen 7 5800X3D, Windows

- AMD Ryzen 7 5800X3D (Zen 3, 8 cores, 16 threads,
  AVX2 and no AVX-512), 32 GB, Windows 11 Pro 10.0.26200.
- Goose `c38dc0f`, `goose build` defaults: `clang-cl` 22.1.3 at `/O2`, from Visual
  Studio Build Tools 2026 (18). `simd fn`s get an AVX2 version.
- libdeflate v1.26 and zlib-ng 2.3.3, CMake `Release` builds with Ninja and clang
  22.1.3 and their default options, which pick each CPU's fastest code at run time;
  `bench/ref.c` at `-O2`, same compiler.
- Run from Git Bash. Background CPU load was about 13 percent before the benchmarks;
  no other benchmark ran.

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
`clz`, which clang turned into one instruction on arm64 but not on x86-64 (until Goose
`d687028`).

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

### Levels 1, 6, and 9 at `43cb937`

2026-10-12, task 003, package at `43cb937`: the chain search's one range test and the
code tables on top of `540ae3c`. `LEVELS="1 6 9" bench/run.sh`: gzip output, one-shot,
the whole file in memory, 10 runs per cell, same machine, compilers, and libraries.
MB/s is the median of the 10 runs; the ratios are as at `540ae3c`
([above](#levels-0-1-6-and-9-at-540ae3c)).

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

### Task 005 steps 2 and 3: `simd fn` and the codegen ceiling

2026-10-13, task 005, package at `6b57c40`, Goose `a6249a4`, same machine, compilers,
and libraries. No other benchmark or build ran during the runs below, CPU load was 2
to 4 percent before each. A run that overlapped another build was discarded.

Each build ran as `bench LEVEL FILE 5`, gzip, one-shot, in 3 alternating rounds with
the others on the 7 Silesia files; a cell is the median of the 3 rounds' medians, in
MB/s. Every build below writes the same bytes as `6b57c40`, checked on `xml`, `x-ray`,
and `dickens` at levels 1, 6, and 9.

#### Step 2: `simd fn` gives std's bit scans no instruction

A `simd fn`'s AVX2 version is compiled with `target("avx2,bmi,bmi2,lzcnt,popcnt")`, so
`tzcnt` and `popcnt` are available to clang there, but std's `ctz` and `popcount` stay
loops in it (until Goose `d687028`).
Two builds, run in the same rounds as step 3's first run:

- S1: `simd` on `match_fast` and `match_chains`, so `search` and `match_len` are
  compiled into the AVX2 version.
- S2: S1, with `match_len` comparing 8 bytes at a time and finding the first differing
  byte with std's `ctz`.

| Level | Build | dickens | webster | xml | nci | mozilla | samba | x-ray |
|---:|---|---:|---:|---:|---:|---:|---:|---:|
| 1 | `6b57c40` | 187.3 | 209.0 | 309.4 | 375.5 | 207.3 | 258.8 | 136.7 |
| | S1 | +1.4% | +2.2% | +5.9% | +7.1% | +2.0% | +3.3% | +0.4% |
| | S2 | -12.4% | -10.8% | -7.7% | +1.5% | -10.7% | -6.3% | -7.9% |
| 6 | `6b57c40` | 49.1 | 68.0 | 121.6 | 128.4 | 73.5 | 88.0 | 68.1 |
| | S1 | +0.4% | +1.6% | +0.3% | -1.0% | +1.1% | +1.5% | +1.0% |
| | S2 | -7.7% | -6.8% | -6.9% | -11.2% | -9.9% | -3.6% | +4.7% |
| 9 | `6b57c40` | 22.4 | 26.6 | 40.6 | 29.2 | 19.0 | 30.8 | 65.5 |
| | S1 | +1.8% | +2.6% | +0.5% | +2.1% | +3.2% | +1.3% | +2.4% |
| | S2 | -7.6% | -7.1% | -6.9% | -16.8% | -25.8% | -6.5% | +9.5% |

Neither kept. S1 is 0.4 to 7.1 percent faster at level 1 and -1.0 to +3.2 percent at
levels 6 and 9, near the 1 percent between two builds of the same code. S2 is 4 to 26
percent slower everywhere but `x-ray` (+5 to +10 percent) and `nci` at level 1, as
the 8-byte compare with std's `ctz` was at task 001 step 4.

#### Step 3: the hand-fixed C

`goose build -v --dry-run` wrote `bench.c` for `6b57c40`, and edited copies were
compiled with its command, `clang-cl -O2` and the release runtime object:

- `c-head`: the C unchanged, as a control.
- `c-unchecked`: every bounds and slice check removed from the whole program.
- `c-hf`: `match_fast`, `match_chains`, and `lz_write` rewritten in C with the same
  algorithm, with `search`, `match_len`, `add_lit`, `add_match`, and `insert` inlined:
  no bounds checks, the encoder's scalars in locals, written back before `end_block`
  and at the end, and an 8-byte `match_len` with `__builtin_ctzll`. `lz_write` is
  included because Goose's inliner had given it its own copy of `match_fast`.
- `c-hf-bytecmp`: `c-hf` comparing a byte at a time, as the Goose code does.

The `c-unchecked` row is from the first run, with S1 and S2; the others from a second
run with libdeflate and zlib-ng in the same rounds. The first run's `c-hf` rows at
level 1 are left out: they ran the old `match_fast` in `lz_write`.

| Level | Build | dickens | webster | xml | nci | mozilla | samba | x-ray |
|---:|---|---:|---:|---:|---:|---:|---:|---:|
| 1 | `6b57c40` | 189.1 | 209.8 | 313.3 | 383.5 | 212.3 | 264.1 | 139.7 |
| | `c-head` | -3.3% | -1.1% | -2.1% | -0.4% | -2.0% | -2.5% | -1.9% |
| | `c-unchecked` (first run) | +3.2% | +5.0% | +10.2% | +13.9% | +5.0% | +7.7% | +1.2% |
| | `c-hf-bytecmp` | +12.7% | +15.2% | +20.3% | +24.2% | +13.7% | +15.4% | +9.0% |
| | `c-hf` | 213.2 | 241.2 | 387.9 | 522.4 | 242.0 | 308.2 | 149.8 |
| | libdeflate | 263.4 | 294.2 | 505.9 | 656.4 | 276.6 | 371.6 | 164.8 |
| | zlib-ng | 282.5 | 343.5 | 681.7 | 896.5 | 318.0 | 431.6 | 158.6 |
| | `c-hf` / libdeflate | 0.81 | 0.82 | 0.77 | 0.80 | 0.87 | 0.83 | 0.91 |
| 6 | `6b57c40` | 50.0 | 69.7 | 123.8 | 130.4 | 75.0 | 90.8 | 70.7 |
| | `c-head` | +0.0% | -0.3% | +0.2% | -0.1% | -0.3% | -0.7% | -0.4% |
| | `c-unchecked` (first run) | +0.4% | +1.6% | -0.7% | -0.5% | +3.4% | +3.0% | +12.5% |
| | `c-hf-bytecmp` | -1.2% | +0.7% | +2.6% | +6.0% | +3.3% | +2.6% | +7.2% |
| | `c-hf` | 53.6 | 74.6 | 138.6 | 163.3 | 82.7 | 100.1 | 76.7 |
| | libdeflate | 73.7 | 104.4 | 186.5 | 236.6 | 120.5 | 136.0 | 121.8 |
| | zlib-ng | 67.8 | 85.0 | 165.4 | 215.6 | 93.8 | 119.6 | 75.7 |
| | `c-hf` / libdeflate | 0.73 | 0.71 | 0.74 | 0.69 | 0.69 | 0.74 | 0.63 |
| 9 | `6b57c40` | 22.9 | 27.1 | 41.0 | 30.0 | 19.2 | 30.8 | 67.7 |
| | `c-head` | +0.0% | +0.0% | -0.2% | +0.0% | -0.5% | +0.3% | -0.1% |
| | `c-unchecked` (first run) | +1.8% | +0.4% | +0.2% | +2.7% | +5.3% | +2.6% | +14.0% |
| | `c-hf-bytecmp` | -1.3% | +0.0% | +2.9% | +9.0% | +3.6% | +7.5% | +7.5% |
| | `c-hf` | 24.1 | 28.5 | 46.4 | 42.0 | 21.8 | 38.0 | 74.2 |
| | libdeflate | 31.6 | 37.7 | 62.5 | 62.2 | 30.9 | 45.9 | 102.7 |
| | zlib-ng | 27.7 | 43.4 | 80.2 | 71.7 | 27.9 | 51.3 | 43.4 |
| | `c-hf` / libdeflate | 0.76 | 0.76 | 0.74 | 0.68 | 0.71 | 0.83 | 0.72 |

The hand-fixed C reaches 0.77 to 0.91 of libdeflate's rate at level 1, 0.63 to 0.74
at level 6, and 0.68 to 0.83 at level 9: well behind, so step 3 points to the
structure, not the codegen. It's 7 to 36 percent faster than the Goose build at level
1, 7 to 25 percent at level 6, and 5 to 40 percent at level 9. Of that, the bounds
checks alone give up to 14 percent, most at level 1 and on `x-ray`. The 8-byte compare
gives 1 to 22 percent at levels 6 and 9, most on `nci`, where matches are long, and
-2 to +10 percent at level 1. `c-head`, the same C as `6b57c40`'s binary, ran 0.4 to
3.3 percent slower at level 1 and within 0.7 percent at levels 6 and 9, so the level 1
gains carry about 2 percent of build noise.

Where `c-hf`'s time goes, by `rdtsc` around `end_block` and the matchers in a build of
it, `c-hf 3` runs a file: the matcher takes 66 to 69 percent at level 1 (19 to 28
percent in `end_block`), 84 to 93 percent at level 6, and 85 to 98 percent at level
9, so at levels 6 and 9 the gap is in the matcher. libdeflate's `hc_matchfinder` runs
the same chains with the same depth and nice length, and differs in the rest: a
candidate must match the 4 bytes ending at the best length and the first 4 before it's
extended, against one byte and the first 4 here; the first 4-byte match has a loop of
its own; it prefetches the next position's buckets; its minimum match length adapts
to each block's literals, and it rejects 3-byte matches past 8 KB. Its level 1 is
another loop entirely (`deflate_compress_fastest` and `ht_matchfinder`, nice length
32).

### Task 005 step 3: libdeflate's chain search, at `9f7a539`

2026-10-13, task 005, Goose `a6249a4`, same machine, compilers, and libraries as step
2. `9f7a539` ports three things from libdeflate's `hc_matchfinder`: a chain link is
the low 16 bits of the previous offset, so a step is a load and a mask; a candidate
must match the 4 bytes ending at the best length, and before the first match only the
4 hashed bytes; and `search` is an `inline fn`. It writes the same bytes as `6b57c40`
on all 21 cells. No other benchmark or build ran, at about 2 percent CPU load before
the run. Each build ran as `bench LEVEL FILE 5` (libdeflate and zlib-ng through
`ref`), gzip, one-shot, in 3 alternating rounds on the 7 Silesia files; a cell is the
median of the 3 rounds' medians, in MB/s. `6b57c40` is a `goose build` of that commit.

| Level | File | `6b57c40` | `9f7a539` | change | libdeflate | zlib-ng | `9f7a539` / libdeflate |
|---:|---|---:|---:|---:|---:|---:|---:|
| 1 | dickens | 186.4 | 183.2 | -1.7% | 254.9 | 285.5 | 0.72 |
| | webster | 209.7 | 212.8 | +1.5% | 292.7 | 339.6 | 0.73 |
| | xml | 313.1 | 324.1 | +3.5% | 503.6 | 677.3 | 0.64 |
| | nci | 379.3 | 396.1 | +4.4% | 651.2 | 883.0 | 0.61 |
| | mozilla | 210.2 | 210.1 | -0.0% | 276.1 | 318.2 | 0.76 |
| | samba | 258.4 | 269.7 | +4.4% | 370.3 | 441.0 | 0.73 |
| | x-ray | 139.2 | 142.8 | +2.6% | 162.5 | 157.6 | 0.88 |
| 6 | dickens | 50.0 | 61.8 | +23.6% | 73.5 | 67.4 | 0.84 |
| | webster | 69.1 | 84.1 | +21.7% | 104.2 | 84.6 | 0.81 |
| | xml | 123.2 | 151.4 | +22.9% | 189.0 | 165.9 | 0.80 |
| | nci | 130.5 | 183.0 | +40.2% | 236.6 | 214.1 | 0.77 |
| | mozilla | 74.9 | 97.5 | +30.2% | 120.1 | 93.4 | 0.81 |
| | samba | 90.3 | 113.2 | +25.4% | 136.1 | 119.4 | 0.83 |
| | x-ray | 70.2 | 88.4 | +25.9% | 121.2 | 74.1 | 0.73 |
| 9 | dickens | 22.9 | 30.8 | +34.5% | 31.6 | 27.7 | 0.97 |
| | webster | 27.1 | 37.0 | +36.5% | 37.8 | 43.3 | 0.98 |
| | xml | 41.1 | 61.5 | +49.6% | 62.8 | 80.5 | 0.98 |
| | nci | 30.0 | 57.7 | +92.3% | 62.1 | 71.5 | 0.93 |
| | mozilla | 19.1 | 31.3 | +63.9% | 30.8 | 27.7 | 1.02 |
| | samba | 30.8 | 49.9 | +62.0% | 45.9 | 51.1 | 1.09 |
| | x-ray | 67.6 | 84.6 | +25.1% | 102.8 | 43.3 | 0.82 |

Level 6 is 22 to 40 percent faster and level 9 25 to 92 percent. Level 9 reaches 0.93
to 1.09 of libdeflate's rate on six files, faster on `mozilla` and `samba`, and 0.82
on `x-ray`; level 6 reaches 0.73 to 0.84. Level 1's code didn't change; its -1.7 to
+4.4 percent is noise between builds. Output is 0.1 to 4.5 percent larger than
libdeflate's at levels 6 and 9, as at `6b57c40`.

#### The C prototypes behind it

Before the port, each idea was tried in the hand-fixed C of step 3 (`c-hf`, built the
same way), and libdeflate v1.26 was built from source with clang 22.1.3 at `-O2` to
profile and count it. Rates in this subsection are quick checks, not the run above:
one `bench LEVEL FILE 3` invocation each, the median of 3 runs, at about 2 percent CPU
load, so they show direction only.

- The chain step dominated. `c-hf`'s step adds the slot's distance, subtracts it from
  the position, and masks it before the next load; with offset links (P2) a step is a
  load and a mask, and `dickens` at level 9 went from 24.0 to 31.6 MB/s.
- libdeflate's candidate test and first-match loop alone (P1) wrote the same bytes and
  added 4 to 9 percent at levels 6 and 9.
- `search` wasn't inlined at its three calls, so the encoder state the matcher keeps
  in a local struct went through memory. Forcing it inline took P2 on `x-ray` level 6
  from 82.8 to 100.8 MB/s.
- libdeflate's `hash3` table for 3-byte matches and its minimum match length, chosen
  from the block's literals (P4), brought output to within 0.1 to 0.9 percent of
  libdeflate's, but cost 3 to 30 percent of the rate, most on `x-ray` (level 6, 100.8
  to 77.4 MB/s). With them, the prototype does libdeflate's work exactly: on `x-ray` at level
  6 both make 5,915,406 searches and about 3,394,000 chain steps. A sampling profile
  puts the prototype's extra time in cache misses on its tables: a 256 KB `u32` head
  table, a 128 KB `hash3` table, and the 64 KB chains, past the 512 KB L2 with the
  window and symbols; libdeflate's three tables take 256 KB.
- libdeflate's layout, 16-bit positions in all three tables rebased every 32 KB (P5),
  was 5 to 10 percent faster than P4 at level 6 on `x-ray` and 8 to 15 percent slower
  at level 9 on `dickens` and `mozilla`. A 16-bit head table without rebasing (P3) let
  stale entries into reach and was up to 31 percent slower.
- A prefetch of the next position's buckets measured the same as the plain load the
  package already does.

The profiles came from a sampler that suspends the main thread every 200 µs and
records its instruction pointer, which needs no elevation on Windows; libdeflate's
level 6 on `x-ray` spends 87.5 percent in `deflate_compress_lazy` and 11.5 percent in
`deflate_flush_block`.

### Task 005: level 1 in libdeflate's 2-entry buckets, at `24ac46b`

2026-10-13, task 005, Goose `a6249a4`, same machine, compilers, libraries, and method
as `9f7a539`'s run above, at level 1 only, at 7 percent CPU load before the run.
`24ac46b` matches level 1 as libdeflate's `ht_matchfinder`: the 2^16-entry hash table
as 2^15 buckets of the 2 latest offsets, both tried unless the newer gives 32 bytes.
`p7` is the same matcher in step 3's hand-fixed C (no bounds checks, state in locals,
an 8-byte compare), spliced into `6b57c40`'s C; it writes `24ac46b`'s bytes. Sizes
are against libdeflate's.

| File | `9f7a539` | size | `24ac46b` | size | change | `p7` | libdeflate | zlib-ng | `24ac46b` / libdeflate |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| dickens | 191.2 | +3.0% | 161.6 | +0.0% | -15.5% | 186.6 | 263.5 | 284.7 | 0.61 |
| webster | 214.8 | +5.0% | 181.5 | +0.1% | -15.5% | 210.0 | 292.4 | 341.9 | 0.62 |
| xml | 323.6 | +20.3% | 286.8 | -0.0% | -11.4% | 352.9 | 504.3 | 677.1 | 0.57 |
| nci | 403.5 | +7.6% | 332.7 | +0.1% | -17.5% | 419.9 | 655.6 | 886.9 | 0.51 |
| mozilla | 216.3 | +1.5% | 172.5 | -0.1% | -20.2% | 194.1 | 275.1 | 317.1 | 0.63 |
| samba | 270.5 | +3.2% | 220.7 | -0.0% | -18.4% | 258.5 | 371.5 | 446.0 | 0.59 |
| x-ray | 142.9 | +0.6% | 103.1 | +0.2% | -27.9% | 110.2 | 164.5 | 158.4 | 0.63 |

Kept (2026-10-13), for the output size: level 1 now writes libdeflate's sizes to
within 0.2 percent, where it wrote up to 20.3 percent more, at 11 to 28 percent of its
rate. `p7` runs within 2.4 percent of `9f7a539`, or faster, on four files, so most of
the loss is the Goose build's, not the matcher's. On `mozilla` and `x-ray` `p7` loses
10 and 23 percent too.

A sampling profile of `p7` on `dickens` puts 15 percent of its samples on the bucket
load in the loop that inserts a match's positions, which must now read a bucket to
shift it; libdeflate's own loop spends 15.5 percent on the same load. libdeflate's
16-bit positions in a 128 KB table, rebased every 32 KB, made `p7` 0 to 7 percent
slower in a quick check (one `bench 1 FILE 3` each). The rest of `p7`'s gap to
libdeflate is spread: its matcher takes 42.6 ms of a `dickens` run where libdeflate's
takes 34, and `end_block` 11.2 ms against `deflate_flush_block`'s 7.2.

### Task 005: 8-byte match extension, at `8ec4538`

2026-10-13, task 005, Goose `a6249a4`, same machine, compilers, libraries, and method
as `24ac46b`'s run above, at levels 1, 6, and 9, at 4 percent CPU load before the run.
`8ec4538` extends a match 8 bytes at a time after one byte, finding the first that
differs with a de Bruijn multiply, in an `inline fn match_len`. It writes the same
bytes as `24ac46b` on all 21 cells.

| Level | File | `24ac46b` | `8ec4538` | change | libdeflate | `8ec4538` / libdeflate |
|---:|---|---:|---:|---:|---:|---:|
| 1 | dickens | 158.6 | 162.4 | +2.4% | 261.5 | 0.62 |
| | webster | 174.4 | 182.1 | +4.4% | 292.4 | 0.62 |
| | xml | 283.0 | 291.2 | +2.9% | 503.1 | 0.58 |
| | nci | 333.6 | 362.9 | +8.8% | 649.5 | 0.56 |
| | mozilla | 172.6 | 177.0 | +2.5% | 274.3 | 0.65 |
| | samba | 218.0 | 229.3 | +5.2% | 369.9 | 0.62 |
| | x-ray | 103.5 | 107.1 | +3.5% | 163.0 | 0.66 |
| 6 | dickens | 61.4 | 63.8 | +3.9% | 72.4 | 0.88 |
| | webster | 82.6 | 83.3 | +0.8% | 102.7 | 0.81 |
| | xml | 149.6 | 158.4 | +5.9% | 185.1 | 0.86 |
| | nci | 180.8 | 196.0 | +8.4% | 232.4 | 0.84 |
| | mozilla | 96.0 | 98.1 | +2.2% | 118.6 | 0.83 |
| | samba | 111.2 | 116.1 | +4.4% | 133.8 | 0.87 |
| | x-ray | 88.0 | 88.8 | +0.9% | 119.4 | 0.74 |
| 9 | dickens | 30.3 | 30.9 | +2.0% | 31.1 | 0.99 |
| | webster | 36.2 | 36.9 | +1.9% | 37.1 | 0.99 |
| | xml | 61.1 | 63.4 | +3.8% | 62.2 | 1.02 |
| | nci | 57.9 | 63.1 | +9.0% | 62.1 | 1.02 |
| | mozilla | 31.1 | 31.7 | +1.9% | 30.6 | 1.04 |
| | samba | 48.7 | 50.6 | +3.9% | 45.2 | 1.12 |
| | x-ray | 84.3 | 86.0 | +2.0% | 100.8 | 0.85 |

Level 9 now runs at 0.99 to 1.12 of libdeflate's rate on six files of seven.

Tried with it, in quick checks (one `bench LEVEL FILE 3` each, on `dickens`, `nci`,
`x-ray`, and `mozilla`), and not kept:

- `match_len` as a plain `fn`: clang stopped inlining it, and level 6 lost 5 to 7
  percent on `x-ray`.
- `load32` as an `inline fn`: within 1 percent, or up to 4 percent slower at level 9.
  Its slice check stays at every inlined call: the analysis doesn't drop the check on
  a slice taken at a difference, `s[p - d..p - d + 4]`.
- `walk` with the distance test as `d >= 1 && d <= reach`, `reach <= p` asserted, and
  the window sliced once: no check dropped, so no build was measured.
- The generated C compiled with `/clang:-fstrict-aliasing`, which `clang-cl` leaves off:
  levels 6 and 9 0.1 to 3.2 percent faster, level 1 -5.5 to +0.7 percent. The encoder
  state's reloads aren't mostly an aliasing matter.

### Task 005: the symbol path at level 1, not kept

2026-10-13, task 005, after `8ec4538`, same machine and method, at about 5 percent
CPU load. A sampling profile of `8ec4538` at level 1 on `dickens` gives the matcher
71.8 percent of the samples, `put_syms` 9.8, the length and distance code lookups
(when a match is recorded and again when it's written) 6.8, CRC-32 5.3, and building
the block's codes under 1.5. In the hand-fixed C (`p7`), finding the matches without
recording them runs at 244 MB/s on `dickens` against libdeflate's 255, in quick checks
(one `bench 1 FILE 3` each), so the gap left at level 1 is recording and writing the
symbols, about 16 ms of the run against about 9 in libdeflate.

- A match's distance code, extra-bit count, and extra bits recorded in its symbol, so
  `put_syms` doesn't look the distance up again. Same output; in 3 alternating rounds
  of 5 runs: level 1 -0.6 to +1.7 percent, level 6 -0.9 to +1.9, level 9 -1.9 to
  +0.0. Not kept: within the 1 to 2 percent between two builds of the same code.
- Literals gathered until 32 bits are held before the 8-byte store, as libdeflate
  does: within 1 percent in quick checks. Not kept.
- The next position's bucket prefetched at level 1, in `p7`: 2 to 8 percent slower in
  quick checks; loaded early instead, as level 6 does, within 2 percent.

### zstd profile at `8ec4538`

2026-10-13, task 005 step 5. The run against libzstd and klauspost is in
[results history](#zstd-levels-1-and-3-at-8ec4538). Profiles from the in-process
sampler (a thread that records the main thread's instruction pointer every ~20 µs):
the package's `goose build` C with the sampler, at `/O2` with debug info, `bench 1
webster 15 zstd`; and libzstd v1.5.7 compiled from source with clang 22.1.3 at `-O3`
into one program with the sampler, `ZSTD_compress2` with the checksum, 25 runs. Shares
are of each profile's samples, inlined callees counted in their callers; ms/MB is the
share times each one's time per MB in the profiled run (173.3 and 383.1 MB/s).

| Work | Package | Share | ms/MB | libzstd | Share | ms/MB |
|---|---|---:|---:|---|---:|---:|
| Matching | `match_zstd_fast` | 47% | 2.68 | `ZSTD_compressBlock_fast` | 69% | 1.80 |
| Everything after | `zstd_block`, `put_huff_literals`, `put_seqs`, `write` | 53% | 3.09 | `ZSTD_encodeSequences`, `HIST_count_parallel_wksp`, `ZSTD_buildSequencesStatistics`, `HUF_compress1X_usingCTable_internal`, `ZSTD_XXH64_update`, and table builds | 31% | 0.81 |

The package's matcher takes 1.5 times libzstd's time a byte, and the rest 3.8 times. By
line, the rest is counting the literals (`plan_literals`, 12 percent of the samples),
Huffman coding them (`put_huff_literals`, 11), computing and counting each sequence's
codes (`code_seqs`, 10), and the FSE state steps (8), which run twice per sequence:
once in `seq_bits`, to learn the block's size before its header is written, and again
in `put_seqs`. libzstd counts literals copied into one buffer as each sequence is
stored (`ZSTD_storeSeq`); the package reads them back run by run through the
sequences, both to count and to code them. At level 3 on `webster`, the double-fast
matcher is 55 percent of the package's samples and 75 percent of libzstd's. On `x-ray`
at level 1, coding the literals is 46 percent of the package's samples and 34 of
libzstd's.

### Task 005: zstd coding changes, at `b396581`

2026-10-13, task 005 step 5, after the [profile](#zstd-profile-at-8ec4538). Each
change against the build before it, with the same output, in 3 alternating rounds of
`bench LEVEL FILE 5 zstd`; the median of the rounds' medians. The base is `8ec4538`.

| File | Level | Base MB/s | `3df4fe4` | `b3f480f` | `b396581` |
|---|---:|---:|---:|---:|---:|
| dickens | 1 | 153.9 | -0.1% | +5.0% | +26.3% |
| webster | 1 | 191.2 | -0.8% | +4.8% | +24.7% |
| xml | 1 | 406.3 | -0.2% | +2.8% | +21.8% |
| nci | 1 | 532.5 | -0.5% | +3.2% | +27.1% |
| mozilla | 1 | 251.0 | +0.5% | +3.4% | +18.8% |
| samba | 1 | 303.9 | +0.2% | +4.2% | +20.3% |
| x-ray | 1 | 674.4 | -0.7% | -1.6% | -0.4% |
| dickens | 3 | 133.1 | -0.9% | +4.9% | +17.4% |
| webster | 3 | 160.4 | +0.1% | +3.5% | +15.7% |
| xml | 3 | 370.2 | +0.3% | +2.6% | +16.6% |
| nci | 3 | 503.1 | +0.3% | +3.8% | +20.7% |
| mozilla | 3 | 192.3 | +0.4% | +2.9% | +12.9% |
| samba | 3 | 259.4 | +0.0% | +4.4% | +13.8% |
| x-ray | 3 | 136.1 | -0.4% | +2.5% | +5.9% |

- `3df4fe4` indexes the hash tables `% ZSTD_HASH_SIZE` and `% ZSTD_LONG_SIZE`, as
  DEFLATE's `match_len` does its table, which drops 7 of the matchers' bounds checks.
  Level 3 keeps two, where the index is a `var` carried from one position to the next.
  Within noise; kept for the checks.
- `b3f480f` writes a block's sequences once. A bound on their bits, from each code's
  count, its extra bits, and the most bits a state of its table writes, shows the block
  is smaller than raw; the block is then written behind a placeholder header that's
  filled in after. Where the bound doesn't show it, `seq_bits` counts the bits first,
  as before. Writing every block before knowing its size, and shrinking `out` back where
  it came out larger, gained the same, but a shrink through `out` makes
  `compress::compress` one that shrinks its argument, and the checker then rejects a
  caller holding any slice that could refer into it (spec §5.1). `x-ray` at level 1 is
  1.6 percent slower in two runs; none of its blocks are raw, and the time is in the
  literals' Huffman coding, which the change doesn't touch.
- `b396581` copies each sequence's literals into `lits`, one buffer per block, when the
  sequence is stored, as libzstd's `ZSTD_storeSeq` does. Counting and coding the
  literals then read four flat segments, not runs found by walking the sequences. The
  encoder grows by 131,080 bytes, to 1,010,955.

### Task 005: zstd's sequence codes, at `64f7bc5`

2026-10-13, measured as at `b396581`, each against the build before it. A profile at
`b396581` on `webster` at level 1 (218.9 MB/s) gives the matcher and its loads about
64 percent of the samples, `code_seqs` 13, the FSE steps and `put_seqs` 14, and the
literals 4, down from 23. On `x-ray` at level 1, Huffman coding the literals is 48
percent and counting them 22.

| File | Level | Base MB/s | `be26d4e` | `64f7bc5` |
|---|---:|---:|---:|---:|
| dickens | 1 | 202.2 | +0.8% | +2.2% |
| webster | 1 | 246.1 | -0.4% | +1.8% |
| xml | 1 | 514.3 | -1.1% | +1.2% |
| nci | 1 | 693.3 | +0.5% | +0.7% |
| mozilla | 1 | 309.9 | -0.3% | +0.6% |
| samba | 1 | 376.1 | +0.1% | +2.2% |
| x-ray | 1 | 649.6 | +3.8% | -2.3% |
| dickens | 3 | 160.3 | -0.9% | +2.1% |
| webster | 3 | 193.6 | -0.8% | +2.4% |
| xml | 3 | 448.4 | -0.3% | +3.3% |
| nci | 3 | 631.5 | -0.0% | +2.4% |
| mozilla | 3 | 223.8 | -0.8% | +0.6% |
| samba | 3 | 305.7 | +0.2% | +2.0% |
| x-ray | 3 | 145.1 | +0.0% | +0.9% |

- `be26d4e` counts the codes in three `i64[256]` tables indexed by the `u8` codes, and
  indexes the code arrays `% ZSTD_SEQ_MAX`, which drops 7 of `code_seqs`' 9 bounds
  checks. Within noise: the hot lines are the repeat-offset compares and the offset
  code's branches.
- `64f7bc5` loads both of the offset code's candidates, `LOG2[v & 255]` and
  `8 + LOG2_HI[v >> 8]`, and selects one, where `log2_zstd` branched on `v >= 256`.

Tried after `64f7bc5`, not kept in the shared implementation: `load64` as one 8-byte
slice, not two `load32`s.
zstd gained 2.6 to 6.6 percent in every cell, but gzip lost 5.9 percent on `x-ray` at
level 6 and 6.3 at level 9, in two runs. With `match_len` kept on two `load32`s, gzip
was within noise and zstd kept a third of the gain, so most of both comes from
`match_len`'s 8-byte load, which the two formats share.

### Task 005: zstd's own `match_len`, at `d10dd61`

2026-10-14, Goose `0bdbd18`, each build against `64f7bc5` at the same pin. Quick checks
first, 2 rounds of `bench LEVEL FILE 5` on 3 files each:

| Build | gzip `x-ray` 6 | gzip `x-ray` 9 | gzip `mozilla` 6 | zstd `dickens` 1 | zstd `webster` 3 |
|---|---:|---:|---:|---:|---:|
| Shared `match_len` with std's `ctz` | -5.1% | -3.5% | -2.9% | +1.7% | +0.6% |
| The same, and `load64` as one 8-byte load | -6.3% | -3.4% | +0.0% | +7.2% | +6.9% |
| `d10dd61`: zstd's own, with both; DEFLATE's as before | +1.1% | -1.0% | -3.8% | +8.5% | +5.8% |

Any change to the inner loop of the shared `match_len` costs DEFLATE's chain search on
`x-ray` at levels 6 and 9, though most of its matches there end at the first byte,
before that loop: the cost is in how clang compiles the search around it, not in the
loop. zstd gains 5 to 7 percent from the two together. So zstd got its own copy.
`load64` is one 8-byte load for XXH64 and zstd's hashes; DEFLATE's `match_len` builds
its 8 bytes from two `load32`s, as before.

`d10dd61` in 3 rounds of 5 runs on all seven files:

| File | Level | zstd base MB/s | zstd | Level | gzip base MB/s | gzip |
|---|---:|---:|---:|---:|---:|---:|
| dickens | 1 | 202.8 | +9.2% | 1 | 163.2 | -1.2% |
| webster | 1 | 245.9 | +7.4% | 1 | 181.3 | +1.0% |
| xml | 1 | 514.2 | +7.4% | 1 | 305.8 | -0.3% |
| nci | 1 | 699.6 | +2.4% | 1 | 351.5 | +0.4% |
| mozilla | 1 | 306.0 | +7.2% | 1 | 168.1 | +4.7% |
| samba | 1 | 376.5 | +6.9% | 1 | 230.0 | +2.0% |
| x-ray | 1 | 653.1 | +0.9% | 1 | 104.2 | +1.0% |
| dickens | 3 | 160.2 | +6.3% | 6 | 63.9 | +0.2% |
| webster | 3 | 194.3 | +5.2% | 6 | 86.0 | +0.8% |
| xml | 3 | 451.4 | +5.6% | 6 | 158.4 | +1.4% |
| nci | 3 | 640.0 | +4.8% | 6 | 197.7 | +0.4% |
| mozilla | 3 | 222.6 | +7.1% | 6 | 99.9 | +0.1% |
| samba | 3 | 306.9 | +5.2% | 6 | 116.8 | +0.7% |
| x-ray | 3 | 144.8 | +7.3% | 6 | 88.8 | +1.2% |

gzip at level 9: -1.2 to +2.7 percent.

### Task 005: zstd's window reads without checks, not kept

2026-10-14, Goose `46356c2`, task 005 step 5, each build against `e1a9800` in 3
alternating rounds of `bench LEVEL FILE 5 zstd`, the median of the rounds' medians.
At `e1a9800`, `match_zstd_fast` keeps 6 index checks and 12 slice and assert checks
(`build/task005/port/fnchecks.py`), and `match_zstd_dfast` 11 and 21: the backward
extension's `win[p - 1 - d]`, `zstd_match_len`'s two slices, its assert, and its last
loop, and `seqs[nseq]`. Each of its 17 and 27 `load32` and `load64` calls keeps the
check on its slice.

| File | Level | Base MB/s | Unchecked C | `w1` | `w3` | `w6` | `w7` |
|---|---:|---:|---:|---:|---:|---:|---:|
| dickens | 1 | 219.6 | +5.5% | -17.9% | -9.4% | -7.9% | -4.2% |
| webster | 1 | 262.8 | +5.6% | -17.0% | -8.6% | -7.5% | -5.5% |
| xml | 1 | 553.0 | +4.7% | -17.7% | -10.6% | -7.4% | -5.3% |
| nci | 1 | 740.0 | +1.9% | -17.1% | -10.1% | -6.4% | -4.6% |
| mozilla | 1 | 325.9 | +6.1% | -19.4% | -12.4% | -8.2% | -5.0% |
| samba | 1 | 402.2 | +4.7% | -16.9% | -9.4% | -4.9% | -2.3% |
| x-ray | 1 | 653.8 | +2.5% | -5.2% | -4.5% | -2.7% | -0.5% |
| dickens | 3 | 164.8 | +6.1% | -20.4% | -13.4% | -8.4% | -7.1% |
| webster | 3 | 204.6 | +2.9% | -21.8% | -13.9% | -7.9% | -8.3% |
| xml | 3 | 477.0 | +3.9% | -23.1% | -14.0% | -8.8% | -7.3% |
| nci | 3 | 668.6 | +3.4% | -22.5% | -10.7% | -6.7% | -5.7% |
| mozilla | 3 | 234.9 | +3.9% | -27.0% | -15.7% | -8.6% | -8.3% |
| samba | 3 | 321.8 | +3.4% | -22.7% | -13.5% | -7.0% | -5.7% |
| x-ray | 3 | 154.6 | +5.5% | -36.6% | -26.8% | -12.1% | -12.2% |

The base column is the first comparison's; the others ran against the same build in
runs of their own. Each build writes the same output.

- Unchecked C: the C `goose build` writes at `e1a9800`, with every check in the two
  matchers, `load32`, and `load64` removed (`build/task005/zs/unchk.py`). The ceiling
  for this work: +1.9 to +6.1 percent.
- `w1`: the matchers read a slice `w = e.win[..end]` through `inline` loads of
  plain indexes, `w[i] | w[i + 1] << 8 ...`, with match candidates behind `q >= 0 &&
  q + 4 <= w.len`. Few checks drop, and each byte keeps one where the slice kept one.
- `w3`: the same loads through a slice, as `load32` does, with both positions and the
  hash reads guarded inside the helpers. Almost nothing drops: the analysis ignores a
  guard written `i + 4 <= w.len`, a gap goose-http's findings record.
- `w6`: the guards written `q <= w.len - 4`, over the whole window, and only on the
  candidate. Every window read's check drops; what's left is `zstd_match_len`'s and
  `seqs[nseq]`. Still 2.7 to 12.1 percent slower.
- `w7`: `e1a9800` with only `load32` and `load64` marked `inline`, which drops no
  check that matters here. 0.5 to 12.2 percent slower, as slow as `w6`.

So the loss is Goose's inlining of the loads, not the guards. clang inlines the
non-`inline` loads too, and the C of each inlined load is the same as the function's;
the double-fast matcher comes to 991 instructions at `e1a9800` and 1,004 in `w7`. A
sampled profile of `x-ray` at level 3 puts the same lines on top in both (the `long`
table's load and the 8- and 4-byte compares) with `w7`'s samples spread over more of
the loop. What the unchecked C gains, Goose can't reach this way at this pin. The
patches are `build/task005/zs/winidx.patch` (`w3`), `winidx-w6.patch`, and
`inline-loads.patch` (`w7`).

### Task 005: zstd's literals and sequences, at `257090f`

2026-10-14, Goose `46356c2`, task 005 step 5. A profile at `e1a9800`, taken as at
[`8ec4538`](#zstd-profile-at-8ec4538), level 1, against libzstd built from source:

| Work | Package | ms/MB | libzstd | ms/MB |
|---|---|---:|---|---:|
| `webster`: matching | `match_zstd_fast`, 63% | 2.68 | `ZSTD_compressBlock_fast`, 69% | 1.80 |
| `webster`: the FSE steps and sequences' bits | `put_seqs`, 15% | 0.62 | `ZSTD_encodeSequences`, 13% | 0.34 |
| `x-ray`: Huffman coding the literals | `put_huff_literals`, 45% | 0.72 | `HUF_compress1X_usingCTable_internal`, 33% | 0.42 |
| `x-ray`: counting, codes, and tables | `zstd_block`, 27% | 0.44 | `HIST_count_parallel_wksp` and `HIST_count_simple`, 33% | 0.42 |

Each change against the build before it, with the same output, in 3 alternating rounds
of `bench LEVEL FILE 5 zstd`, the median of the rounds' medians. H1 and H2 are against
`e1a9800`, S1 against H1, and S2 against S1.

| File | Level | Base MB/s | `b0199ba` (H1) | H2 | `257090f` (S1) | S2 |
|---|---:|---:|---:|---:|---:|---:|
| dickens | 1 | 219.5 | +2.0% | -0.9% | +2.7% | -0.0% |
| webster | 1 | 264.6 | -0.1% | -0.5% | +1.9% | -0.9% |
| xml | 1 | 552.8 | +0.4% | -1.8% | +1.7% | +0.2% |
| nci | 1 | 740.8 | +1.3% | +0.4% | +1.6% | -0.4% |
| mozilla | 1 | 325.3 | +1.9% | +1.4% | +0.9% | +0.7% |
| samba | 1 | 401.1 | +0.8% | -0.4% | +3.3% | +0.0% |
| x-ray | 1 | 667.0 | +5.2% | +2.8% | +1.2% | +2.1% |
| dickens | 3 | 170.0 | +1.0% | -2.4% | +1.4% | +0.1% |
| webster | 3 | 206.4 | +0.6% | -0.4% | +1.1% | +0.0% |
| xml | 3 | 477.6 | +0.8% | -1.3% | +1.4% | -0.4% |
| nci | 3 | 680.0 | -1.1% | -3.6% | +0.4% | -1.1% |
| mozilla | 3 | 237.0 | +0.9% | +0.1% | +0.9% | -0.1% |
| samba | 3 | 328.2 | +0.4% | -0.4% | +1.1% | -0.7% |
| x-ray | 3 | 156.5 | -0.1% | -0.9% | +1.6% | -1.1% |

- `b0199ba` (H1) codes a Huffman stream's literals four at a time, a loop of fixed
  count, and the last one to three after it; the loop had run `min(q, 4)` times. Kept.
- H2, on H1: each literal's code and length from one `u32` table, not a `u16` and a
  `u8` one. Slower than H1 in 13 cells of 14. Not kept.
- `257090f` (S1) writes a sequence's bits with one flush, not two, where its extra bits
  are at most 30, as `ZSTD_encodeSequences` does. Kept.
- S2: the FSE tables' `dnb` and `dfs` at 256 entries, indexed by the `u8` code, and
  `next` indexed under a mask, which drops `fse_step`'s two bounds checks. Within noise,
  and 9,744 more bytes an encoder. Not kept.

The patches not kept are `build/task005/zs/h2.patch` and `s2.patch`.

Tried after `7a96425`, not kept: S3, the extra bits as each value's low bits, as
`ZSTD_encodeSequences` writes them (a code's baseline is a multiple of 2^bits), with
no `LL_BASE` or `ML_BASE` load, and `LL_BITS` and `ML_BITS` read through 256-entry `u8`
tables indexed by the code without a check. -0.1 to -3.3 percent in every cell of
both levels, in 3 rounds against `7a96425` (`build/task005/zs/s3.patch`).

#### Level 1's hash table against the L2

Level 1's table holds 2^15 `u32`s, 128 KB, as klauspost's does; libzstd's level 1
holds 2^13, 32 KB, in the Ryzen's 512 KB L2 beside the window. Built at `257090f` with
level 1's hash cut to 14 and 13 bits (the table keeps its size, and level 3 its 15),
in 3 alternating rounds of `bench 1 FILE 5 zstd`, against 2^15; output against
libzstd's at level 1:

| File | 2^15 MB/s | 2^14 | 2^13 | Output vs libzstd: 2^15 | 2^14 | 2^13 |
|---|---:|---:|---:|---:|---:|---:|
| dickens | 224.6 | +7.0% | +17.7% | -5.4% | -2.4% | +1.9% |
| webster | 271.2 | +7.2% | +13.6% | -2.9% | -1.1% | +2.0% |
| xml | 560.0 | +2.0% | +5.7% | +9.3% | +10.4% | +12.1% |
| nci | 760.5 | -1.6% | -1.0% | +2.8% | +2.7% | +2.8% |
| mozilla | 329.4 | +12.3% | +18.6% | -1.3% | -0.5% | +1.1% |
| samba | 414.3 | +4.5% | +9.4% | -0.1% | +0.5% | +1.9% |
| x-ray | 700.0 | +11.5% | +13.6% | -0.2% | -0.0% | +0.0% |

The smaller table trades output for rate: 2^13 runs up to 18.6 percent faster and
writes up to 7.8 percent more than 2^15, and at least libzstd's size on every file. 2^14
gains up to 12.3 percent for at most 3.1 percent more output, and stays at or under
libzstd's size on four files of seven, where 2^15 is under it on five. Level 1 takes
2^13, libzstd's own, as the task's parity compares level by level (2026-10-14). Over
the 12 Silesia files its output goes from 0.3378 of the input to 0.3498, against
libzstd's 0.3455.

### Levels 0, 1, 6, and 9 at `6b57c40`

2026-10-13, task 005 step 1, package at `6b57c40`, Goose `a6249a4`, `clang-cl`
22.1.3 at `/O2`, the baseline for task 005. On this
machine it adds `d71eb59`, `1f1ed62`, and `865d359` to the last run, at `43cb937`
([history](#levels-1-6-and-9-at-43cb937)).
`LEVELS="0 1 6 9" bench/run.sh`: gzip output, one-shot, the whole file in memory, 10
runs per cell; MB/s is the median of the 10. Sizes are each output's bytes against
libdeflate's at the same level, from one run of `bench` and `ref`.

Level 0, MB/s:

| File | MB | Level 0 goose | zlib-ng | libdeflate |
|---|---:|---:|---:|---:|
| dickens | 10.2 | 2,756.1 | 17,251.9 | 19,144.3 |
| webster | 41.5 | 2,769.0 | 15,777.0 | 14,313.9 |
| xml | 5.3 | 2,639.0 | 17,209.5 | 12,858.5 |
| nci | 33.6 | 2,833.1 | 16,562.2 | 17,465.7 |
| mozilla | 51.2 | 2,639.4 | 14,213.7 | 13,814.6 |
| samba | 21.6 | 2,804.5 | 15,676.1 | 18,829.1 |
| x-ray | 8.5 | 2,724.9 | 17,178.7 | 18,727.6 |

Levels 1, 6, and 9, MB/s and size:

| File | Level 1 goose | size | zlib-ng | size | libdeflate | Level 6 goose | size | zlib-ng | size | libdeflate | Level 9 goose | size | zlib-ng | size | libdeflate |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| dickens | 188.1 | +3.0% | 283.1 | +42.8% | 261.6 | 49.3 | +0.1% | 67.2 | +0.9% | 72.9 | 22.8 | +0.1% | 27.4 | +1.3% | 31.3 |
| webster | 210.6 | +5.0% | 341.4 | +39.6% | 290.6 | 68.8 | +0.3% | 83.9 | +0.5% | 103.8 | 27.0 | +0.3% | 43.3 | +2.0% | 37.7 |
| xml | 312.4 | +20.3% | 681.3 | +33.3% | 504.0 | 124.1 | +0.6% | 165.3 | -0.4% | 188.4 | 41.2 | +0.5% | 80.3 | +1.9% | 62.9 |
| nci | 385.9 | +7.6% | 888.3 | +40.6% | 651.4 | 130.0 | +1.1% | 213.8 | +1.7% | 236.7 | 29.9 | +0.8% | 71.2 | +2.5% | 61.8 |
| mozilla | 208.6 | +1.5% | 319.1 | +18.8% | 274.5 | 74.6 | +3.0% | 93.1 | +3.3% | 120.0 | 19.1 | +3.0% | 27.7 | +1.7% | 30.6 |
| samba | 258.8 | +3.2% | 439.0 | +28.6% | 364.7 | 89.0 | +1.8% | 118.5 | +3.1% | 134.1 | 30.5 | +2.0% | 50.6 | +2.6% | 45.4 |
| x-ray | 139.4 | +0.6% | 156.5 | +25.1% | 163.5 | 69.5 | +4.3% | 74.4 | +4.7% | 120.2 | 67.4 | +4.5% | 43.3 | -0.5% | 101.6 |

Goose beats zlib-ng's rate on `x-ray` at level 9, 67.4 MB/s against 43.3, and loses
every other rate. Against libdeflate it's 1.17 to 1.69 times slower at level 1, 1.48
to 1.82 at level 6, and 1.37 to 2.07 at level 9, for output 0.6 to 20.3 percent
larger at level 1 and 0.1 to 4.5 percent at levels 6 and 9. Against the `43cb937`
run, a session earlier, level 1 is 2 to 9 percent faster, level 6 3 to 15 percent,
and level 9 2 to 16 percent, most on `x-ray`. Level 0 is 4.9 to 7.0 times slower than
both libraries: CRC-32 at 2.6 to 2.8 GB/s against their carryless multiply.

Task 005's steps 2 and 3, `simd fn` and the hand-fixed C against libdeflate, are in
[results-history.md](#task-005-steps-2-and-3-simd-fn-and-the-codegen-ceiling).

### zstd levels 1 and 3 at `8ec4538`

2026-10-13, task 005 step 5, package at `8ec4538`: zstd's first run on this machine.
Against:

- libzstd v1.5.7, a CMake `Release` build with Ninja and clang 22.1.3 (`-O3`) and its
  default options, through `bench/ref.c` at `-O2`, same compiler: `ZSTD_compress2`
  with `ZSTD_c_checksumFlag` on, at its own window for the input (512 KB at level 1, 2
  MB at level 3), and as `libzstd-w17` at the package's 128 KB.
- klauspost/compress v1.20.3, built by Go 1.27.0 with `go build` defaults, through
  `bench/klauspost`: `EncodeAll` with `WithEncoderCRC(true)`, at `SpeedFastest` against
  level 1 and `SpeedDefault` against level 3, with its default window.

Every library writes the content checksum and compresses one-shot, the whole file in
memory. Rate, MB/s, `FORMAT=zstd bench/run.sh`: 10 runs per cell, the median. The run
went twice, at 1 percent CPU load before it; each cell's medians agreed within 3
percent, except `libzstd-w17` at level 3 on `xml`, within 10.2. The table is the
first. Output sizes are the same as the M1 Pro's
([ratios](results.md#zstd-levels-1-and-3-at-237de3a)).

| File | MB | Level 1 goose | libzstd | libzstd, 128 KB | klauspost | Level 3 goose | libzstd | libzstd, 128 KB | klauspost |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| dickens | 10.2 | 152.9 | 361.0 | 311.9 | 205.5 | 132.8 | 195.0 | 210.3 | 160.8 |
| webster | 41.5 | 190.8 | 418.7 | 358.2 | 251.9 | 158.6 | 238.7 | 277.3 | 200.6 |
| xml | 5.3 | 406.4 | 828.5 | 691.4 | 519.8 | 366.1 | 610.7 | 529.6 | 392.8 |
| nci | 33.6 | 517.2 | 1,024.9 | 975.8 | 652.6 | 504.0 | 814.3 | 822.2 | 578.4 |
| mozilla | 51.2 | 247.9 | 518.0 | 450.6 | 333.2 | 192.3 | 282.6 | 324.7 | 258.3 |
| samba | 21.6 | 299.4 | 603.2 | 513.9 | 398.1 | 260.0 | 387.8 | 411.8 | 330.9 |
| x-ray | 8.5 | 670.9 | 846.4 | 945.2 | 2,327.1 | 133.8 | 146.9 | 209.6 | 150.0 |

The package loses every rate, by less than on the M1 Pro. At level 1, libzstd is 2.0
to 2.4 times faster on six files and 1.26 times on `x-ray`; klauspost is 1.26 to 1.34
times faster on six and 3.5 times on `x-ray`, whose literals it leaves raw. At level 3,
libzstd is 1.47 to 1.67 times faster on six files and 1.10 times on `x-ray`;
klauspost is 1.07 to 1.34 times. On `webster` at level 1, the coding after the matcher
takes 3.8 times libzstd's time a byte and the matcher 1.5 times
([profile](#zstd-profile-at-8ec4538)).

### zstd levels 1 and 3 at `b396581`

2026-10-13, task 005 step 5: three changes to the package's zstd coding, with the same
output, measured as at `8ec4538`, one run.

| File | Level 1 goose | libzstd | libzstd, 128 KB | klauspost | Level 3 goose | libzstd | libzstd, 128 KB | klauspost |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| dickens | 205.1 | 355.9 | 315.2 | 205.8 | 160.6 | 196.2 | 209.2 | 161.4 |
| webster | 246.9 | 415.0 | 359.7 | 252.8 | 191.9 | 237.6 | 274.6 | 202.6 |
| xml | 515.8 | 831.7 | 708.7 | 528.3 | 448.7 | 615.4 | 581.6 | 408.6 |
| nci | 699.3 | 1,013.3 | 975.2 | 654.3 | 635.9 | 808.8 | 833.7 | 605.2 |
| mozilla | 310.9 | 529.0 | 452.7 | 335.2 | 222.6 | 282.4 | 324.1 | 263.7 |
| samba | 373.7 | 608.6 | 518.0 | 396.9 | 306.0 | 389.4 | 407.9 | 333.1 |
| x-ray | 652.1 | 842.7 | 945.3 | 2,330.0 | 145.5 | 147.6 | 209.7 | 149.7 |

At level 1, libzstd is 1.45 to 1.74 times faster on six files and 1.29 times on
`x-ray`; klauspost's rate is 0.94 to 1.08 times the package's on six files, and 3.6
times on `x-ray`. At level 3, libzstd is 1.22 to 1.37 times faster on six files and
level on `x-ray`; klauspost's rate is 0.91 to 1.18 times the package's.

Each change against the build before it, in 3 alternating rounds of `bench LEVEL FILE 5
zstd` (`build/task005/ab.sh`), the median of the rounds' medians, per file in
[results-history.md](#task-005-zstd-coding-changes-at-b396581):

| Change | Level 1 | Level 3 | Kept |
|---|---|---|---|
| `3df4fe4`: hash tables indexed `% n`, 7 bounds checks dropped | -0.8% to +0.5% | -0.9% to +0.4% | yes, for the checks |
| `b3f480f`: sequences written once, behind a bound on their bits | +2.8% to +5.0%, `x-ray` -1.6% | +2.5% to +4.9% | yes |
| `b396581`: literals copied into one buffer as each sequence is stored | +18.8% to +27.1%, `x-ray` -0.4% | +5.9% to +20.7% | yes, at 131,072 more bytes |
| `be26d4e`: sequence codes counted in `u8`-indexed tables, 7 bounds checks dropped | -1.1% to +0.8%, `x-ray` +3.8% | -0.9% to +0.2% | yes, for the checks |
| `64f7bc5`: offset codes by a select between two table loads, not branches | +0.6% to +2.2%, `x-ray` -2.3% | +0.6% to +3.3% | yes |

`x-ray` at level 1 moves 2 to 4 percent either way between builds, in its literals'
Huffman coding, which none of these changes touch.

### Goose `0bdbd18`

2026-10-13: the pin moved from `a6249a4` to `0bdbd18`. The package at `64f7bc5`, built
by each compiler, writes the same output, and in 3 alternating rounds of `bench LEVEL
FILE 5` every cell is within 1.9 percent: gzip levels 1, 6, and 9 -1.2 to +1.2
percent, zstd levels 1 and 3 -1.4 to +1.9. The results above stand for `0bdbd18`.

### Goose `46356c2`

2026-10-14: the pin moved from `0bdbd18` to `46356c2`. The tests pass, and `bench` at
`d10dd61` writes the same output as with `0bdbd18`. The compiler drops 584 of
`bench`'s 862 index checks, against 560 of 851 at `a6249a4`; since then it also drops
the check on `win[p - d]` after a guard.

`bench` at `e1a9800` built by `46356c2`, against `d10dd61` built by `0bdbd18` (the
source differs only in a comment), in 3 alternating rounds of `bench LEVEL FILE 5`
(`build/task005/ab.sh`), the median of the rounds' medians: gzip levels 1, 6, and 9
-1.2 to +2.9 percent, zstd levels 1 and 3 -2.4 to +1.4. zstd on `webster` at level 1
came out at -4.2 percent and at -1.5 in 5 rounds of its own, whose rates overlap. The
pin moves no rate.

### zstd levels 1 and 3 at `e1a9800`

2026-10-14, task 005 step 5, Goose `46356c2`, measured as at
[`8ec4538`](#zstd-levels-1-and-3-at-8ec4538): `FORMAT=zstd bench/run.sh`, 10 runs per
cell, the median. The run went twice; each cell's medians agreed within 4.1 percent,
except klauspost at level 1 on `dickens` (6.5), `libzstd-w17` at level 3 on `x-ray`
(5.2), and klauspost at level 3 on `xml` (5.1). The table is the first. The output is
the same as at `b396581`.

| File | MB | Level 1 goose | libzstd | libzstd, 128 KB | klauspost | Level 3 goose | libzstd | libzstd, 128 KB | klauspost |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| dickens | 10.2 | 219.3 | 351.9 | 307.4 | 193.1 | 164.2 | 187.5 | 208.0 | 156.6 |
| webster | 41.5 | 266.6 | 405.4 | 358.5 | 254.2 | 205.1 | 238.1 | 271.1 | 198.4 |
| xml | 5.3 | 554.9 | 830.7 | 709.8 | 490.9 | 479.7 | 616.6 | 582.9 | 400.9 |
| nci | 33.6 | 745.0 | 1,023.1 | 963.5 | 648.4 | 671.2 | 819.8 | 819.1 | 598.8 |
| mozilla | 51.2 | 330.9 | 519.3 | 447.5 | 330.2 | 238.4 | 281.5 | 316.5 | 260.7 |
| samba | 21.6 | 406.3 | 608.0 | 513.0 | 396.7 | 324.2 | 383.8 | 415.6 | 326.4 |
| x-ray | 8.5 | 676.3 | 841.4 | 940.9 | 2,281.4 | 155.3 | 145.4 | 212.7 | 151.9 |

At level 1, libzstd is 1.37 to 1.60 times faster on six files and 1.24 times on
`x-ray`; klauspost's rate is 0.87 to 1.00 times the package's on six files, and 3.4
times on `x-ray`. At level 3, libzstd is 1.14 to 1.29 times faster on six files, and
the package 1.07 times faster on `x-ray`; klauspost's rate is 0.84 to 1.09 times the
package's. Against libzstd at the package's 128 KB window, libzstd is 1.26 to 1.40
times faster at level 1 and 1.22 to 1.37 at level 3.

### zstd levels 1 and 3 at `257090f`

2026-10-14, task 005 step 5, Goose `46356c2`, after `b0199ba` (literals coded four at
a time) and `257090f` (a sequence's bits in one flush)
([history](#task-005-zstds-literals-and-sequences-at-257090f)),
measured as at [`e1a9800`](#zstd-levels-1-and-3-at-e1a9800). The run went twice; each
cell's medians agreed within 2.3 percent, except klauspost's: within 14.2 at level 3 on
`xml`, 12.6 at level 1 on `x-ray`, and 5.6 or less elsewhere. The table is the first.
The output is the same as at `b396581`.

| File | MB | Level 1 goose | libzstd | libzstd, 128 KB | klauspost | Level 3 goose | libzstd | libzstd, 128 KB | klauspost |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| dickens | 10.2 | 227.8 | 358.4 | 313.0 | 207.3 | 175.7 | 195.9 | 212.7 | 165.5 |
| webster | 41.5 | 273.3 | 415.7 | 357.8 | 254.2 | 210.5 | 240.8 | 277.5 | 202.9 |
| xml | 5.3 | 565.1 | 829.7 | 710.2 | 531.5 | 488.7 | 614.6 | 580.4 | 421.0 |
| nci | 33.6 | 754.2 | 1,007.5 | 976.7 | 656.2 | 682.6 | 811.8 | 815.8 | 601.2 |
| mozilla | 51.2 | 339.9 | 525.0 | 448.1 | 336.3 | 240.5 | 284.8 | 322.4 | 264.2 |
| samba | 21.6 | 418.3 | 607.8 | 519.4 | 418.6 | 335.2 | 383.1 | 413.6 | 345.3 |
| x-ray | 8.5 | 710.6 | 841.5 | 939.3 | 2,301.6 | 160.1 | 148.1 | 213.1 | 151.2 |

At level 1, libzstd is 1.34 to 1.57 times faster on six files and 1.18 times on
`x-ray`; klauspost's rate is 0.87 to 1.00 times the package's on six files, and 3.2
times on `x-ray`. At level 3, libzstd is 1.11 to 1.26 times faster on six files, and
the package 1.08 times faster on `x-ray`; klauspost's rate is 0.86 to 1.10 times the
package's. Against libzstd at the package's 128 KB window, libzstd is 1.24 to 1.37
times faster at level 1 and 1.19 to 1.34 at level 3.

### zstd levels 1 and 3 at `7a96425`

2026-10-14, task 005 step 5, Goose `46356c2`: level 1's hash table cut to libzstd's
2^13 entries ([history](#level-1s-hash-table-against-the-l2)),
`FORMAT=zstd bench/run.sh`: seven Silesia files, one-shot, the whole file in
memory, 10 runs per cell; MB/s is the median. libzstd v1.5.7 is a CMake `Release`
build with clang 22.1.3, run through `bench/ref.c` at `-O2` with its checksum on.
`libzstd-w17` uses a 128 KB window; the other libzstd columns use 512 KB at level 1
and 2 MB at level 3. klauspost/compress v1.20.3 is built by Go 1.27.0 and uses
`EncodeAll`, `WithEncoderCRC(true)`, `SpeedFastest` and `SpeedDefault`.
The run went twice; each cell's medians agreed within 5.4 percent. The table is the
first. Level 3's output is
the same as before; level 1's is 0.0 to 12.1 percent larger than libzstd's at level 1,
and 0.3498 of Silesia's 12 files against libzstd's 0.3455.

| File | MB | Level 1 goose | libzstd | libzstd, 128 KB | klauspost | Level 3 goose | libzstd | libzstd, 128 KB | klauspost |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| dickens | 10.2 | 262.5 | 360.0 | 313.7 | 204.4 | 174.2 | 193.2 | 207.6 | 160.4 |
| webster | 41.5 | 308.7 | 416.9 | 358.8 | 255.8 | 205.4 | 237.4 | 264.5 | 196.5 |
| xml | 5.3 | 594.1 | 829.8 | 710.9 | 490.7 | 485.6 | 613.9 | 574.8 | 424.8 |
| nci | 33.6 | 736.0 | 1,007.6 | 975.9 | 643.8 | 680.8 | 818.3 | 819.0 | 570.0 |
| mozilla | 51.2 | 393.1 | 517.9 | 445.6 | 335.7 | 238.4 | 281.6 | 318.3 | 261.9 |
| samba | 21.6 | 453.9 | 611.9 | 510.2 | 394.2 | 327.6 | 381.3 | 408.0 | 330.8 |
| x-ray | 8.5 | 810.7 | 837.2 | 937.0 | 2,223.3 | 157.9 | 144.7 | 214.0 | 150.7 |

At level 1, libzstd is 1.32 to 1.40 times faster on six files and 1.03 times on
`x-ray`; klauspost's rate is 0.78 to 0.87 times the package's on six files, and 2.7
times on `x-ray`. Against libzstd at the package's 128 KB window, whose output is 1 to 4
percent larger than the package's on six files, libzstd is 1.12 to 1.33 times
faster at level 1. Level 3's output is 0.3251 of the 12-file corpus, against libzstd's
0.3121 and
0.3326 with a 128 KB window. The package writes 2.5 to 12.8 percent more than
libzstd on the seven rate-test files. At level 3, libzstd is 1.11 to 1.26 times faster
on six files; the package is 1.09 times faster on `x-ray`.

## AMD Ryzen 7 5800X3D, WSL2

- AMD Ryzen 7 5800X3D (Zen 3, 8 cores, 16 threads), Windows 11, Ubuntu 26.04.1 in
  WSL2, kernel 6.18.54.1-microsoft-standard-WSL2.
- Goose `v2026.3`, `goose build` defaults, with `CC=gcc`: gcc 15.2.0
  (Ubuntu 15.2.0-16ubuntu1), the compiler HttpArena builds its servers with.
- Run from a clone on WSL's own filesystem. No other benchmark ran.

### Level 1's `load32` and next bucket, with gcc

2026-10-23, the [M1 Pro's comparison](#level-1s-load32-and-next-bucket-not-kept)
again, with gcc on x86-64, where a server's profile showed `load32` as a symbol of its
own, not inlined. `bench/compare.sh` at `208fe93` (branch `match-fast`), every build
byte-identical to `7e9e2d8`:

```sh
CC=gcc ROUNDS=2 LEVELS="1 6" bench/compare.sh 7e9e2d8 match-fast-load32 e7f03e2 match-fast-next-bucket
CC=gcc ROUNDS=1 BODIES= FILES="build/bench/corpus/dickens build/bench/corpus/x-ray" LEVELS="1 6" bench/compare.sh 7e9e2d8 match-fast-load32 e7f03e2
```

`match-fast-load32` is `8378681`, `match-fast-next-bucket` `eed8bf9`. The load average
was 1.2 to 1.5. The bodies, in µs a call:

| Body | Level | Bytes out | `7e9e2d8` | `8378681` | `e7f03e2` | `eed8bf9` |
|---|---:|---:|---:|---:|---:|---:|
| 100 bytes | 1 | 108 | 2.71 | 2.65 | 2.79 | 2.80 |
| 100 bytes | 6 | 108 | 3.03 | 2.92 | 3.02 | 3.02 |
| 25 items | 1 | 1,008 | 17.79 | 13.50 | 19.04 | 19.23 |
| 25 items | 6 | 938 | 29.59 | 23.26 | 29.68 | 29.32 |
| 40 items | 1 | 1,420 | 26.27 | 19.62 | 28.22 | 28.72 |
| 40 items | 6 | 1,273 | 47.25 | 35.02 | 49.75 | 45.78 |
| 50 items | 1 | 1,703 | 32.45 | 23.31 | 35.24 | 36.35 |
| 50 items | 6 | 1,483 | 60.78 | 43.38 | 61.69 | 58.90 |

Silesia, in MB/s:

| File | Level | `7e9e2d8` | `8378681` | `e7f03e2` |
|---|---:|---:|---:|---:|
| `dickens` | 1 | 125.5 | 144.5 | 118.0 |
| `dickens` | 6 | 48.7 | 58.4 | 49.7 |
| `x-ray` | 1 | 83.6 | 96.2 | 87.0 |
| `x-ray` | 6 | 73.9 | 82.4 | 73.5 |

The cells within 3 percent of `7e9e2d8`, one round more each, at a load average of 1.0:
100 bytes at level 1, 2.79 against `8378681`'s 2.64, `e7f03e2`'s 2.79, and `eed8bf9`'s
2.79; at level 6, 3.06 against 2.93, 3.02, and 3.04; 25 and 50 items at level 6, 29.44
and 60.43 against `e7f03e2`'s 29.32 and 59.12 and `eed8bf9`'s 29.41 and 57.49;
`dickens` and `x-ray` at level 6, 50.9 and 75.7 MB/s against `e7f03e2`'s 52.5 and 74.7.

With gcc, the inline `load32` wins everywhere measured: 24 to 28 percent off the
bodies of 25 to 50 items at level 1 and 21 to 29 percent at level 6, 4 to 5 percent off
100 bytes, and 12 to 20 percent more MB/s on Silesia. gcc doesn't inline the C `load32`
that Apple clang does. The next bucket found early costs the bodies 3 to 12 percent at
level 1, as on the M1 Pro, and is within 3 percent at level 6.

The inline `load32` is kept for gcc, where servers build, at the M1 Pro's cost
([decisions](decisions.md#settled), 2026-10-23); the next bucket isn't.

### Level 1 and the symbol coder in C

2026-10-23, for Plod's HttpArena json-comp entry, which gzips each response at level 1.
gcc 15.2.0 with `-O3 -march=native` after Goose's flags, through a wrapper passed as
`CC`, as the entry's Dockerfile builds; each program pinned to one CPU with `taskset`.
The bodies' times are `bench/json` with 41 batches of 500 calls, the best of 3 rounds'
medians, in µs a call; libdeflate is v1.26, CMake `Release`, timed by the same method
in a C program around `libdeflate_gzip_compress` with one compressor kept.

Before changing anything, the base `241673c` against libdeflate, and the base with
every index and slice check stripped from its generated C (`GS_IDX` made the index
itself, and each `gs_abort(GS_E_SLICE, ...)` test deleted), an upper bound for what
dropping checks gives:

| Body | Base | Base, no checks | `shim/deflate.c` | libdeflate |
|---|---:|---:|---:|---:|
| `json25` | 11.71 (1,008 B) | 10.15 | 10.04 | 9.60 (1,012 B) |
| `json40` | 16.51 (1,420 B) | 14.29 | 14.02 | 12.50 (1,421 B) |
| `json50` | 19.86 (1,703 B) | 16.92 | 16.52 | 14.60 (1,708 B) |

A profile of `json40` (`perf record -F 20000`) put level 1's loop at 65 percent of the
base's time, `put_syms` and `end_block` at 22, and the Huffman sort at 4; libdeflate's
`deflate_compress_fastest`, which clears its 128 KB table each call, took 68 percent of
its 12.6 µs, the same 8.5 µs as the shim's loop.

`bench/compare.sh base .`, the branch against `241673c`, every output byte-identical,
3 rounds (Silesia 3 runs a round), the load average 1.0 to 1.1:

| Input | Level | `241673c` | Branch |
|---|---:|---:|---:|
| `json25` | 1 | 11.71 | 10.28 |
| `json40` | 1 | 16.58 | 14.20 |
| `json50` | 1 | 19.80 | 16.85 |
| `json40` | 6 | 30.90 | 31.33 |
| `json40` | 9 | 45.49 | 45.76 |
| `dickens` | 1 | 155.0 MB/s | 189.6 MB/s |
| `mozilla` | 1 | 173.0 MB/s | 198.8 MB/s |
| `nci` | 1 | 420.5 MB/s | 465.8 MB/s |
| `x-ray` | 1 | 103.2 MB/s | 114.2 MB/s |
| `xml` | 1 | 328.3 MB/s | 376.6 MB/s |
| `samba` | 1 | 232.0 MB/s | 262.9 MB/s |
| `ooffice` | 1 | 124.3 MB/s | 141.4 MB/s |

Levels 6 and 9 stayed within 3 percent on every input, the bodies and the seven files.

Two alternatives, not kept:

- A `checkfree` Goose loop with the shim's interface, every index proved
  ([findings](goose-findings.md#bounds-check-elimination-misses-an-lz-matchers-facts)),
  with the C symbol coder: 10.89, 15.35, and 18.52 µs, against the shim's 10.05, 14.04,
  and 16.48 in alternating rounds. It ran 270,050 instructions a call on `json40`
  against 234,627, and 67,919 cycles against 62,743 (`perf stat`). Its first form ran
  slower than the base: gcc kept `load8`'s eight byte loads separate, and compiled a
  `% 30` reduction to `idiv`.
- The next position's bucket hashed and prefetched a position ahead, as libdeflate's
  `next_hash`: in the entry's server (below), 159.5K requests a second against 162.3K
  without, in alternating runs.

The entry's server, built natively at Plod `ef8b625` (goose-http `v0.5.7`) with the
same gcc and flags, on CPUs 0 to 3, under wrk 4.1.0 with goose-http's
`bench/json-comp.lua` (json-comp's seven requests in turn, `Accept-Encoding: gzip, br`)
on CPUs 4 to 15, 8 threads, 512 connections, 20 s, with perf over 10 s of it: 152.0K
requests a second at `v0.1.3` and 161.9K with the shim, in two alternating runs each.
CPU a request, from `/proc/stat` over the same 10 s: 26.6 to 26.9 µs at `v0.1.3`, 25.5
with the shim. Aegon's entry, its binary and libraries copied from its HttpArena image
and run the same way, served 191.5K to 193.6K at 21.2 to 21.4 µs, 51.8 percent of it in
libdeflate, for seven bodies a cycle where Plod compresses five (goose-http's
`min_size` was 1,024 bytes). With the shim, gzip is about 45 percent of Plod's CPU;
Plod's kernel time is 8.1 µs a request against Aegon's 6.1, and its other user code
5.7 µs against 3.2.
