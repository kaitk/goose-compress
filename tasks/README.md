# Tasks

Markdown-based task tracking. One file per task, or one folder for a task with
several subtasks or its own supporting files.

## Naming

`NNN-short-slug.md` — zero-padded, sequential number plus a kebab-case slug,
e.g. `001-gzip.md`.

A task with subtasks or supporting files is a folder with the same name,
`NNN-short-slug/`, holding the task itself as `README.md` and one file per
subtask as `NN-short-slug.md`, numbered within the folder. Subtasks use the same format
as tasks.

## Format

```markdown
# NNN: Title

Status: todo | in-progress | done | cancelled

Short description of what and why.

## Acceptance criteria

- [ ] Concrete, verifiable outcome
- [ ] ...
```

Update the status line as work progresses; tick criteria as they are met. A cancelled task
says when it was cancelled and why. A task that measures something links to the
numbers and their method in `docs/results.md` or `docs/results-history.md`.

## Archive

When a task is done and nothing still builds on its file, move it to `000-archive/` with
`git mv`, keeping its name. The main folder then lists only open work. Numbers stay
unique across both folders: pick the next number after the highest in either. Refer to
tasks by number ("task 001"), not by path, so a move breaks no reference.

Archived tasks describe the implementation at completion. Use the README and
architecture doc for current behavior, and results for the latest measurements.

## Order

Tasks 001 (gzip and zlib) and 004 (zstd) are done and in `000-archive/`.
Task 003 records the earlier DEFLATE tuning; task 005 continues that work for both
DEFLATE and zstd on the Ryzen, aiming for parity with the C libraries or a decision
to proxy to them. Task 002, brotli, waits
on a measurement that shows it's needed. See the [latest results](../docs/results.md)
for the measured gaps. Task 006 moves the build to Goose releases; its Windows and Linux
test runs remain.
