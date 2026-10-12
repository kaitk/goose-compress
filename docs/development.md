# Development

The package is Goose with no C, so it builds wherever the Goose compiler does. Tests and
benchmarks have run on macOS so far (2026-10-12); they need a POSIX shell, Python 3, and
`gzip`, and should run unchanged on Linux.

## Toolchain

| Tool | Version used (2026-10-12) | For |
|---|---|---|
| Goose compiler | `c38dc0f`, the pin in `README.md` | everything |
| macOS | 26.3.1, Apple M1 Pro | |
| C compiler | Apple clang 21.0.0 (`clang-2100.0.123.102`) | `goose build`, `bench/` |
| CMake | 4.4.4 (Homebrew) | building the Goose compiler, libdeflate, and zlib-ng |
| Python | 3.14.8 (Homebrew) | `scripts/roundtrip.py`, with its `zlib` module |
| gzip | Apple gzip 475 | `scripts/roundtrip.py` |
| git, curl, unzip, shasum | macOS | `bench/build.sh` |

## Set up the Goose compiler

The scripts run the compiler that `GOOSE` names, or `goose` on `PATH` without it, so the
checkout can live anywhere; this page puts it next to this repository, at `../goose`.
Leave it on the pinned commit and don't edit it (`AGENTS.md`).

```sh
git clone -o upstream https://github.com/aardappel/goose.git ../goose
git -C ../goose checkout c38dc0f
cmake -S ../goose -B ../goose/build-macos -DCMAKE_BUILD_TYPE=Release
cmake --build ../goose/build-macos -j
export GOOSE=$PWD/../goose/build-macos/goose
```

On Linux, name the build directory `build-linux` (goose-http's
[development.md](https://github.com/kaitk/goose-http/blob/main/docs/development.md)
has the Linux and Windows setup). The compiler finds the stdlib by walking up from its
own binary, so a build inside the checkout needs no setting.

### Move the pin

The Goose repository changes daily. Fetch it at the start of a session, and move the pin
in its own commit with the tests and results that still hold:

```sh
git -C ../goose fetch upstream
git -C ../goose log --oneline HEAD..upstream/master
git -C ../goose checkout upstream/master
cmake --build ../goose/build-macos -j
```

Then run `scripts/test.sh`, and update the pin in `README.md` and the table above.
goose-http pins Goose too; keep the two on the same commit where possible, since a
program that imports both builds with one compiler.

## Test

`scripts/test.sh` runs everything, and stops at the first failure:

1. `goose check` of each root file under `test/` and `bench/`.
2. `scripts/test-unit.sh`: each `test/test_*.goose` through TinyCC, in the compiler's
   process. `test/test_compress.goose` checks the checksums against known values, the
   Huffman code builder (RFC 1951's canonical-code example, optimal lengths, and
   Fibonacci frequencies cut to 15 and 7 bits), the exact bytes of small streams at
   level 0 and of small fixed and dynamic Huffman streams at level 1, what the levels
   match differently (level 2 follows a hash chain past the newest entry; levels 5 and
   up take a literal for a longer match one byte on), flushes, matches at distance
   32,768, and that a stream's bytes don't depend on how its input was split across
   writes, at levels 0, 1, 2, 6, and 9. Each exact-byte stream at level 1 and up was
   checked by decompressing it with Python's `zlib`.
3. `goose build` of `test/encode.goose` into `build/encode`, a command that compresses
   a file at a level, one-shot or by a plan of writes and flushes.
4. `scripts/roundtrip.py`: `build/encode` on each input in gzip, zlib, and raw DEFLATE,
   at levels 0, 1, 2, 6, and 9, one-shot and streamed. Each output must decompress to its
   input through Python's `zlib`, and gzip output through `gzip -dc` too. At each
   flush, the output so far must end in `00 00 ff ff` and decompress to exactly the
   input written so far. The inputs are empty, one byte, text, JSON, random bytes,
   random inputs of 65,534 to 131,071 bytes around the stored blocks' 65,535-byte
   limit, long runs and repeated blocks, bytes that repeat at distances 32,767, 32,768,
   and 32,769, random bytes with runs copied from up to 40 KB back, and 16,000 bytes
   whose optimal Huffman code needs 17 bits. The plans write in 257-byte pieces, which
   end inside matches, and flush every 1,000 and every 32,769 bytes, so matches run
   across writes and flushes. One-shot at level 1 and up, inputs that repeat must
   compress below a limit set for each, a few percent above what level 1 reaches; text,
   JSON, and the copies within 40 KB have a tighter limit from level 6, a few percent
   above what level 6 reaches. The script then reads back the header of the 17-bit input's block: its
   literal/length code must reach exactly 15 bits and be complete. A fuzz run of 200
   random inputs, levels, and plans follows, with seed 0; `--levels`, `--fuzz N`, and
   `--seed S` change them.

```sh
GOOSE=../goose/build-macos/goose scripts/test.sh
```

It took about 22 s on the M1 Pro (2026-10-12). A program run through TinyCC compiles at
`-O1` without a C compiler, so the unit tests start fast; `encode` is built with
`goose build` because `roundtrip.py` runs it 2,499 times.

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
- `ref`, from `bench/ref.c`, which compresses a file with either library.
- `bench`, from `bench/bench.goose`, which compresses a file with the package.
- The [Silesia corpus](https://sun.aei.polsl.pl/~sdeor/index.php?page=silesia), 211 MB
  in 12 files, from `silesia.zip`, checked against its SHA-256 before it's unzipped.

`bench/run.sh` then prints a Markdown table: for each file and level, each library's
ratio and its median and best rate over `RUNS` runs. Each run compresses the whole file
in memory to one gzip stream; reading the file isn't timed.

```sh
GOOSE=../goose/build-macos/goose bench/build.sh
bench/run.sh                                # level 0, 10 runs, 7 Silesia files
LEVELS="1 6 9" RUNS=5 FILES=dickens bench/run.sh
```

The level is passed to each library as it is. Record results in `docs/results.md` with
what `AGENTS.md` asks for.

To compare a change, build `bench/bench.goose` before and after it into two binaries
with `goose build -o`, and run them in alternating rounds on the same files: the
libraries' rates varied about 4 percent between sessions, and two builds of the same
code about 1 percent within one.

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
  their names are global.
- `bench/run.sh` sets `LC_ALL=C`: under a locale with a decimal comma, such as
  `et_EE`, awk prints `10,2` and the table's numbers break.
- A rebuilt zlib-ng keeps options from its CMake cache: delete `build/bench/zlib-ng`
  after changing its options in `bench/build.sh`.
- A constant plus a `u8` is a `u8`: `t[768 + b[4]]` fails with "constant 768 does not
  fit u8". Write `768 + b[4] as i64`.
- `x as i64..end` parses as the variable-mode type `i64..`: write `(x as i64)..end`.
- Several results go only into new names: `let a, b = f();`, not `a, b = f();` into
  existing variables.
- Shrinking a `u8[>..]&` parameter, even after growing it in the same call, makes the
  function one that shrinks it, and a caller holding a slice of that array can no
  longer call it (spec §5.1). The package's functions only append to `out`.
- std's `ctz` and `popcount` are loops; `clz` compiles to an instruction
  ([findings](goose-findings.md#ctz-and-popcount-loop-over-the-bits)).
- Under zsh, `set -- $v` doesn't split `$v` into words; run such loops with `sh`.
