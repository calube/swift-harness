# Build agent calibration seeds

`swiftgate calibrate build` runs `build-worker` and `build-fixer` on the seeded repositories in
this directory and judges what they leave behind (spec §12). Each case is a tiny Swift package
with a known correct diff, labelled by construction: the case's `solution/` meets its label, and
`CalibrateBuildTests` checks that it does.

## Layout

```
gate/Fixtures/calibrate-build/
  README.md
  last-pass.json                 written by a full pass; committed
  build-worker/<case>/
    input.md                     the prompt the agent gets, with {{placeholders}}
    label.json                   what a correct agent does
    context.md                   the context pack the prompt points at
    base/                        the repository's first commit on main
    accept/                      acceptance tests laid over the result, never shown to the agent
    solution/                    the known correct diff, laid over base/
  build-fixer/<case>/
    input.md, label.json, accept/, solution/ as above
    base/                        the common ancestor
    main/                        laid over base/ and committed on main: the task already merged
    task/                        laid over base/ and committed on the task branch
```

- Only `build-worker` and `build-fixer` may have seeds. Any other directory exits 1 with
  `calibrate-build.unknown-agent`, and either agent without a case exits 1 with
  `calibrate-build.uncalibrated-agent`.
- A missing `label.json` or `input.md` is `calibrate-build.missing-label` or `missing-input`. A
  missing entry the agent needs, such as `base/` or `context.md`, is `calibrate-build.missing-entry`.
- `solution/` is read only by the tests. The agent sees `input.md`, `context.md` and the
  repository.

## How a case runs

1. The seed's repository is built in a scratch directory under the system temp directory. A worker
   gets `base/` on `main` and a checked-out branch `calibrate/<case>`. A fixer gets `base/`, `task/`
   committed on `calibrate/<case>`, `main/` committed on `main`, and a checked-out branch
   `calibrate/fix-<case>` where merging the task branch left a conflict. If the merge doesn't
   conflict, the case is a `calibrate-build.seed-defect`. `refs/remotes/origin/main` points at
   `main`, so `swiftgate check` finds its default base.
2. `input.md` is filled in and sent on stdin to `claude -p` in the repository, with the agent's
   body as the system prompt, its frontmatter `tools`, and its frontmatter `model` (`sonnet` when
   it names none, as `build-worker` does: its model is chosen per task). `--model <m>` runs every
   agent on `<m>` instead, for experiments, and push never counts that record as fresh. The run loads no user, project or local settings and no MCP servers, and this
   checkout's `plugin/bin` goes first on `PATH`. The placeholders are `{{worktree}}`,
   `{{branch}}`, `{{plan}}` (`calibrate`), `{{task}}` (the case name), `{{contextPack}}` (worker),
   and `{{mainCommit}}` and `{{taskCommit}}` (fixer). An unfilled one is a seed defect.
3. The judge checks, each as one answer in the record:

| Question | Expected | What's checked |
|---|---|---|
| `outcome` | the label's `outcome` | the final message is a `TaskReturn`, and its outcome |
| `return` | `matches` | the return's claims, as `build check-return` checks them: its commits are on the branch, its gate run is in the sandbox's run history with the tier and verdict it claims, at or above the label's `gate`. A worker's `review: null` isn't a finding |
| `scope` | `inside-write-set` | every file the branch changed since it started (the base for a worker, `main` for a fixer) is in `writeSet` |
| `refs` | `unchanged` | no ref but the agent's own branch moved, appeared or vanished, and `HEAD` is still on that branch |
| `resolution` | `resolved` (fixer only) | no merge in progress, no unmerged path, the tip contains both sides, no conflict markers |
| `tests` | `passed` | `accept/` laid over the branch tip in a separate worktree; every labelled test ran and passed under `swift test` |

Every answer met in every case: exit 0, and `last-pass.json` is rewritten. Any miss: exit 1 with
one `calibrate-build.label-missed` per answer, the sandbox kept for inspection, and
`last-pass.json` left as it was. A `calibrate-build.usage` note per case gives the model, cost and
time. When git, `swift` or `claude` can't run or `claude` reports an error, the run exits 2.

## `label.json`

```json
{
  "schemaVersion": 1,
  "outcome": "ready-to-merge",
  "gate": "fast",
  "writeSet": ["Sources/Greeter/Greeter.swift", "Tests/GreeterTests/GreeterTests.swift"],
  "tests": ["GreeterTests.CalibrationAcceptance/formalGreeting()"]
}
```

- Every key is required and no other is allowed. `outcome` is a `TaskReturn` outcome and `gate`
  a check tier.
- `writeSet` holds distinct paths relative to the repository, with no `..`.
- `tests` holds distinct `<classname>/<name>` pairs as the xUnit report writes them.
- A label that breaks any of these exits 1 with `calibrate-build.invalid-label`.

## The seeds

| Agent | Case | A correct agent |
|---|---|---|
| `build-worker` | `formal-greeting` | adds `Greeter.greet(_:formal:)` test-first, touching only `Greeter.swift` and `GreeterTests.swift`, and returns `ready-to-merge` with a green `fast` run |
| `build-fixer` | `formal-greeting-meets-farewell` | resolves the conflict between `farewell(_:)` on `main` and `greet(_:formal:)` on the task branch by keeping both, and returns `ready-to-merge` with a green `fast` run |

## `last-pass.json`

A `CalibrationRecord`, as `calibrate design` writes it. `contentHash` covers
`plugin/agents/build-worker.md` and `plugin/agents/build-fixer.md`, so editing either one makes the
record stale. Each case's `model` is the model its agent ran on. A build check's `probability` is `1`: it observes
rather than asks. Editing a seed doesn't change the hash, so rerun the calibration after changing
one.

## Freshness at push

`swiftgate check --tier push` compares `contentHash` with the working tree's build agents, and each
case's `model` with its agent's frontmatter, as it does for the design suite, with the same
`calibration-freshness.*` rules. A repository with neither
build agent skips the build suite.
