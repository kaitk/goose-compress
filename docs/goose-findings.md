# Goose findings

Gaps, bugs, and surprises in the pinned Goose compiler and stdlib, found while building
this package. Each entry has a minimal program that shows it, the Goose commit it was
found on, the workaround used here, and whether it has been reported upstream.

The entries come in two parts: [bugs](#bugs), where Goose does something wrong or other
than its spec says, then [feature requests](#feature-requests), for what it lacks. Each
part runs from the least work a fix is expected to take to the most, so the cheap fixes
come first. The order is an estimate from reading the compiler. Place a new entry where
its expected work puts it, and delete an entry once the pin has its fix: git keeps it.

An entry stays only while its workaround costs this package something measured: speed,
an API constraint, or tooling to maintain (2026-10-14). A gap with a free workaround, or
whose fix measured no gain here, isn't asked for. A bounds check the analysis fails to
drop is a feature request, not a bug: spec §10.5 requires only that the analysis be
sound.

Format:

```markdown
### Short title

Found on `<goose commit>`, task NNN. Status: open | reported

What happens and what was expected.

    minimal program

Workaround: ...
```

## Bugs

### The unsafe-fast build the spec names doesn't exist

Found on `a6249a4`, task 005. Status: open; unchanged on `46356c2`

Spec §9.3 says index checks "can be disabled wholesale in a designated unsafe-fast
build", but `goose build` has no such mode: `GS_IDX` and the slice checks are in the
generated C, not behind a define. Measuring what the checks cost takes editing that C.
In `bench`, removing all of them made level 1 1 to 14 percent faster on Silesia and
levels 6 and 9 up to 14 percent, on `x-ray`
([results](results-history.md#step-3-the-hand-fixed-c)); in zstd's two matchers, 1.9
to 6.1 percent
([results](results-history.md#task-005-zstds-window-reads-without-checks-not-kept)).
Expected: a define or flag that drops them, as `GS_DEBUG` adds overflow checks.

Workaround: `goose build -v --dry-run` prints the C file and the compile command; a
script removes the checks from a copy of the file, which that command compiles.

## Feature requests

### A struct literal copies each nested fixed array whole

Found on `5c83a5a`, task 001. Status: open; unchanged on `46356c2`. Recorded in
goose-http's findings ("A struct literal is built in whole temporaries and copied",
found on `e7792d7`)

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
1.7 s. On `46356c2` it takes 6.0 s on a Ryzen 7 5800X3D under Windows, 60 µs a `make`:
the Windows C runtime's `memcpy` is slow on Zen 3 when source and destination sit at
nearly the same offset within a 4 KB page, as these temporaries do (task 003).

Building a `compress::Encoder`, 460,406 bytes, takes about 145 µs on that Ryzen, against
7.3 µs for `compress` of 100 bytes with an encoder reset in place (README). So the API
asks callers to keep encoders in slots and reset them, rather than build one a stream.

`var e: Encoder;` with only a type isn't a way around the literal: the compiler
rejects a read of `e` as "may be used before it is assigned".

Workaround: build an encoder once and `reset` it for each stream, which zeroes its
fields in place (task 003). `compress` does so with an encoder it keeps.

### Goose has no carryless multiply

Found on `5c83a5a`, task 001. Status: open; unchanged on `46356c2`

CRC-32 runs at 2.7 to 2.9 GB/s on a Ryzen 7 5800X3D, slice-by-16 table lookups.
libdeflate and zlib-ng fold the CRC with a carryless multiply (`PCLMULQDQ` on x86-64,
`PMULL` on arm64), at 13 to 20 GB/s with the copy included
([results](results.md#levels-0-1-6-and-9-at-v011)). Goose has no such operation, and
no way to ask for one: `simd fn` builds wider versions on x86-64 only (spec §7.12), and
C compilers don't turn a CRC loop into carryless multiplies. Expected: a carryless
multiply, or a CRC-32 in the stdlib that uses one where the CPU has it.

    let T = table();   // the 256 reflected CRC-32 entries
    fn crc32(crc: u32, data: const u8[:]) -> u32 {
        var c = ~crc;
        for b in data { c = T[(c ^ b) & 0xFF] ^ (c >> 8); }
        return ~c;
    }

What it costs here: gzip level 0 is 4.9 to 7.0 times slower than both libraries, and
the CRC is about 0.36 ms of each MB at level 1, 5 to 14 percent of its time on Silesia
(from the same run's level 1 rates, 139 to 386 MB/s): as much as every bounds check.

Workaround: slice-by-16, 16 table lookups for 16 bytes from a 16 KB table (task 001
step 4). On an M1 Pro, level 0 on `dickens` and `x-ray` went from 346 MB/s to 2.8-2.9
GB/s, and slice-by-8 reached 1.8 GB/s (`build/bench/bench 0 FILE 5`, median of 5 runs,
best of 3 rounds, 2026-10-12). Then, from 64 bytes up on x86-64 with PCLMULQDQ and
arm64 with PMULL, `shim/crc32.c` folds the CRC in C, built through `compress.build`,
with the tables kept for other CPUs and `GOOSE_COMPRESS_PORTABLE=1`
([decisions](decisions.md), [results](results-history.md#crc-32-on-pmull),
2026-10-23). The shim stays until Goose has a carryless multiply.
