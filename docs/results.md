# Results

The package against libdeflate and zlib-ng, and in zstd against libzstd and
klauspost/compress: each machine's latest run. Each machine has
a section of its own, which starts with how the machine and its tools were set up;
numbers from different machines aren't compared. How to run them is in
[development.md](development.md#benchmark). Earlier runs, small inputs, and
the measurements behind each change are in [results-history.md](results-history.md).

- [Apple M1 Pro, macOS](#apple-m1-pro-macos)
- [AMD Ryzen 7 5800X3D, Windows](#amd-ryzen-7-5800x3d-windows)

## Apple M1 Pro, macOS

- Apple M1 Pro (8 performance and 2 efficiency cores),
  macOS 26.3.1 (Darwin 25.3.0).
- Goose `c38dc0f`, `goose build` defaults (`-O2`), with Apple clang 21.0.0
  (`clang-2100.0.123.102`).
- libdeflate v1.26 and zlib-ng 2.3.3, CMake `Release` builds with their default
  options, which pick each CPU's fastest code at run time; `bench/ref.c` at `-O2`, same
  compiler.
- Background load average was 5.3 before the run and 8.4 at its end; no other
  benchmark ran.

### Levels 1, 6, and 9 at `ce13855`

2026-10-12, task 003, package at `ce13855`: task 001's encoder with the chain search's
one range test, the code tables, 2^16 hash buckets, symbols counted as they're added,
the next position's hash carried to the next search, and a match extension's bounds
checked once. `LEVELS="1 6 9" bench/run.sh`: gzip output, one-shot, the whole file in
memory, 10 runs per cell. MB/s is the median of the 10 runs; ratio is output over
input.

| File | MB | Level 1 goose | zlib-ng | libdeflate | Level 6 goose | zlib-ng | libdeflate | Level 9 goose | zlib-ng | libdeflate |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| dickens | 10.2 | 176.3 | 200.5 | 226.8 | 46.4 | 75.0 | 70.1 | 22.6 | 30.1 | 34.2 |
| webster | 41.5 | 194.9 | 239.6 | 262.9 | 65.7 | 85.9 | 94.4 | 26.7 | 44.6 | 39.7 |
| xml | 5.3 | 316.4 | 460.3 | 464.8 | 120.3 | 172.7 | 174.0 | 40.3 | 83.3 | 66.3 |
| nci | 33.6 | 392.9 | 587.2 | 578.6 | 126.7 | 214.9 | 216.5 | 28.1 | 70.2 | 56.5 |
| mozilla | 51.2 | 192.9 | 238.5 | 240.4 | 72.5 | 90.6 | 105.4 | 17.3 | 26.3 | 27.2 |
| samba | 21.6 | 232.5 | 305.3 | 327.6 | 90.3 | 120.9 | 126.2 | 30.0 | 49.9 | 42.9 |
| x-ray | 8.5 | 119.7 | 125.4 | 141.6 | 73.4 | 65.4 | 102.2 | 69.0 | 39.8 | 88.1 |

| File | Level 1 goose | zlib-ng | libdeflate | Level 6 goose | zlib-ng | libdeflate | Level 9 goose | zlib-ng | libdeflate |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| dickens | 0.426 | 0.591 | 0.414 | 0.379 | 0.382 | 0.379 | 0.374 | 0.379 | 0.374 |
| webster | 0.343 | 0.456 | 0.327 | 0.294 | 0.294 | 0.293 | 0.287 | 0.292 | 0.287 |
| xml | 0.200 | 0.221 | 0.166 | 0.129 | 0.128 | 0.128 | 0.122 | 0.124 | 0.122 |
| nci | 0.123 | 0.161 | 0.114 | 0.093 | 0.094 | 0.092 | 0.088 | 0.089 | 0.087 |
| mozilla | 0.400 | 0.468 | 0.394 | 0.378 | 0.379 | 0.367 | 0.376 | 0.372 | 0.365 |
| samba | 0.280 | 0.349 | 0.272 | 0.252 | 0.255 | 0.247 | 0.249 | 0.250 | 0.244 |
| x-ray | 0.747 | 0.929 | 0.743 | 0.738 | 0.741 | 0.708 | 0.738 | 0.703 | 0.706 |

Goose beats zlib-ng's rate on `x-ray` at levels 6 and 9, 73.4 MB/s against 65.4 and
69.0 against 39.8, and loses every other rate. At level 1 it's 1.05 to 1.5 times
slower than zlib-ng and 1.2 to 1.5 times slower than libdeflate; at level 6, 1.25 to
1.7 and 1.4 to 1.7 times; at level 9, 1.3 to 2.5 and 1.3 to 2.0 times. Against task
001 step 4's run, level 1 is 3 to 13 percent faster, level 6 6 to 49 percent (`x-ray`
49.3 to 73.4 MB/s), and level 9 4 to 48 percent. Ratios: level 1 is smaller than
zlib-ng's on all seven files and 0.5 to 20 percent larger than libdeflate's; level 6
is smaller than zlib-ng's on five files, the same on `webster`, and 1 percent larger
on `xml`, and 0 to 4 percent larger than libdeflate's.

### zstd levels 1 and 3 at `237de3a`

2026-10-13, task 004 step 6, package at `237de3a`, Goose `a6249a4`, `goose build`
defaults (`-O2`) with Apple clang 21.0.0. Against:

- libzstd v1.5.7, a CMake `Release` build (`-O3`) with its default options, through
  `bench/ref.c` at `-O2`, same compiler: `ZSTD_compress2` with `ZSTD_c_checksumFlag`
  on, at its own window for the input (512 KB at level 1, 2 MB at level 3), and as
  `libzstd-w17` at the package's 128 KB (`ZSTD_c_windowLog` 17).
- klauspost/compress v1.20.3, built by Go 1.27.2 (Homebrew) with `go build` defaults,
  through `bench/klauspost`: `EncodeAll` with `WithEncoderCRC(true)`, at `SpeedFastest`
  against level 1 and `SpeedDefault` against level 3, with its default window.

Every library writes the content checksum and compresses one-shot, the whole file in
memory. Background load average was 4 to 10; no other benchmark ran.

Rate, MB/s, `FORMAT=zstd bench/run.sh`: 10 runs per cell, the median. The run went
twice; each cell's medians agreed within 0.7 percent, except klauspost's `SpeedDefault`,
within 4.6. The table is the first.

| File | MB | Level 1 goose | libzstd | libzstd, 128 KB | klauspost | Level 3 goose | libzstd | libzstd, 128 KB | klauspost |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| dickens | 10.2 | 132.4 | 419.5 | 418.8 | 212.5 | 113.9 | 226.8 | 233.5 | 188.0 |
| webster | 41.5 | 166.0 | 457.5 | 463.2 | 270.2 | 140.7 | 283.6 | 309.6 | 235.4 |
| xml | 5.3 | 344.9 | 859.9 | 835.3 | 553.9 | 319.9 | 698.5 | 640.8 | 501.4 |
| nci | 33.6 | 450.1 | 1,013.9 | 1,071.6 | 722.7 | 429.9 | 913.9 | 899.3 | 684.5 |
| mozilla | 51.2 | 224.5 | 578.6 | 568.9 | 374.8 | 169.6 | 382.1 | 397.3 | 317.7 |
| samba | 21.6 | 259.0 | 648.0 | 644.5 | 426.1 | 224.4 | 467.3 | 467.4 | 392.6 |
| x-ray | 8.5 | 600.5 | 702.4 | 771.9 | 2,302.7 | 124.2 | 212.4 | 269.3 | 175.0 |

The package loses every rate. At level 1, libzstd is 2.3 to 3.2 times faster on six
files and 1.2 times on `x-ray`; klauspost is 1.6 to 1.7 times faster on six and 3.8
times on `x-ray`, whose literals it leaves raw. At level 3, libzstd is 2.0 to 2.3 times
faster on six files and 1.7 times on `x-ray`; klauspost is 1.4 to 1.9 times. A 128 KB
window leaves libzstd's rate within 10 percent of its own window's either way, except on
`x-ray` at level 3, 27 percent faster.

Ratio, output over input, on the 12 Silesia files: `bench`, `ref`, and `klauspost` run
once on each file. The total is all 12 files' output over their input.

| File | Level 1 goose | libzstd | libzstd, 128 KB | klauspost | Level 3 goose | libzstd | libzstd, 128 KB | klauspost |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| dickens | 0.3955 | 0.4181 | 0.4309 | 0.3992 | 0.3781 | 0.3594 | 0.3955 | 0.3642 |
| webster | 0.3201 | 0.3295 | 0.3410 | 0.3237 | 0.3045 | 0.2918 | 0.3187 | 0.2945 |
| xml | 0.1417 | 0.1297 | 0.1491 | 0.1302 | 0.1341 | 0.1189 | 0.1409 | 0.1205 |
| nci | 0.0873 | 0.0849 | 0.0898 | 0.0890 | 0.0866 | 0.0845 | 0.0919 | 0.0854 |
| mozilla | 0.3848 | 0.3899 | 0.3979 | 0.3828 | 0.3757 | 0.3559 | 0.3742 | 0.3660 |
| samba | 0.2537 | 0.2540 | 0.2701 | 0.2485 | 0.2459 | 0.2293 | 0.2564 | 0.2305 |
| x-ray | 0.7978 | 0.7991 | 0.7995 | 0.9896 | 0.7407 | 0.7181 | 0.7497 | 0.7444 |
| mr | 0.3680 | 0.3825 | 0.3842 | 0.3786 | 0.3582 | 0.3558 | 0.3637 | 0.3606 |
| ooffice | 0.5543 | 0.5841 | 0.5866 | 0.5595 | 0.5262 | 0.5081 | 0.5270 | 0.5184 |
| osdb | 0.3492 | 0.3698 | 0.4018 | 0.3534 | 0.3481 | 0.3472 | 0.3806 | 0.3475 |
| reymont | 0.3173 | 0.3243 | 0.3383 | 0.3266 | 0.3007 | 0.2924 | 0.3141 | 0.2959 |
| sao | 0.8200 | 0.8618 | 0.8703 | 0.8607 | 0.7808 | 0.7622 | 0.7664 | 0.7951 |
| total | 0.3378 | 0.3455 | 0.3556 | 0.3478 | 0.3251 | 0.3121 | 0.3326 | 0.3184 |

At level 1 the package's output is the smallest in total: 2.2 percent smaller than
libzstd's with its 512 KB window, 5.0 percent smaller than with 128 KB, and 2.9 percent
smaller than klauspost's. It's larger than libzstd's on `xml` and `nci`. At level 3 it's
4.2 percent larger than libzstd's and 2.1 percent larger than klauspost's, and 2.3
percent smaller than libzstd's with the same 128 KB window: the window is the whole of
level 3's gap. Where the time goes is in
[results-history.md](results-history.md#zstd-against-libzstd-and-klauspost-task-004-step-6).

## AMD Ryzen 7 5800X3D, Windows

- AMD Ryzen 7 5800X3D (Zen 3, 8 cores, 16 threads,
  AVX2 and no AVX-512), 32 GB, Windows 11 Pro 10.0.26200.
- Goose `46356c2`, `goose build` defaults: `clang-cl` 22.1.3 at `/O2`, from Visual
  Studio Build Tools 2026 (18). `simd fn`s get an AVX2 version.
- libdeflate v1.26 and zlib-ng 2.3.3, CMake `Release` builds with Ninja and clang
  22.1.3 and their default options, which pick each CPU's fastest code at run time;
  `bench/ref.c` at `-O2`, same compiler.
- Run from Git Bash. Background CPU load was about 2 percent before the benchmark;
  no other benchmark or build ran.

### Level 0 at `6b57c40`

2026-10-13, Goose `a6249a4`, `LEVELS="0 1 6 9" bench/run.sh`: seven Silesia
files, gzip output, one-shot, the whole file in memory, 10 runs per cell; MB/s is the
median. Level 0 is unchanged by the later matcher and zstd changes.

| File | MB | Level 0 goose | zlib-ng | libdeflate |
|---|---:|---:|---:|---:|
| dickens | 10.2 | 2,756.1 | 17,251.9 | 19,144.3 |
| webster | 41.5 | 2,769.0 | 15,777.0 | 14,313.9 |
| xml | 5.3 | 2,639.0 | 17,209.5 | 12,858.5 |
| nci | 33.6 | 2,833.1 | 16,562.2 | 17,465.7 |
| mozilla | 51.2 | 2,639.4 | 14,213.7 | 13,814.6 |
| samba | 21.6 | 2,804.5 | 15,676.1 | 18,829.1 |
| x-ray | 8.5 | 2,724.9 | 17,178.7 | 18,727.6 |

### Levels 1, 6, and 9 at `8ec4538`

2026-10-13, task 005: matches extended 8 bytes at a time, Goose `a6249a4`,
`clang-cl` 22.1.3 at `/O2`.
Seven Silesia files, gzip output, one-shot with the whole file in memory; 3 alternating
rounds of `bench LEVEL FILE 5`, the median of the rounds' medians. Output is unchanged
from `24ac46b`. Every cell is 0.8 to 9.0 percent faster than `24ac46b`
([history](results-history.md#task-005-8-byte-match-extension-at-8ec4538)).

| Level | goose MB/s | libdeflate MB/s | goose / libdeflate |
|---:|---:|---:|---:|
| 1 | 107–363 | 163–650 | 0.56–0.66 |
| 6 | 64–196 | 72–232 | 0.74–0.88 |
| 9 | 31–86 | 31–101 | 0.85–1.12 |

### zstd levels 1 and 3 at `7a96425`

2026-10-14, task 005 step 5, Goose `46356c2`: level 1's hash table cut to libzstd's
2^13 entries ([history](results-history.md#level-1s-hash-table-against-the-l2)),
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

These are the latest measured runs, not measurements of every subsequent commit.
