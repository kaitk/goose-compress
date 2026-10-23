# Development

The package is Goose with no C, so it builds wherever the Goose compiler does. Tests and
benchmarks have run on macOS and on Windows under Git Bash (2026-10-14); they need a
POSIX shell, Python 3.14 or later, `gzip`, the `zstd` command, and Go for
`bench/build.sh`, and should run unchanged on Linux. Both DEFLATE and zstd benchmarks
have run on macOS and
Windows; on Linux, only `test/run_tests.py` has run, on x64 in Docker's `python:3.12`
image with its gcc (2026-10-15).

## Toolchain

Use the Goose pin in [README.md](../README.md#pins). The scripts also need:

| Tool | Requirement | Purpose |
|---|---|---|
| C compiler | clang; `clang-cl` on Windows with Visual Studio Build Tools | `goose build` and benchmark harnesses; SIMD builds require clang |
| CMake and build tool | CMake with Make, Ninja, or a Visual Studio generator | Goose and benchmark libraries |
| Python | 3.14 or later with `zlib` and `compression.zstd` | round-trip tests |
| gzip and zstd | commands on `PATH` | independent decompression checks |
| Go | a version supported by `bench/klauspost/go.mod` | klauspost benchmark |
| POSIX shell, git, curl, unzip, shasum | on `PATH`; Git Bash on Windows | test and benchmark scripts |

Exact hardware, OS, compiler, and library versions for measured runs belong in
[results](results.md) and [results history](results-history.md).

## Set up the Goose compiler

The scripts use the Goose release pinned in `scripts/goose.sh` (`v2026.3`, 2026-10-21)
unless told otherwise. The first script that needs the compiler downloads the release's
archive for the platform from
[the releases page](https://github.com/aardappel/goose/releases), checks its SHA-256,
and unpacks it into `build/goose-v2026.3-<platform>/`; later runs reuse it. Run
`scripts/goose.sh` to fetch it and print the compiler's path. The release needs the Xcode
command line tools on macOS and the C library's headers on Linux
([Goose's README](https://github.com/aardappel/goose#install-a-release)). Linux on arm64
has no release archive, so there the script builds the release's tag from source, as
`GOOSE_COMMIT` does below.

Use another compiler only when the release can't do the job, such as a Goose fix not
yet released. Two settings choose one, and the first set wins:

| Setting | Compiler |
|---|---|
| `GOOSE` | The binary it names, such as a checkout's build or a release unpacked elsewhere. |
| `GOOSE_COMMIT` | That commit of `aardappel/goose`, cloned into `build/goose-<commit>/` and built with CMake (and Ninja if installed) on first use. Give the full 40-hex hash; a shallow fetch can't resolve an abbreviated one. |

The release's `stdlib/` under `build/` needs no `exclude`: the repository has no `.build`
sidecar, and the tests pass with the release unpacked there (2026-10-15). A sidecar
added later needs `exclude = ["build"]`, as goose-http's has, because Goose collects a
package's JIT symbol table from every `.goose` file under its root, and the release's
stdlib declares the runtime's `extern fn`s.

To build a checkout by hand, clone it anywhere and point `GOOSE` at its build. Don't edit
it (`AGENTS.md`):

```sh
git clone -o upstream https://github.com/aardappel/goose.git ../goose
cmake -S ../goose -B ../goose/build-macos -DCMAKE_BUILD_TYPE=Release
cmake --build ../goose/build-macos -j
export GOOSE=$PWD/../goose/build-macos/goose
```

On Linux, name the build directory `build-linux`. On Windows, configure with
`-G "Visual Studio 18 2026"` in PowerShell, with the Visual Studio Build Tools' CMake,
and build with `--config Release`; the compiler is then
`..\goose\build\Release\goose.exe`. A checkout's compiler finds the stdlib by walking up
from its own binary, and a release's sits beside it, so neither needs a setting.

On Windows, `goose build` finds `clang-cl` in the Build Tools on its own
(`goose toolchain` says which compiler it chose), which matters for speed: `simd fn`
builds AVX2 and AVX-512 versions only under clang, and MSVC ignores it. Run the scripts
from Git Bash, where `scripts/goose.sh` fetches the `windows-x64` release.

### Move the pin

The pin is a Goose release. At the start of a session, check for a newer one:

```sh
gh release list -R aardappel/goose --limit 3
```

To move to a new release, update `goose_release` and the four archives' SHA-256 sums in
`scripts/goose.sh`. GitHub lists each asset's digest:

```sh
gh api repos/aardappel/goose/releases/tags/<tag> -q '.assets[] | "\(.name) \(.digest)"'
```

Then run `scripts/test.sh`, and update the pin in `README.md` and this page's release
paths, in its own commit with the tests and results that still hold. Packages imported
by the same program must use a compatible Goose pin, since the program builds with one
compiler.

Pin a commit only when a Goose fix that this repository needs isn't in a release yet:
set `GOOSE_COMMIT` in the scripts' environment, record the commit in the README's Pins
table with the reason, and return to a release once one includes the fix.

## Test

`scripts/test.sh` runs everything, and stops at the first step that fails:

1. `goose check` of each root file under `test/` and `bench/`.
2. `test/run_tests.py`: the tests under `test/<area>/` ([Run the tests](#run-the-tests)).
   `test/checksums/` checks CRC-32, Adler-32, and XXH64 against known values and
   across splits of their input, and CRC-32 against a bit at a time at lengths on
   each side of 2 KB, where it starts to take two halves at once. `test/deflate/` checks the Huffman code builder
   (RFC 1951's canonical-code example, optimal lengths, and Fibonacci frequencies cut
   to 15 and 7 bits), the exact bytes of small streams at level 0 and of small fixed
   and dynamic Huffman streams at level 1, what the levels match differently (level 1
   tries a bucket's 2 newest entries and level 2 follows the chain past them; levels 5
   and up take a literal for a longer match one byte on), and matches at distance
   32,768. `test/stream/` checks flushes, `reset`, and that a stream's bytes don't
   depend on how its input was split across writes, at levels 0, 1, 2, 6, and 9; and
   that streams one after another through one encoder, reset between them, code as
   new encoders' do at levels 1, 2, and 6, including a stream after enough empty
   ones to bring the offsets round past 2^31, where the tables must have been cleared
   for it to. Each
   exact-byte stream at level 1 and up was checked by decompressing it with Python's
   `zlib`. `test/zstd/` checks the exact bytes of empty, raw, RLE, and compressed
   blocks: two with sequences and the predefined tables, the second across a flush with
   a repeat offset; one of Huffman literals alone; and two across a flush, the first
   building its literal length and offset tables and the second repeating them; and
   one at level 3 of 5-byte matches that level 1 misses. Each was checked with
   `zstd -d` and `compression.zstd`. After `reset`, a zstd stream must come out as from
   a new encoder, with no table to repeat, after streams at levels 3 and 1 too; and its
   bytes don't depend on how its input was split across writes.
3. `goose build` of `test/encode.goose` into `build/encode`, a command that compresses
   a file at a level, one-shot or by a plan of writes and flushes.
4. `scripts/roundtrip.py`: `build/encode` on each input in gzip, zlib, and raw DEFLATE,
   at levels 0, 1, 2, 6, and 9, and in zstd at levels 1 and 3, one-shot and streamed.
   Each output must decompress to its input through Python's `zlib`, and gzip output
   through `gzip -dc` too; zstd output through `compression.zstd`, and one-shot through
   `zstd -dc` too. At each flush, the output so far must decompress to exactly the
   input written so far, and DEFLATE's must end in `00 00 ff ff`. The inputs are
   empty, one byte, text, JSON, random bytes, random inputs of 65,534 to 131,073 bytes
   around the stored blocks' 65,535-byte limit and zstd's 131,072-byte block, long
   runs and repeated blocks, bytes that repeat at distances 32,767, 32,768, and 32,769,
   random bytes with runs copied from up to 40 KB back, 16,000 bytes whose optimal
   Huffman code needs 17 bits, bytes that repeat at 131,071 and 131,072, at the edge of
   zstd's window and past it, 5-byte words with a random byte between, which fill
   a zstd block's 16,384 sequences, skewed bytes of nearly every value, which zstd
   codes with 11-bit Huffman codes and FSE-coded weights, and 440,000 bytes of text,
   short matches, JSON, skewed bytes, and copies in turn, whose zstd blocks change
   statistics. The plans write in 257-byte pieces, which end
   inside matches, and flush every 1,000 and every 32,769 bytes, so matches run across
   writes and flushes. One-shot at level 1 and up, inputs that repeat must compress
   below a limit set for each, a few percent above what level 1 reaches, in DEFLATE
   and in zstd; text, JSON, and the copies within 40 KB have a tighter DEFLATE limit
   from level 6, a few percent above what level 6 reaches, and those, short matches,
   and the changing input a zstd limit of their own from level 3, looser for the JSON,
   where level 3 does worse than level 1. The script then reads back
   the header of the 17-bit input's block: its literal/length code must reach exactly
   15 bits and be complete. It reads back the changing input's zstd frames too, block
   by block: one-shot, some must build sequence tables; flushed every 1,000 bytes,
   some must repeat the last block's; and the two must take all four table modes
   between them. A fuzz run of 200 random inputs, levels, and plans follows,
   with seed 0; `--levels`, `--zstd-levels`, `--fuzz N`, and `--seed S` change them.

```sh
scripts/test.sh
```

`GOOSE`, `GOOSE_COMMIT`, and `CC` pass through to `test/run_tests.py`. It took about 48 s
on the M1 Pro and 99 s on the Ryzen under Git Bash, where starting a process costs more
(2026-10-13); 46 s on the M1 Pro with `v2026.1` and `test/run_tests.py` (2026-10-15).
`encode` is built with `goose build` because `roundtrip.py` runs it 3,880 times.

### Run the tests

Each test is a program, `test/<area>/<name>.goose`, that prints what it checks and
asserts it; `test/expected/<name>.out` holds what it must print. The shared helpers are
`test/check.goose`, which a test imports with `import check from "../";`. Names are
unique across areas, since `test/expected/` is one directory. `test/run_tests.py` is
Python 3 with its standard library alone:

```sh
python3 test/run_tests.py                # every test
python3 test/run_tests.py deflate        # one area
python3 test/run_tests.py crc32          # one test; names and areas can be mixed
python3 test/run_tests.py -O0 zstd       # one level only
python3 test/run_tests.py --bless crc32  # rewrite test/expected/crc32.out from its output
```

It compiles the tests to C in batches, a `goose --multi-test` run per batch, at `-O0`
and `-O2`; builds each with the C compiler `goose toolchain` names (`CC` chooses
another, as for `goose build --cc`), against the Goose runtime compiled once per level,
into `build/test/`; and runs each as a process of its own, in parallel (`-j N`). Both
levels, since `-O2` inlines and folds what `-O0` leaves alone, and native C builds the
package as its users do; together they took about 4 s on the M1 Pro (2026-10-15). A
run passes when its stdout is the `.out` file, and it exits 0. Where
`test/expected/<name>.aborts` exists, the run must exit nonzero instead, and each
nonblank line of `test/expected/<name>.stderr` must occur in its stderr. A file with
`// error: <message>` lines is a fixture that must not compile: `goose --check` must
exit 1, with each message in its diagnostics. The runner reports every failure, with a
diff for a changed output, then a count per area, and exits 1 if any test failed; `-v`
lists the passes too.

After a change that alters what a test prints, run it with `--bless`, and read the diff
of `test/expected/` before committing it: blessing writes whatever the program printed
at the first level it ran, provided it exited as expected.

To try one stream by hand:

```sh
build/encode gzip 6 in.txt out.gz 100,f,5,f   # level 6: 100 bytes, flush, 5, flush, the rest
gzip -dc out.gz
```

## Benchmark

`bench/build.sh` builds, into `build/bench/`:

- libdeflate v1.26 and zlib-ng 2.3.3, cloned at those tags into `build/bench/src/` and
  built with CMake in `Release` mode with their default options. Both pick the CPU's
  fastest code at run time, carryless-multiply CRC-32 included. zlib-ng is built with
  its native API (`ZLIB_COMPAT=OFF`).
- libzstd v1.5.7, cloned at that tag and built with CMake from its `build/cmake`
  directory in `Release` mode, as a static library, with its programs and tests off.
- `ref`, from `bench/ref.c`, which compresses a file with any of the three. libzstd
  runs `ZSTD_compress2` with the content checksum on, at its own window, or at the
  package's 128 KB as `libzstd-w17`.
- `klauspost`, from the Go module in `bench/klauspost/`, which compresses a file with
  klauspost/compress at the version its `go.mod` pins, v1.20.3: `EncodeAll` with the
  checksum on, at the level `zstd.EncoderLevelFromZstd` maps zstd's to, so 1 is
  `SpeedFastest` and 3 `SpeedDefault`. `go build` fetches the module into Go's module
  cache. `GO` names the Go toolchain, or `go` on `PATH` without it.
- `bench`, from `bench/bench.goose`, which compresses a file with the package.
- `json`, from `bench/json.goose`, which times the package's one-shot gzip of a small
  body, as a server compresses each response.
- The [Silesia corpus](https://sun.aei.polsl.pl/~sdeor/index.php?page=silesia), 211 MB
  in 12 files, from `silesia.zip`, checked against its SHA-256 before it's unzipped.

`bench/run.sh` then prints a Markdown table: for each file and level, each library's
ratio and its median and best rate over `RUNS` runs. Each run compresses the whole file
in memory to one stream; reading the file isn't timed. `FORMAT=zstd` runs the package
against libzstd, `libzstd-w17`, and klauspost at levels 1 and 3, in place of gzip
against zlib-ng and libdeflate. For gzip, a second table gives the package's µs a call
on the small JSON bodies in `bench/json/` at levels 1 and 6; `BODIES=` skips it. The
bodies' sizes are a test (`test/deflate/json_bodies.goose`), so a change that grows
them fails `scripts/test.sh`; their time is this table's and `bench/compare.sh`'s.

```sh
bench/build.sh
bench/run.sh                                # level 0, 10 runs, 7 Silesia files
LEVELS="1 6 9" RUNS=5 FILES=dickens bench/run.sh
FORMAT=zlib bench/run.sh                    # level 0 zlib: a copy and Adler-32
FORMAT=zstd bench/run.sh                    # zstd levels 1 and 3
```

`run.sh` rounds ratios to 3 places. For zstd's 4-place ratios and Silesia totals, run
`bench`, `ref`, and `klauspost` with `RUNS` 1 and sum their third and fourth fields,
the input and output sizes.

On Windows, `bench/build.sh` builds with `clang` and Ninja. Put the Build Tools' CMake,
Ninja, and LLVM on Git Bash's `PATH` first:

```sh
VS="/c/Program Files (x86)/Microsoft Visual Studio/18/BuildTools"
export PATH="$VS/Common7/IDE/CommonExtensions/Microsoft/CMake/CMake/bin:$PATH"
export PATH="$VS/Common7/IDE/CommonExtensions/Microsoft/CMake/Ninja:$PATH"
export PATH="$VS/VC/Tools/Llvm/x64/bin:$PATH"
bench/build.sh
```

`bench/build.sh` ends by naming the Goose compiler it built `bench` with: the release's
tag, or a checkout's commit. Record it with the results.

The level is passed to each library as it is. Record results with what `agents/benchmarks.md`
asks for, under the machine's own section; a new machine gets a section that starts
with its hardware, OS, compiler, and library builds. `docs/results.md` holds each
machine's latest full run only: when a new one replaces it, move the old one to
`docs/results-history.md`, where each change's measurements and other one-off runs go
too.

To compare a change, build `bench/bench.goose` before and after it into two binaries
with `goose build -o`, and run them in alternating rounds on the same files: the
libraries' rates varied about 4 percent between sessions, and two builds of the same
code about 1 percent within one.

`bench/compare.sh` does that for any commits, a branch, or `.` for the working tree.
It builds this checkout's `bench/json.goose`, `bench/bench.goose`, and
`test/encode.goose` against each one's package, stops if any gives other output than
the first, and prints a table of the best round for each input, build, and level, with
the load average over the rounds. The small bodies in `bench/json/` are JSON
responses of the shape HttpArena's `/json/:count` asks for, 25, 40, and 50 items, and
the first 100 bytes of a one-item one:

```sh
bench/compare.sh BEFORE AFTER                            # the bodies at level 1
LEVELS="1 6" ROUNDS=5 bench/compare.sh BEFORE AFTER
BODIES= FILES="build/bench/corpus/dickens build/bench/corpus/x-ray" \
    bench/compare.sh BEFORE AFTER                        # Silesia files, in MB/s
BODIES= FILES=build/bench/corpus/dickens FORMAT=zstd LEVELS="1 3" \
    bench/compare.sh BEFORE AFTER
```

It needs only Git, a POSIX shell, and the compiler, so it runs from Git Bash on
Windows too; `FILES` needs `bench/build.sh`'s corpus. Git Bash has no load average,
so the Load column shows `-` there.

### Profile

`goose build` binaries keep their symbols, so macOS's `sample` profiles them while
they run; each Goose function is a C function named `NAMESPACE_NAME_gN`, where
inlined callees are counted in their caller:

```sh
build/bench/bench 6 build/bench/corpus/mozilla 20 & sleep 1; sample bench 4 -file prof.txt
```

`goose check --bce-lines FILE` prints the bounds checks each line kept, and the C
`goose build` writes is in `~/.goose/build/prog/NAME-HASH/NAME.c`.

## Traps

- `return` inside a block passed to a function, such as `each_split(s, ',') { ... }`,
  returns from the function that wrote the block, not from the block (tutorial §13).
  Use `if`/`else` inside the block to skip an item.
- Globals initialize in import order, imported files first (spec §11.1). A file whose
  globals call into another file's globals imports that file itself: `deflate.goose`
  imports `huffman.goose`, because `FIXED_LIT` is built with `HUFF_MAX`. Importing
  both from `compress.goose` alone fails with "may be used before it is assigned".
- Integer literals are decimal or `0x` hex; there is no `0b`.
- `match` takes integer constants only, so strings are compared with `if`/`else if`.
- `args()`, `read_file`, and the other `os` functions need `import os;` even though
  their names are global. Likewise `log2`, `sqrt`, and the other float functions need
  `import math;`. The package's own `log2`, of an `i64`, hides std's in namespace
  `compress`: write `::log2(x)` for the float one.
- `bench/run.sh` sets `LC_ALL=C`: under a locale with a decimal comma, such as
  `et_EE`, awk prints `10,2` and the table's numbers break. Set it in any script that
  computes ratios too: the shell's `printf "%.4f"` rejects `bc`'s `.3781` there.
- A rebuilt zlib-ng keeps options from its CMake cache: delete `build/bench/zlib-ng`
  after changing its options in `bench/build.sh`.
- A constant plus a `u8` is a `u8`: `t[768 + b[4]]` fails with "constant 768 does not
  fit u8". Write `768 + b[4] as i64`. A product wraps with no error: `w[i] * 64` is
  0 for a `w[i]` of 4. Write `(w[i] as i64) * 64`.
- A fixed-size struct passed to an untyped (generic) parameter is a copy, so writes to
  it are lost without a warning: pass `&f` (spec §7.2).
- Shift counts are masked to the type's width (spec §6.2), so `bits >>= 64` leaves
  `bits` as it was. A bit buffer that can fill to 64 bits needs its flush before then.
- `x as i64..end` parses as the variable-mode type `i64..`: write `(x as i64)..end`.
  Likewise `x as i64 & (m)` parses as the reference type `i64&` followed by a call
  ("this expression cannot be called"): write `(x as i64) & m`.
- Several results go only into new names: `let a, b = f();`, not `a, b = f();` into
  existing variables.
- Shrinking a `u8[>..]&` parameter, even after growing it in the same call, makes the
  function one that shrinks it, and a caller holding a slice of that array can no
  longer call it (spec §5.1). The package's functions only append to `out`.
- A hot path that is fast on one machine can be slow on the other: measure a change on
  both, or say which one it was measured on.
- Under zsh, `set -- $v` doesn't split `$v` into words; run such loops with `sh`.
- On Windows, winget puts Go in `C:\Program Files\Go\bin` and links `zstd` into
  `%LOCALAPPDATA%\Microsoft\WinGet\Links`, on the `PATH` of shells started after the
  install only. A Git Bash already open needs both added to its `PATH`.
- Git Bash turns a `clang-cl` flag such as `/O2` into a path (`C:/Program Files/Git/O2`).
  From Git Bash, give `clang-cl` its flags with `-` (`-O2`, `-Fe...`) and Windows paths
  from `cygpath -w`. Linker flags have no `-` form (`/link /DEBUG`): set
  `MSYS_NO_PATHCONV=1` for that command, or, through `clang`, pass `-Wl,-debug`.
- The zstd 1.5.7 command line compresses with worker threads by default, in `zstd -b`
  too: `zstd -b1` gave `dickens` 681 MB/s, and with `-T1` 421, the rate of libzstd in
  `ref`. Pass `-T1` to compare its rates with one thread's.
