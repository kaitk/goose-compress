# 007: Move goose-compress's tests to Goose's test convention

Status: done (2026-10-15)

Tests follow Goose's own convention in goose-compress, goose-http, and goose-rest
([decisions](../docs/decisions.md), 2026-10-15): a top-level `test/` by area, each test
a small program checked by its printed output against `test/expected/<name>.out`,
`// error:` fixtures for code that must not compile, and a runner that batches the
builds with `goose --multi-test` and runs the tests in parallel. goose-compress's tests
today are `test/test_compress.goose`, which `scripts/test-unit.sh` runs through TinyCC,
and `test/encode.goose`, which `scripts/roundtrip.py` drives against the reference
decoders, and the first failed `assert` ends a program.

As in Goose's own repository, the runner is this repository's own: `test/run_tests.py`,
in Python, modeled on Goose's, with no package or script shared between repositories
(2026-10-15).

## Acceptance criteria

- [x] `test/run_tests.py`, modeled on Goose's: finds `test/**/*.goose`, compiles them
      in batches with `goose --multi-test`, runs each as a process of its own and in
      parallel, at `-O0` and `-O2` where they differ, compares output with
      `test/expected/`, checks `// error:` fixtures fail with their message, and
      reports every failure with a count per area; one way to run a single test or area
      (2026-10-15: it finds the tests one level below `test/`, as Goose's does, so
      `test/encode.goose` and the helpers in `test/check.goose` aren't taken for tests;
      it builds native C at both levels, about 4 s on the M1 Pro; no `// error:`
      fixture exists yet)
- [x] The unit tests split into small programs by area (`test/deflate/`, `test/zstd/`,
      `test/checksums/`, `test/stream/`, ...), each printing what it checks, with its
      golden file; the shared helpers in one module (2026-10-15: 22 programs from
      `test/test_compress.goose`'s 15 test functions, every check kept)
- [x] The round trip against zlib, libdeflate, and libzstd's decoders stays a step of
      its own, as it needs those decoders, and `test/encode.goose` stays its driver
- [x] `scripts/test.sh` calls the runner in place of `scripts/test-unit.sh`'s list,
      and keeps its typecheck of each root and the round trip (2026-10-15:
      `scripts/test-unit.sh` is deleted)
- [x] `docs/development.md` says how to run the tests, one test, and one area, and how
      to bless a changed golden file
