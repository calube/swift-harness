# 0004. Proof and mutation may run once, in the final gate

Status: accepted, 2026-09-27, with the build executor plan's "Speed" section
(the plan now lives only in the tag `harness-freeze-2026-10-05`). Changes the build executor spec §5.1.

## Context

Every build task's gate ran `check --tier <taskGate> --base main --prove --mutate`, whatever the preset said, and
`check-return` rejected a worker's return without a proved and mutated run. In interview trial run 2 that cost
13.7 minutes of a 32.8-minute critical path. Prove has a floor of about 55 s per call. One worker was
done after about 6 minutes, then spent 885 s rewriting its code to stubs so prove had a base. The final `ready`
gate proves and mutates the whole diff again (145 s of prove at 3 bases and 100 s of mutation, measured), so the
per-task runs caught nothing the final gate would miss.

## Decision

A required preset key, `task_proof`, is `per-task` or `final` (a closed enum). Under `per-task` each task gate
proves and mutates, as before. Under `final` the task gate drops `--prove --mutate`, `check-return` stops requiring
them from a worker, and the build's final `ready` gate proves and mutates every merged task once. The template
stamps `default` = `per-task` and `interview` = `final`.

## Consequences

- A test that passes without its code, or a weak assertion, surfaces at the final gate instead of at its task.
  The fix then happens after merge, as a fixer round, rather than inside the worker.
- The final gate stays mandatory in every preset (fast modes design §6), so no change reaches a GREEN build
  unproved.
- The 2 cheap checks the research found misplaced move the other way: impact, diff coverage and an app build
  run in every task gate (`check --impact --coverage --app-build`).
- A repo whose `.swiftgate.toml` predates the key fails config loading until each preset names it.
