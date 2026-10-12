#!/usr/bin/env python3
"""Checks the encoder's output against gzip and Python's zlib.

Runs build/encode (test/encode.goose) on each input in each format and at each
level, one-shot and streamed, and fails on the first output that doesn't
decompress to its input. gzip output also goes through `gzip -dc`. At each
flush, the output so far must decompress to exactly the input written so far.
Inputs that repeat must come out smaller than a limit, one-shot at level 1 and
up. Then a fuzz run of random inputs, levels, and plans, seeded for
repeatability.

    scripts/roundtrip.py [ENCODE] [--levels 0,1,6,9] [--fuzz N] [--seed S]
"""

import argparse
import json
import os
import random
import subprocess
import sys
import tempfile
import zlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WBITS = {"gzip": 31, "zlib": 15, "raw": -15}
STORED_MAX = 65535
WSIZE = 32768


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


def inputs():
    """Yields each input's name, bytes, and the most its one-shot output may
    take at level 1 and up, as a share of the input."""
    r = random.Random(3)
    yield "empty", b"", None
    yield "one byte", b"a", None
    yield "text", text(100_000), 0.4
    yield "json", json_doc(), 0.4
    # Stored where the fixed code would grow it.
    yield "random", r.randbytes(300_000), 1.001
    for n in (STORED_MAX - 1, STORED_MAX, STORED_MAX + 1, 2 * STORED_MAX,
              2 * STORED_MAX + 1):
        yield f"{n} bytes", r.randbytes(n), 1.001
    # 13 bits for each match of 258 in the fixed code.
    yield "a run of one byte", b"a" * 300_000, 0.01
    # The block, then 21 bits for each match of 258 at distance 1000.
    yield "a 1000-byte block, repeated", r.randbytes(1000) * 300, 0.02
    yield "repeats at 32767", repeats_at(r, WSIZE - 1, 4 * WSIZE), 0.35
    yield "repeats at 32768", repeats_at(r, WSIZE, 4 * WSIZE), 0.35
    # Out of reach: nothing to match, so stored.
    yield "repeats at 32769", repeats_at(r, WSIZE + 1, 4 * WSIZE), 1.001
    yield "copies within 40 KB", copies(r, 200_000), 0.5


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


def check(encode, fmt, level, data, plan, tmp, limit=None):
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
    ap.add_argument("--levels", default="0,1,6,9")
    ap.add_argument("--fuzz", type=int, default=200)
    ap.add_argument("--seed", type=int, default=0)
    args = ap.parse_args()
    levels = [int(x) for x in args.levels.split(",")]
    cases = 0
    with tempfile.TemporaryDirectory() as tmp:
        for name, data, limit in inputs():
            for level in levels:
                for fmt in WBITS:
                    for pname, plan in [("one-shot", None)] + list(plans(len(data))):
                        try:
                            check(args.encode, fmt, level, data, plan, tmp,
                                  limit if plan is None else None)
                        except Failure as e:
                            sys.exit(f"FAIL {name}, {fmt}, level {level}, {pname}: {e}")
                        cases += 1
        r = random.Random(args.seed)
        for i in range(args.fuzz):
            n = r.choice((0, 1, r.randrange(1000), r.randrange(300_000)))
            data = r.choice((r.randbytes, text, lambda n: copies(r, n)))(n)
            fmt = r.choice(list(WBITS))
            level = r.choice(levels)
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
