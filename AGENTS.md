# Agent rules

## Project context

- What this is, its API, and its pin: `README.md`
- Architecture decisions: `docs/architecture/README.md`
- Toolchain, local setup, tests, and benchmarks: `docs/development.md`
- Goose compiler and stdlib gaps found here: `docs/goose-findings.md`
- Benchmark results: `docs/results.md` (each machine's latest run) and
  `docs/results-history.md` (earlier runs and each change's measurements)
- Task tracking: `tasks/` (see `tasks/README.md`)
- Substantial doc drafts and requested prose reviews:
  `.claude/skills/google-style/SKILL.md`; other writing follows "Writing" below
- The formats: RFC 1951 (DEFLATE), RFC 1950 (zlib), and RFC 1952 (gzip).
- The language: the pinned Goose checkout's `docs/tutorial.md`, `docs/goose_spec.md`,
  and `docs/stdlib.md`. Read the tutorial before writing Goose; check the spec before
  assuming a feature exists.

Follow the recorded decisions; if a change contradicts one, update the doc in the same
change or ask first. Record setup facts and environment traps you find (paths, shell
quirks, locales, encodings) in `docs/development.md`, not in agent memory, so the next
agent finds them. Docs and commits name no people: date a decision or a request
(`(2026-10-12)`), and describe the setup without anyone's machine, checkouts, or home
directory. What only one machine needs, such as where its Goose checkout is, goes in
`CLAUDE.local.md`, which git ignores. Benchmark results still name their machine.

## Writing

- Lead with the decision, behavior, or action, then explain why. Name the responsible
  component and use concrete facts. Cut filler and repeated summaries.
- Preserve technical meaning when editing: actors, negations, conditions, numbers,
  versions, commands, paths, and identifiers. Keep decided/proposed/open,
  implemented/planned, and must/should/can distinct. Flag contradictions instead of
  silently resolving them while copyediting.
- Record a decision with its reason and the trade-off that matters. Keep each fact in
  one place and link to it elsewhere. Use absolute dates for dated events.
- Match the document's format. Tasks follow `tasks/README.md`, with concrete acceptance
  criteria. Use sentence-case headings, backticks for code identifiers and commands,
  and descriptive links. Wrap prose at about 90 characters.
- Use prose for connected ideas, lists for steps or separate items, and tables for
  comparisons. Keep structure proportional to the content.

## Goose, not an addition to Goose

- The Goose repository changes daily. Fetch the Goose checkout `GOOSE` is built from
  (`../goose` unless `CLAUDE.local.md` says otherwise) at the start of a session and
  move the pin when it lags (`docs/development.md`, "Move the pin").
- Don't edit the Goose checkout. When the compiler rejects something it should accept,
  miscompiles, or the stdlib lacks something, reduce it to a minimal program, record it
  in `docs/goose-findings.md`, and work around it here. Report blockers to the maintainer.
- Every finding names the Goose commit it was found on, the pin at the time. When one
  lacks it, recover it from this repository's history: the pin in the commit that added
  the entry.
- `docs/goose-findings.md` lists bugs first and feature requests after, each part from
  the least work a fix is expected to take to the most. Place a new entry by that
  order, and delete an entry once the pin has its fix (2026-10-14).
- Write Goose the way the pinned checkout's `samples/` and `stdlib/` do: flat data,
  references into growing arrays, `return ... from` for errors, untyped parameters for
  generics.
- The package is Goose with no C: hashing, bit-packing, and Huffman tables are the work
  that measuring Goose is about. Other languages belong in `bench/` only, as the
  languages of the libraries the package is measured against: C for libdeflate, zlib-ng,
  and libzstd, and Go for klauspost/compress.

## Benchmarks

- Every number comes with how it was measured: machine, OS, compiler, command, input
  corpus, and run count. A result without them doesn't go in a doc.
- libdeflate and zlib-ng run in their fastest documented configuration, built in release
  mode, at the level nearest the package's. Losses are recorded as plainly as wins.

## Code conventions

- Comment only where the code is hard to follow without it, and say only what a reader
  of that code needs: why, a constraint, or a contract the code can't show. Don't restate
  the next line, and don't describe earlier versions or the task that added the code;
  history belongs in git.
- Edit files with the Edit tool, not with `sed` or a Python or PowerShell script. On
  Windows, line endings differ by file type and a shell adds a layer of escaping, and
  scripted edits break on both.

## Commits

- One lean sentence in imperative mood, at most 72 characters.
- No body, no `Co-Authored-By` or any other trailers.
- Fetch and rebase before pushing a finished commit to `origin`.
