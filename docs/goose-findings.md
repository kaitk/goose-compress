# Goose findings

Gaps, bugs, and surprises in the pinned Goose compiler and stdlib, found while building
this package. Each entry has a minimal program that shows it, the Goose commit it was
found on, the workaround used here, and whether it has been reported upstream.

Format:

```markdown
## Short title

Found on `<goose commit>`, task NNN. Status: open | reported | fixed in `<commit>`

What happens and what was expected.

    minimal program

Workaround: ...
```

## Goose has no carryless multiply

Found on `5c83a5a`, task 001. Status: open

CRC-32 runs at about 345 MB/s on an M1 Pro, one table lookup a byte. libdeflate and
zlib-ng fold the CRC with a carryless multiply (`PMULL` on arm64, `PCLMULQDQ` on
x86-64), at 7-32 GB/s with the copy included (`docs/results-history.md`). Goose has no such
operation, and no way to ask for one: `simd fn` builds wider versions on x86-64 only
(spec §7.12), and C compilers don't turn a CRC loop into carryless multiplies. Expected:
a carryless multiply, or a CRC-32 in the stdlib that uses one where the CPU has it.

    let T = table();   // the 256 reflected CRC-32 entries
    fn crc32(crc: u32, data: const u8[:]) -> u32 {
        var c = ~crc;
        for b in data { c = T[(c ^ b) & 0xFF] ^ (c >> 8); }
        return ~c;
    }

Workaround: slice-by-16, 16 table lookups for 16 bytes from a 16 KB table (task 001
step 4). On the same M1 Pro, level 0 on `dickens` and `x-ray` went from 346 MB/s to
2.8-2.9 GB/s, and slice-by-8 reached 1.8 GB/s (`build/bench/bench 0 FILE 5`, median
of 5 runs, best of 3 rounds, 2026-10-12). That is still 2.5 times slower than
zlib-ng's 7 GB/s and 7 times slower than libdeflate's 21 GB/s.

## A struct literal copies each nested fixed array whole

Found on `5c83a5a`, task 001. Status: open

A literal of a fixed-size struct is built through temporaries: each array field is
zeroed in a temporary of its own and copied into a temporary of the struct holding
it, which is copied into its parent's temporary, and so on to the variable. A struct
of 196 KB nested one level deep is zeroed once and copied three times, with each
element zeroed in a loop of its own in the C. Expected: the literal built in its
destination, as §4.3 guarantees for values that aren't fixed-size, so `S { .. }`
costs one `memset`. `default<S>()` and a limited array field (`u8[..65536]`) don't
help: `default<S>()` adds a copy, and the limited array is still copied whole.

    import std;
    import os;

    struct Inner {
        n: i64,
        head: u32[32768],
        win: u8[65536],
    }

    struct Outer {
        level: i64,
        z: Inner,
    }

    fn make(level: i64) -> Outer {
        return Outer { level: level, .. };
    }

    fn main() {
        var total = 0;
        for i in 100000 {
            var o = make(args().len);
            o.z.win[i & 65535] = 1;
            o.z.head[i & 32767] = 1;
            total += o.z.win[3] + o.z.head[5];
        }
        print(total);
    }

On an M1 Pro this takes 1.2 s, 12 µs a `make`; with `win: u8[..65536]` and a `push`,
1.7 s. A `compress::Encoder` held 262,484 bytes before task 001 step 4's hash chains
(328,050 after), and building one was about three
quarters of the 20 µs `compress` took for 100 bytes at level 1 (the rest is coding
the block), by `sample` (task 001 step 4).

On Windows the copies cost about 5 times as much (`c38dc0f`, task 003). `compress` of
100 bytes at level 1, with a 2^16-entry hash table, takes 157 µs on a Ryzen 7 5800X3D
under Windows, and 30 µs on the same CPU under Linux, most of it `memset` and `memcpy`
there. Each array's temporary
lives in a data-stack region of its own, so a copy's source and destination are at
nearly the same offset within a 4 KB page, and the Windows C runtime's `memcpy` is
slow on Zen 3 exactly then: 128 KB copies in 31.4 µs when the destination is 16 bytes
past the source modulo 4,096, and in 1.9 to 2.1 µs at 32 bytes or more. glibc's
`memcpy` takes 1.0 µs either way. The 2^15-entry table, 128 KB less to zero and copy,
takes 112 µs on Windows.

`var e: Encoder;` with only a type isn't a way around the literal: the compiler
rejects a read of `e` as "may be used before it is assigned".

Workaround: build an encoder once and `reset` it for each stream, which zeroes its
fields in place (task 003). `compress` does so with an encoder it keeps.

## `clz`, `ctz`, and `popcount` loop over the bits

Found on `5c83a5a`, task 001; `clz` on x86-64 on `c38dc0f`, task 003. Status: open

std's `clz`, `ctz`, and `popcount` are Goose loops, one iteration a bit (one a set
bit for `popcount`). Apple clang 21 turns `clz`'s loop into the `clz` instruction,
but not the other two: `ctz` and `popcount` run as loops. Expected: one instruction
each, as C's `__builtin_clzll`, `__builtin_ctzll`, and `__builtin_popcountll` give.
The program below takes 0.9 s on an M1 Pro, 9 ns a call at 21 trailing zeros, and its
`main` has no `rbit` or `clz`. With `popcount` in place of `ctz` it takes 0.63 s; with
`clz`, 0.02 s.

On x86-64, clang 22.1.3 leaves `clz`'s loop a loop too, under `goose build` on Windows
(`clang-cl /O2`) and with `--cc clang` on Linux: with `clz` in place of `ctz`, the
program takes 0.58 s on a Ryzen 7 5800X3D. The baseline x86-64 target has no `lzcnt`,
but `bsr` would do. `len_code` and `dist_code` used `clz` on each match, twice a
match, and level 1 ran at half the M1 Pro's rate until tables replaced them (task 003).

    import std;
    import os;

    fn main() {
        var x = (args().len as! u64) << 40;
        var n = 0;
        for i in 100000000 {
            n += ctz(x);
            x += 1 << 20;
        }
        print(n);
    }

An 8-byte match compare that found the first differing byte with `ctz` made level 1
30-40 percent slower than comparing a byte at a time (task 001 step 4).

Workaround: no `clz`, `ctz`, or `popcount` in a hot path. A de Bruijn multiply and a
64-entry table was still 3-12 percent slower at level 1 than shifting the xor of the
two words a byte at a time. The length and distance codes and a distance's logarithm
come from tables built once.

## `simd fn` doesn't turn std bit loops into instructions

Found on `a6249a4`, task 005. Status: open

A `simd fn`'s AVX2 version is compiled with `target("avx2,bmi,bmi2,lzcnt,popcnt")`
(`GS_SIMD_TARGET1` in the runtime), so `tzcnt` and `popcnt` are available to clang
there. std's `ctz` and `popcount` still compile to loops in it. `ctz`'s loop, shift
right until the low bit is set, isn't an idiom LLVM recognizes, even in hand-written C.
`popcount`'s loop, clear the lowest set bit and count, is one, but LLVM rewrites it
only when it isn't nested in another loop: as a function of its own it becomes
`popcntq`, and inlined into a loop, the only place a match compare calls it, it stays
a loop. Expected: one instruction each, at least in a `simd fn`'s versions. The
program below, with `ctz` or with `popcount((x & (0 - x)) - 1)` in its place, takes
0.75 to 1.0 s on a Ryzen 7 5800X3D under Windows, as the baseline does, and its
binary has no `tzcnt` or `popcnt`.

    import std;
    import os;

    simd fn count(x0: u64) -> i64 {
        var x = x0;
        var n = 0;
        for i in 100000000 {
            n += ctz(x);
            x += 1 << 20;
        }
        return n;
    }

    fn main() {
        print(count((args().len as! u64) << 40));
    }

Workaround: none; `ctz` stays out of hot paths. A `simd` matcher whose `match_len`
compares 8 bytes and calls `ctz` was 4 to 26 percent slower than `6b57c40` at levels 1,
6, and 9 on six Silesia files of seven
([results](results-history.md#step-2-simd-fn-gives-stds-bit-scans-no-instruction)).

## Bounds checks can't be turned off to measure them

Found on `a6249a4`, task 005. Status: open

`goose build` has no unchecked mode, so measuring what the bounds checks cost takes
editing the C it writes: `GS_IDX` and the slice checks are in the generated file, not
behind a define. In `bench`, removing all of them made level 1 1 to 14 percent faster
on Silesia and levels 6 and 9 up to 14 percent, on `x-ray`
([results](results-history.md#step-3-the-hand-fixed-c)). Expected: a define or flag
that drops them, for measurement, as `GS_DEBUG` adds overflow checks.

Workaround: `goose build -v --dry-run` prints the C file and the compile command; edit
a copy of the file and compile it with that command.
