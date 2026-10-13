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
says who cancelled it, when, and why. A task that measures something records the numbers
in its own file, with how they were measured.

## Archive

When a task is done and nothing still builds on its file, move it to `000-archive/` with
`git mv`, keeping its name. The main folder then lists only open work. Numbers stay
unique across both folders: pick the next number after the highest in either. Refer to
tasks by number ("task 001"), not by path, so a move breaks no reference.

## Order

Task 001 is the DEFLATE encoder with the gzip and zlib wrappers, goose-http's task
022.02, in steps that each give valid output; goose-http can build against step 1.
zstd, task 004, followed once task 001 was measured, and is done; its speed, 2 to 3
times slower than libzstd's, is still being improved. Task 003 takes the DEFLATE
encoder's speed past task 001's. Task 002, brotli, waits on
a measurement that shows it's needed.
