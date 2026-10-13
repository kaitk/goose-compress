#!/usr/bin/env python3
"""Checks the encoder's output against gzip, zstd, and Python's zlib and
compression.zstd.

Runs build/encode (test/encode.goose) on each input in each format and at each
level, one-shot and streamed, and fails on the first output that doesn't
decompress to its input. gzip output also goes through `gzip -dc`, and one-shot
zstd output through `zstd -dc`. At each
flush, the output so far must decompress to exactly the input written so far.
Inputs that repeat must come out smaller than a limit, one-shot at level 1 and
up. An input whose optimal Huffman code needs more than 15 bits must get a
dynamic code of exactly 15. Then a fuzz run of random inputs, levels, and
plans, seeded for repeatability.

    scripts/roundtrip.py [ENCODE] [--levels 0,1,2,6,9] [--zstd-levels 1,3]
                         [--fuzz N] [--seed S]
"""

import argparse
import heapq
import json
import os
import random
import subprocess
import sys
import tempfile
import zlib
from compression import zstd

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WBITS = {"gzip": 31, "zlib": 15, "raw": -15}
STORED_MAX = 65535
WSIZE = 32768
ZSTD_BLOCK_MAX = 1 << 17
# The first level held to the tighter size limits: the default level.
STRONG_LEVEL = 6


def text(n):
    words = ("the quick brown fox jumps over a lazy dog while goose "
             "compresses every byte of it").split()
    r = random.Random(1)
    out = []
    size = 0
    while size < n:
        w = r.choice(words)
        out.append(w)
        size += len(w) + 1
    return (" ".join(out).encode() + b"\n")[:n]


def json_doc():
    r = random.Random(2)
    rows = [{"id": i, "name": f"user{i}", "score": r.random(),
             "tags": ["a", "b", "c"][: r.randrange(4)]} for i in range(2000)]
    return json.dumps({"rows": rows}).encode()


def repeats_at(r, dist, n):
    """Random bytes that repeat at exactly `dist` back, n bytes in all."""
    out = bytearray(r.randbytes(dist))
    while len(out) < n:
        out.append(out[len(out) - dist])
    return bytes(out)


def copies(r, n):
    """Random bytes with runs copied from up to 40 KB back."""
    out = bytearray()
    while len(out) < n:
        if len(out) > 40_000 and r.random() < 0.05:
            at = len(out) - 1 - r.randrange(40_000)
            out += out[at:at + r.randrange(300)]
        out.append(r.randrange(256))
    return bytes(out[:n])


def deep_code(r, n=16_000, rare=12, bulk=32):
    """n bytes, one block of literals, whose optimal Huffman code needs 17
    bits. Bytes 0 to rare - 1 appear 1, 2, 3, 5, 8, ... times, which with the
    end-of-block symbol's 1 make a chain of Fibonacci frequencies, each code a
    bit longer than the next. The rest are `bulk` byte values, about equally
    frequent, and the chain hangs a few levels down their tree. No 4 bytes
    repeat, so nothing matches: a match needs its 4 bytes hashed to the same
    bucket, and two different 4 bytes that share their first 3 never do."""
    left = []
    a, b = 1, 2
    for i in range(rare):
        left.append(a)
        a, b = b, a + b
    rare_at = set(r.sample(range(3, n), sum(left)))
    out = bytearray()
    seen = set()
    for p in range(n):
        if p in rare_at:
            cands = sorted((s for s in range(rare) if left[s]),
                           key=lambda s: -left[s] * r.random())
        else:
            cands = r.sample(range(64, 64 + bulk), bulk)
        for c in cands:
            gram = bytes(out[-3:]) + bytes([c])
            if p < 3 or gram not in seen:
                break
        else:
            raise Failure("deep_code: no byte keeps every 4 bytes unique")
        if p >= 3:
            seen.add(gram)
        if p in rare_at:
            left[c] -= 1
        out.append(c)
    return bytes(out)


def inputs():
    """Yields each input's name, bytes, and the most its one-shot output may
    take at level 1 and up, as a share of the input: a few percent over what
    level 1 reaches. Where the stronger levels do better, a pair: the limit
    from level 1, then the one from STRONG_LEVEL, a few percent over what
    level 6 reaches."""
    r = random.Random(3)
    yield "empty", b"", None
    yield "one byte", b"a", None
    yield "text", text(100_000), (0.24, 0.19)
    yield "json", json_doc(), (0.235, 0.205)
    # Stored where a code would grow it.
    yield "random", r.randbytes(300_000), 1.001
    for n in (STORED_MAX - 1, STORED_MAX, STORED_MAX + 1, 2 * STORED_MAX,
              2 * STORED_MAX + 1):
        yield f"{n} bytes", r.randbytes(n), 1.001
    # Around zstd's largest block.
    for n in (ZSTD_BLOCK_MAX, ZSTD_BLOCK_MAX + 1):
        yield f"{n} bytes", r.randbytes(n), 1.001
    # Under 3 bits for each match of 258.
    yield "a run of one byte", b"a" * 300_000, 0.0013
    # The block, then a match of 258 at distance 1000 every 258 bytes.
    yield "a 1000-byte block, repeated", r.randbytes(1000) * 300, 0.0095
    # The first 32 KB stored, then matches.
    yield "repeats at 32767", repeats_at(r, WSIZE - 1, 4 * WSIZE), 0.27
    yield "repeats at 32768", repeats_at(r, WSIZE, 4 * WSIZE), 0.27
    # Out of reach: nothing to match, so stored.
    yield "repeats at 32769", repeats_at(r, WSIZE + 1, 4 * WSIZE), 1.001
    yield "copies within 40 KB", copies(r, 200_000), (0.39, 0.375)
    yield "a code past 15 bits", deep_code(r), 0.66


def plans(n):
    """Streaming plans for an input of n bytes, besides one-shot."""
    yield "1 write", ""
    yield "4 KB writes", ",".join(["4096"] * (n // 4096 + 1))
    # Writes that end inside matches and short of the encoder's lookahead.
    yield "257-byte writes", ",".join(["257"] * (n // 257 + 1))
    yield "flush first and last", "f," + str(n) + ",f"
    yield "flush every 1000 bytes", ",".join(["1000,f"] * (n // 1000 + 1))
    yield "flush every 32769 bytes", ",".join([f"{WSIZE + 1},f"] * (n // WSIZE + 1))
    yield "a flush after every byte, for 300", ",".join(["1,f"] * 300)
    yield "flushes back to back", "10,f,f,f,0,f"


class Failure(Exception):
    pass


def run(encode, fmt, level, data, plan, tmp):
    src = os.path.join(tmp, "in")
    dst = os.path.join(tmp, "out")
    with open(src, "wb") as f:
        f.write(data)
    cmd = [encode, fmt, str(level), src, dst] + ([plan] if plan is not None else [])
    p = subprocess.run(cmd, capture_output=True, text=True)
    if p.returncode != 0:
        raise Failure(f"encode exited {p.returncode}: {p.stderr.strip()}")
    with open(dst, "rb") as f:
        out = f.read()
    flushes = [tuple(map(int, line.split())) for line in p.stdout.splitlines()]
    return out, dst, flushes


def level_limit(limit, level):
    """The limit inputs() gives for one level, or None."""
    if isinstance(limit, tuple):
        return limit[1] if level >= STRONG_LEVEL else limit[0]
    return limit


def check(encode, fmt, level, data, plan, tmp, limit=None):
    if fmt == "zstd":
        check_zstd(encode, level, data, plan, tmp)
        return
    out, path, flushes = run(encode, fmt, level, data, plan, tmp)
    got = zlib.decompress(out, WBITS[fmt])
    if got != data:
        raise Failure(f"zlib gave {len(got)} bytes, not the {len(data)} in")
    if fmt == "gzip":
        p = subprocess.run(["gzip", "-dc", path], capture_output=True)
        if p.returncode != 0 or p.stdout != data:
            raise Failure(f"gzip -dc: exit {p.returncode}, {len(p.stdout)} bytes")
    for consumed, produced in flushes:
        d = zlib.decompressobj(WBITS[fmt])
        part = d.decompress(out[:produced])
        if part != data[:consumed]:
            raise Failure(f"flush at input {consumed}, output {produced}: "
                          f"{len(part)} bytes come out")
        if out[produced - 4:produced] != b"\x00\x00\xff\xff":
            raise Failure(f"flush at output {produced} doesn't end in 00 00 ff ff")
    # The wrapper takes at most 18 bytes.
    if limit is not None and level > 0 and len(out) > limit * len(data) + 18:
        raise Failure(f"{len(out)} bytes out, over {limit} of the {len(data)} in")


def check_zstd(encode, level, data, plan, tmp):
    out, path, flushes = run(encode, "zstd", level, data, plan, tmp)
    # Decompressing checks the content checksum too.
    try:
        got = zstd.decompress(out)
    except zstd.ZstdError as e:
        raise Failure(f"compression.zstd: {e}")
    if got != data:
        raise Failure(f"compression.zstd gave {len(got)} bytes, not the {len(data)} in")
    if plan is None:
        p = subprocess.run(["zstd", "-dcq", path], capture_output=True)
        if p.returncode != 0 or p.stdout != data:
            raise Failure(f"zstd -dc: exit {p.returncode}, {len(p.stdout)} bytes")
    for consumed, produced in flushes:
        part = zstd.ZstdDecompressor().decompress(out[:produced])
        if part != data[:consumed]:
            raise Failure(f"flush at input {consumed}, output {produced}: "
                          f"{len(part)} bytes come out")
    # The header and checksum take 10 bytes, and each block's header 3.
    blocks = len(data) // ZSTD_BLOCK_MAX + len(flushes) + 1
    if len(out) > len(data) + 10 + 3 * blocks:
        raise Failure(f"{len(out)} bytes out for {len(data)} in")


CL_ORDER = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]


def first_block_lengths(raw):
    """The literal/length and distance code lengths of a raw DEFLATE stream's
    first block, or None if the block isn't dynamic (RFC 1951 §3.2.7)."""
    pos = 0

    def bits(n):
        nonlocal pos
        v = 0
        for i in range(n):
            v |= (raw[pos >> 3] >> (pos & 7) & 1) << i
            pos += 1
        return v

    bits(1)
    if bits(2) != 2:
        return None
    hlit, hdist, hclen = bits(5) + 257, bits(5) + 1, bits(4) + 4
    cl = [0] * 19
    for i in range(hclen):
        cl[CL_ORDER[i]] = bits(3)
    # The canonical code-length code, as (length, code) to symbol; Huffman
    # codes are packed from their most significant bit.
    codes = {}
    code = 0
    for n in range(1, 8):
        for s in range(19):
            if cl[s] == n:
                codes[(n, code)] = s
                code += 1
        code <<= 1
    lens = []
    while len(lens) < hlit + hdist:
        n = code = 0
        while (n, code) not in codes:
            if n == 7:
                raise Failure("a code-length code that decodes nothing")
            code = code << 1 | bits(1)
            n += 1
        s = codes[(n, code)]
        if s < 16:
            lens.append(s)
        elif s == 16:
            lens += [lens[-1]] * (3 + bits(2))
        elif s == 17:
            lens += [0] * (3 + bits(3))
        else:
            lens += [0] * (11 + bits(7))
    return lens[:hlit], lens[hlit:hlit + hdist]


def optimal_depth(counts):
    """The longest code in an optimal Huffman code for counts, unlimited."""
    h = [(c, 0) for c in counts if c]
    heapq.heapify(h)
    while len(h) > 1:
        a, da = heapq.heappop(h)
        b, db = heapq.heappop(h)
        heapq.heappush(h, (a + b, max(da, db) + 1))
    return h[0][1]


def check_limit(encode, level, tmp):
    """The deep-code input, one-shot in raw DEFLATE, must be one dynamic block
    whose literal/length code reaches exactly 15 bits and stays complete."""
    data = deep_code(random.Random(3))
    counts = [data.count(bytes([b])) for b in range(256)] + [1]
    if optimal_depth(counts) <= 15:
        raise Failure("the input's optimal code fits in 15 bits")
    out, _, _ = run(encode, "raw", level, data, None, tmp)
    lens = first_block_lengths(out)
    if lens is None:
        raise Failure("the first block isn't dynamic")
    for name, code in zip(("literal/length", "distance"), lens):
        if sum(1 << (15 - n) for n in code if n) != 1 << 15:
            raise Failure(f"the {name} code isn't complete")
    if max(lens[0]) != 15:
        raise Failure(f"the longest literal/length code is {max(lens[0])} bits")


def fuzz_plan(r, n):
    steps = []
    left = n
    while left > 0 and r.random() < 0.9:
        k = r.choice((0, 1, r.randrange(100), r.randrange(STORED_MAX * 2)))
        steps.append(str(k))
        left -= k
        if r.random() < 0.5:
            steps.append("f")
    return ",".join(steps)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("encode", nargs="?", default=os.path.join(ROOT, "build", "encode"))
    ap.add_argument("--levels", default="0,1,2,6,9")
    ap.add_argument("--zstd-levels", default="1,3")
    ap.add_argument("--fuzz", type=int, default=200)
    ap.add_argument("--seed", type=int, default=0)
    args = ap.parse_args()
    levels = [int(x) for x in args.levels.split(",")]
    zlevels = [int(x) for x in args.zstd_levels.split(",")]
    runs = [(fmt, level) for level in levels for fmt in WBITS]
    runs += [("zstd", level) for level in zlevels]
    cases = 0
    with tempfile.TemporaryDirectory() as tmp:
        for name, data, limit in inputs():
            for fmt, level in runs:
                for pname, plan in [("one-shot", None)] + list(plans(len(data))):
                    try:
                        check(args.encode, fmt, level, data, plan, tmp,
                              level_limit(limit, level) if plan is None else None)
                    except Failure as e:
                        sys.exit(f"FAIL {name}, {fmt}, level {level}, {pname}: {e}")
                    cases += 1
        for level in levels:
            if level > 0:
                try:
                    check_limit(args.encode, level, tmp)
                except Failure as e:
                    sys.exit(f"FAIL the 15-bit limit, level {level}: {e}")
                cases += 1
        r = random.Random(args.seed)
        for i in range(args.fuzz):
            n = r.choice((0, 1, r.randrange(1000), r.randrange(300_000)))
            data = r.choice((r.randbytes, text, lambda n: copies(r, n)))(n)
            fmt, level = r.choice(runs)
            plan = fuzz_plan(r, n)
            try:
                check(args.encode, fmt, level, data, plan, tmp)
            except Failure as e:
                sys.exit(f"FAIL fuzz {i} (seed {args.seed}), {fmt}, level {level}, "
                         f"{n} bytes, plan {plan!r}: {e}")
            cases += 1
    print(f"roundtrip: {cases} cases ok")


if __name__ == "__main__":
    main()
