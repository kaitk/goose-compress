# 006: Build from Goose releases

Status: in-progress

Goose publishes official releases for Windows, Linux, and macOS. Asked for 2026-10-15:
build from the pinned release by default, and pin a Goose commit only when a fix this
package needs isn't released yet. goose-http made the same change first; its task 034
tracks all three repositories.

Done (2026-10-15): `scripts/goose.sh`, copied from goose-http, names the release
(`v2026.1`, Goose `ac759c3`) and its archives' SHA-256 sums. It downloads the archive
into `build/`, or uses `GOOSE` or `GOOSE_COMMIT` when set
([setup](../docs/development.md#set-up-the-goose-compiler)). `scripts/test.sh`,
`scripts/test-unit.sh`, and `bench/build.sh` source it; `bench/run.sh` runs only built
binaries and doesn't. `bench/build.sh` ends by naming the compiler, for the results'
record. The package has no `.build` sidecar, so the release's `stdlib/` under `build/`
needs no `exclude`.

The pin moves from `46356c2` to `v2026.1`, which adds only the release packaging and
where the compiler looks for its packages and the macOS SDK. Results at `46356c2` stand,
and no finding's fix arrives with it.

## Acceptance criteria

- [x] `scripts/test.sh` passes with the release by default: with `GOOSE` unset on macOS
      arm64 (M1 Pro), 3,878 round-trip cases (2026-10-15).
- [x] `GOOSE_COMMIT=46356c26a94f0e1723b3b61ad56b93a7da70878f scripts/test.sh` builds that
      commit into `build/` and passes, and `GOOSE` naming a compiler passes
      `scripts/test-unit.sh` (2026-10-15, macOS arm64).
- [x] `bench/build.sh` builds `bench` with the release (2026-10-15, macOS arm64).
- [ ] `scripts/test.sh` passes with the release in Git Bash on Windows and on Linux.
