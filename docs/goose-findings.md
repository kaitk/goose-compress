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
x86-64), at 7-32 GB/s with the copy included (`docs/results.md`). Goose has no such
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
