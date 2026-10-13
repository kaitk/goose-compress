# Results

The package against libdeflate and zlib-ng, and in zstd against libzstd and
klauspost/compress: each machine's latest run. Each machine has
a section of its own, which starts with how the machine and its tools were set up;
numbers from different machines aren't compared. How to run them is in
[development.md](development.md#benchmark). Earlier runs, level 0, small inputs, and
the measurements behind each change are in [results-history.md](results-history.md).

- [Apple M1 Pro, macOS](#apple-m1-pro-macos)
- [AMD Ryzen 7 5800X3D, Windows](#amd-ryzen-7-5800x3d-windows)

## Apple M1 Pro, macOS

- MacBook Pro `MacBookPro18,3`, Apple M1 Pro (8 performance and 2 efficiency cores),
  macOS 26.3.1 (Darwin 25.3.0).
- Goose `c38dc0f`, `goose build` defaults (`-O2`), with Apple clang 21.0.0
  (`clang-2100.0.123.102`).
- libdeflate v1.26 and zlib-ng 2.3.3, CMake `Release` builds with their default
  options, which pick each CPU's fastest code at run time; `bench/ref.c` at `-O2`, same
  compiler.
- Desktop apps and other agent sessions, idle, ran beside the run, at a load average
  of 5.3 before it and 8.4 at its end, and no other benchmark.

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
memory. Desktop apps (a terminal, Firefox) ran beside the run at a load average of 4 to
10, and no other benchmark.

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

- Desktop on an MSI `MS-7A34` board, AMD Ryzen 7 5800X3D (Zen 3, 8 cores, 16 threads,
  AVX2 and no AVX-512), 32 GB, Windows 11 Pro 10.0.26200.
- Goose `a6249a4`, `goose build` defaults: `clang-cl` 22.1.3 at `/O2`, from Visual
  Studio Build Tools 2026 (18). `simd fn`s get an AVX2 version.
- libdeflate v1.26 and zlib-ng 2.3.3, CMake `Release` builds with Ninja and clang
  22.1.3 and their default options, which pick each CPU's fastest code at run time;
  `bench/ref.c` at `-O2`, same compiler.
- Run from Git Bash. Docker Desktop, Firefox, and two idle agent sessions ran beside
  the benchmark, at about 2 percent CPU load before it started, and no other benchmark
  or build.

### Levels 0, 1, 6, and 9 at `6b57c40`

2026-10-13, task 005 step 1, package at `6b57c40`, the baseline for task 005. On this
machine it adds `d71eb59`, `1f1ed62`, and `865d359` to the last run, at `43cb937`
([history](results-history.md#levels-1-6-and-9-at-43cb937)).
`LEVELS="0 1 6 9" bench/run.sh`: gzip output, one-shot, the whole file in memory, 10
runs per cell; MB/s is the median of the 10. Sizes are each output's bytes against
libdeflate's at the same level, from one run of `bench` and `ref`.

| File | MB | Level 0 goose | zlib-ng | libdeflate |
|---|---:|---:|---:|---:|
| dickens | 10.2 | 2,756.1 | 17,251.9 | 19,144.3 |
| webster | 41.5 | 2,769.0 | 15,777.0 | 14,313.9 |
| xml | 5.3 | 2,639.0 | 17,209.5 | 12,858.5 |
| nci | 33.6 | 2,833.1 | 16,562.2 | 17,465.7 |
| mozilla | 51.2 | 2,639.4 | 14,213.7 | 13,814.6 |
| samba | 21.6 | 2,804.5 | 15,676.1 | 18,829.1 |
| x-ray | 8.5 | 2,724.9 | 17,178.7 | 18,727.6 |

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
[results-history.md](results-history.md#task-005-steps-2-and-3-simd-fn-and-the-codegen-ceiling).

### Levels 1, 6, and 9 at `9f7a539`

2026-10-13, task 005 step 3: libdeflate's chain search ported to Goose. It writes the
same bytes as `6b57c40`. Measured in 3 alternating rounds of `bench LEVEL FILE 5`
against `6b57c40` and the libraries; MB/s is the median of the rounds' medians. Per
file, with the C prototypes behind the change, in
[results-history.md](results-history.md#task-005-step-3-libdeflates-chain-search-at-9f7a539).

| Level | goose MB/s | libdeflate MB/s | zlib-ng MB/s | goose / libdeflate | Against `6b57c40` |
|---:|---:|---:|---:|---:|---:|
| 1 | 143–396 | 163–651 | 158–883 | 0.61–0.88 | -1.7% to +4.4% (unchanged code) |
| 6 | 62–183 | 74–237 | 67–214 | 0.73–0.84 | +21.7% to +40.2% |
| 9 | 31–85 | 31–103 | 28–81 | 0.82–1.09 | +25.1% to +92.3% |

Level 9 runs at 0.93 to 1.09 of libdeflate's rate on six files, faster on `mozilla`
and `samba`, and 0.82 on `x-ray`.

### Level 1 at `24ac46b`

2026-10-13, task 005: level 1 in libdeflate's 2-entry hash buckets, measured as at
`9f7a539`. Output is within 0.2 percent of libdeflate's size on all seven files, where
`9f7a539` wrote 0.6 to 20.3 percent more, at 103 to 333 MB/s, 11 to 28 percent slower
than `9f7a539` and 0.51 to 0.63 of libdeflate's rate. The same matcher in hand-fixed C
loses at most 2.4 percent on four files, so the loss is taken as codegen to win back
([history](results-history.md#task-005-level-1-in-libdeflates-2-entry-buckets-at-24ac46b)).

