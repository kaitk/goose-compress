# 002: Brotli

Status: todo (a possible follow-up, not started until a measurement asks for it;
recorded 2026-10-12)

Brotli encoding on the fly is out of scope. This task records what would justify
adding it; the decision is in [decisions](../docs/decisions.md).

## Why it's out

HTTP servers can serve Brotli files compressed ahead of time; goose-http's
`open_precompressed` already serves `.br` copies. Dynamic responses can use gzip
or the implemented zstd encoder. Brotli would add a separate block format and
context model, and no deployment measurement here establishes a need for it.

## What would bring it back

Measure the response-size gap for a deployment whose clients accept `br` but cannot
use `zstd`, especially for large dynamic text. Check browser support at the time of
the measurement; this task does not maintain a browser compatibility table.

## Acceptance criteria

- [ ] Safari's current `zstd` support checked, and the size gap measured on the
      deployment's own responses
- [ ] A decision to build or keep out, recorded in `docs/decisions.md`
