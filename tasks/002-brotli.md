# 002: Brotli

Status: todo (a possible follow-up, not started until a measurement asks for it;
recorded 2026-10-12)

Brotli encoding on the fly is out of scope (`docs/architecture/README.md`). This task
records why, and what would bring it back.

## Why it's out

- Brotli's advantage over gzip comes mostly at qualities 9 to 11, which take tens of
  milliseconds or more per response. That suits files compressed ahead of time, and
  goose-http's `open_precompressed` already serves `.br` copies.
- At its fast qualities (0 to 4), brotli is about as fast as gzip at level 6 and a
  little smaller. That still needs a second encoder, with its own block format and
  context modeling: a few thousand lines even without the built-in dictionary, none of
  which helps zstd.
- zstd covers the same ground: faster or smaller than gzip, cheaper to encode quickly,
  and planned for this package after gzip.
- Nothing measured needs it. HttpArena accepts gzip or br, and gzip is required anyway.

## What would bring it back

A browser that takes `br` but not `zstd` gets gzip on dynamic responses, where nginx
with its brotli module would send `br`: a few percent larger on small JSON, more on
large HTML or JavaScript. Safari's zstd support wasn't checked on 2026-10-12. Start
this task if a measurement shows the gap matters to a deployment: Safari still lacks
zstd, and the deployment serves large dynamic text to browsers.

## Acceptance criteria

- [ ] Safari's current `zstd` support checked, and the size gap measured on the
      deployment's own responses
- [ ] A decision to build or keep out, recorded in `docs/architecture/README.md`
