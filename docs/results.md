# Results

The package against libdeflate and zlib-ng: each machine's latest run. Each machine has
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

### Levels 1, 6, and 9 at `43cb937`

2026-10-12, task 003, package at `43cb937`: the chain search's one range test and the
code tables on top of `540ae3c`. `LEVELS="1 6 9" bench/run.sh`: gzip output, one-shot,
the whole file in memory, 10 runs per cell, same machine, compilers, and libraries.
MB/s is the median of the 10 runs; the ratios are as at `540ae3c`
([history](results-history.md#levels-0-1-6-and-9-at-540ae3c)).

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

