# Changelog

What each tag adds. Earlier tags are described by their commits and
[results history](docs/results-history.md).

## v0.1.3 (2026-10-23)

- CRC-32 folds 64 bytes and up with the CPU's carryless multiply, PCLMULQDQ on x86-64
  and PMULL on arm64, in `shim/crc32.c`, built through `compress.build`; other CPUs,
  and `GOOSE_COMPRESS_PORTABLE=1`, keep the Goose tables
  ([decisions](docs/decisions.md#settled)). With gcc on a Ryzen 7 5800X3D, level 0 runs
  2.8 times as fast on `dickens` and 35 to 38 percent faster on the 4 to 8 KB JSON
  bodies, and level 1 is 4 to 6 percent faster on the bodies. With Apple clang on an M1
  Pro, level 0 runs 4.0 times as fast on `dickens`, and level 1 takes 8 to 10 percent
  less time on the bodies ([results](docs/results-history.md#crc-32-on-pmull)).
- `load32` is an `inline fn`. With gcc on the Ryzen, it takes 21 to 29 percent off the
  JSON bodies at levels 1 and 6 and gives 12 to 20 percent more MB/s on Silesia. With
  Apple clang on the M1 Pro it costs 3 to 15 percent at levels 6 and 9; task 008 looks
  for a form that wins under both
  ([results](docs/results-history.md#level-1s-load32-and-next-bucket-with-gcc)).
- Together, in Plod's HttpArena entry on the Ryzen under WSL2, the two take json-comp
  from 77.5K to 93.0K requests a second at 4,096 connections (+20%), and CPU per
  request from 34.4 to 28.7 µs, against Aegon's 113.4K and 23.8 µs.
- `bench/compare.sh` times builds of the package against each other on the small JSON
  bodies in `bench/json/` and on Silesia, and checks their output is the same;
  `bench/run.sh` times the bodies too, and `test/deflate/json_bodies.goose` checks their
  gzip sizes.

The output is v0.1.2's, byte for byte, on every input and level measured.
