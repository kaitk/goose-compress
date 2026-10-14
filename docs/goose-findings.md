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

On `46356c2` the program still takes 6.0 s on the Ryzen under Windows, 60 µs a `make`.

`var e: Encoder;` with only a type isn't a way around the literal: the compiler
rejects a read of `e` as "may be used before it is assigned".

Workaround: build an encoder once and `reset` it for each stream, which zeroes its
fields in place (task 003). `compress` does so with an encoder it keeps.

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

## Bounds-check elimination doesn't combine facts about a difference

Found on `a6249a4`, task 005; narrowed on `46356c2`. Status: open

The analysis (spec §10.5) drops the check on `s[p - d]` after a guard that proves
`0 <= p - d < s.len`, but keeps the check on a slice taken at a difference,
`s[p - d..p - d + 4]`, after a guard that proves it in range. It also keeps the check on
a table indexed by a shift that leaves fewer bits than the table's size, `T[x >> 58]`
for 64 entries. With every call inlined into `main`, the checks marked `kept` stay:

    fn f(s: const u8[:], p: i64, d: i64) -> u8 {
        guard p + 4 <= s.len && d >= 1 && d <= p else { return 0; }
        let w = s[p - d..p - d + 4];                  // kept
        return w[0] ^ w[3];                           // both dropped
    }
    let T: i64[64] = [0; 64];
    fn e(x: u64) -> i64 { return T[x >> 58]; }        // kept
    fn e2(x: u64) -> i64 { return T[(x >> 58) % 64]; } // dropped

Workaround: index tables with `% n`, as the zstd hash tables do. `load32` and `load64`
slice the window at a position minus a distance, so those reads keep their checks.
Written `p <= s.len - 4`
([below](#bounds-check-elimination-ignores-a-constant-added-to-the-index)), the guard
still leaves the slice's check.

## Bounds-check elimination ignores a constant added to the index

Found on `46356c2`, task 005. Status: open

A guard that bounds an index with a constant added to it, `p + 4 <= s.len`, drops no
check, not even on `s[p]`; `p + 3 < s.len` and `s.len >= p + 4` drop none either. The
same bound with the constant on the length's side, `p <= s.len - 4`, drops both.
Goose's arithmetic is checked, so the forms are equivalent. With every call inlined
into `main`:

    fn f(s: const u8[:], p: i64) -> i64 {
        guard p >= 0 && p + 4 <= s.len else { return 0; }
        return s[p] + s[p + 3];                           // both kept
    }

    fn g(s: const u8[:], p: i64) -> i64 {
        guard p >= 0 && p <= s.len - 4 else { return 0; }
        return s[p] + s[p + 3];                           // both dropped
    }

Workaround: write the bound on the length's side. In zstd's matchers, guards in that
form drop every window read's check, but marking `load32` and `load64` `inline`, which
puts the reads where a guard can reach them, costs 0.5 to 12 percent on its own
([results](results-history.md#task-005-zstds-window-reads-without-checks-not-kept)),
so the matchers keep the checks.
