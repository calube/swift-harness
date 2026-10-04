---
name: run
description: This skill should be used by the orchestrator session that `swiftgate run <spec.md>` launches in a brownfield clone, a repository the harness doesn't own. It takes the spec to a merged plan branch with no human input — reads the spec, picks the areas it touches, runs 1 read-only explorer per area against a deadline, fixes failing command guesses through `swiftgate discover --apply`, writes the live `PLAN.md` with its assumptions, lands a contract commit on the plan branch, imports the plan, builds it with the brownfield preset, runs the `final` gate and prints the end-of-run report. Use when the prompt says it comes from `swiftgate run`, or names a brownfield plan slug and a spec to build.
---

# Run

This session is the orchestrator and planner of 1 brownfield run. The user handed over a spec and
left: every choice is yours, from a reading of an ambiguous sentence to the order of the tasks.
Nothing in a run waits for a person. The user may read or edit `PLAN.md`, or stop the run, but is
never asked anything. When the spec is silent or ambiguous, pick the reading a careful maintainer
of this repository would pick, and write it as 1 bullet under `PLAN.md`'s `## Assumptions`.

`SG="${CLAUDE_PLUGIN_ROOT}/bin/swiftgate"`. Every `swiftgate` step below runs through it.

## Names

| Name | Value |
|---|---|
| `<slug>` | the plan slug the launch prompt names |
| `<spec>` | the spec's path the launch prompt names: the user's file, or its copy in `<plan-dir>`. Read it; never write it |
| `<plan-branch>` | the branch `swiftgate run` created at the user's `HEAD`, named in the launch prompt. Every commit of the run lands on it |
| `<base>` | the commit `<plan-branch>` started at: `git merge-base <plan-branch> HEAD` in the user's checkout, before anything lands |
| `<common>` | `git rev-parse --path-format=absolute --git-common-dir` |
| `<plan-dir>` | `<common>/swift-harness/plans/<slug>` |
| `<checkout>` | `<plan-dir>/checkout`: a worktree on `<plan-branch>`, under the git dir, where you commit and run gates |
| `<config>` | `<common>/swift-harness/config.toml`, written only by `discover --apply` and `allow` |
| `<session>` | the `Session id: <id>` line of the SessionStart context |
| `<run>` | the `runId` that `build start` prints in step 7 |
| `<span>` | the span id `events span start` printed for the phase open now |

The user's checked-out branch never moves and their tree never changes: no commit, no stash, no
checkout there. Read the code there if you like; write only in `<checkout>` and the task worktrees.

## Phase spans

Each phase below opens and closes a span the run viewer draws. Opening one with
`events span start` prints the new span id alone on stdout: keep it as `<span>` for its
`events span end`. Empty output means telemetry is off and there is no span: skip its end. Span
calls never stop the run: any other non-zero exit of either prints 1 line for the report, and the
step goes on without that span.

No build run exists before `build start` in step 7, so the phases before it (spec-read, explore,
plan and contract) name the plan slug as their `--build-run`: the 1 id the run has from launch.
The viewer folds them into the plan's first build run. `final` runs inside the build run and
names `<run>`. Discovery and the warm-up time themselves in `discover.run` and `warmup.run`, so
they take no span call here.

## 1. Read the spec

Open the phase: `"$SG" events span start --phase spec-read --build-run <slug>`, kept as `<span>`.

Read `<spec>` whole. List what it asks for as numbered requirements, each a sentence a test could
check, and every open question it leaves. Answer each open question yourself now, and keep the
answer for `## Assumptions`. A requirement you can't test still gets a task; its acceptance names
the check that stands in for a test.

Close the phase: `"$SG" events span end <span> --outcome ok`.

## 2. Pick the areas

`swiftgate run` already applied discovery. Read the proposal it applied with `"$SG" discover --json`
and the areas in `<config>`: each `[[areas]]` entry has a `name`, a `root`, a `kind`, its
commands (`test`, `test_files`, `lint`, `build`, `e2e`) and the source of each (`found`, `guessed`,
`missing`, `orchestrator`). Pick the areas the spec touches: an area is touched when a requirement
changes a file under its `root`, or a type another touched area reads. Name the touched areas in
`PLAN.md`'s `## Areas`. Files listed in `<common>/swift-harness/discover/dirty.json` were modified
before the run started; no task writes them and nothing stages them.

## 3. Explore and draft at once

Open the phase: `"$SG" events span start --phase explore --build-run <slug>`, kept as `<span>`.

With 1 touched area, or a repository small enough to read in a few minutes, read the code yourself
and skip the explorers. Otherwise launch 1 `swift-harness:brownfield-explorer` per touched area with
the Agent tool, all in 1 message and in the background. Each prompt names the area, its `root`,
its commands from `<config>`, the absolute path of `<spec>`, and the requirements that touch it.
Note the time you launched them.

Each explorer has a 3-minute soft and 4-minute hard deadline and returns in 300 words or fewer.
At 3 minutes, send each explorer still running a message to return what it has now. At 4 minutes,
stop any still running and drop its report: write 1 assumption naming the area and that you
planned it from your own reading.

While they run, draft the plan skeleton: the contract task, 1 task per requirement or per area a
requirement crosses, their dependencies, and the goal line of each. Fill in write sets, tests and
acceptance as reports arrive.

Close the phase: `"$SG" events span end <span> --outcome ok`.

## 4. Fix the commands before planning ends

The warm-up started when discovery finished and runs every area's `generate`, `build` and `test`
at `<base>`, in parallel, to the end. It waits for nothing and you don't wait for it either; read
what it has recorded so far with `"$SG" events list --kind warmup.run`. Each event names an
`area`, a `step`, its `ms`, `cache` and `outcome` (`passed`, `failed`, `dropped`,
`not-installed`).

- **A guessed command failed.** Find the command the repository really uses: its CI workflow,
  its task runner, its README, the explorer's working commands. Try it in `<checkout>`. When it
  works, record it: `"$SG" discover --apply --set <area>.<step>=<command>`. Repeat `--set` for
  several steps in 1 call.
- **No command works.** Drop the step: `"$SG" discover --apply --drop <area>.<step> --reason "<why>"`.
  The area keeps its other steps, and the report carries the reason.
- **A tool isn't installed** (`not-installed`). Drop the step with that reason; installing
  toolchains is outside a run.
- **Build-only areas.** An area whose warm test run takes longer than `slice_budget_s` in
  `<config>`'s `[brownfield]` builds only at `slice`; its tests and their proof run at `merge`.
  Mark it build-only in `## Areas`. An area with no warm time yet, because the warm-up is still
  running, is marked as unknown; `slice` measures it.

Never edit `<config>` by hand.

## 5. Write `PLAN.md`

Open the phase: `"$SG" events span start --phase plan --build-run <slug>`, kept as `<span>`.

Write `<plan-dir>/PLAN.md` in the shape [`references/plan-shape.md`](references/plan-shape.md)
fixes: `## Requirements` with 1 `- req-<name>: <requirement>` bullet per requirement from step 1,
`## Areas`, `## Assumptions` with 1 bullet per reading you made, then 1 `### <task-id>` section
per task, whose `- Covers:` names the requirements it serves. Read that reference now. It holds the field list, an example, how to derive
write sets from each kind's target graph, and the rules a task's write set obeys.

- Every requirement is covered by at least 1 task, and a task covers only listed ids: the import
  fails naming any id that breaks either rule.
- Every task gates at `slice` (`Gate: slice`). Leave `Model:` out: the brownfield preset's pinned
  worker model applies.
- The first task is the contract task (step 6), already done when the plan is imported; every task
  that reads its types depends on it.
- 2 tasks in the same wave never share a write path. A task that changes a target's types owns
  every target that reads them, unless the contract commit landed those types. Each removal has 1
  owning task.

Close the phase: `"$SG" events span end <span> --outcome ok`.

## 6. Land the contract commit

Open the phase: `"$SG" events span start --phase contract --build-run <slug>`, kept as `<span>`.

1. `git worktree add <checkout> <plan-branch>` from the user's checkout. Work only there.
2. Write the contract: the new types, signatures and stubs every task compiles against, with
   behaviour unchanged. It builds in every touched area: run each touched area's `build` command
   from `<config>` in `<checkout>`.
3. `"$SG" check --tier slice --base <base>` in `<checkout>`. Fix any finding the contract caused.
   A finding on a line that must stay as it is, such as a generated file, gets
   `"$SG" allow <rule> <path>:<line> --reason "<why>"`.
4. Commit on `<plan-branch>` with a message in the repository's own style. The repository's git
   hooks run on every commit of the run; a failing hook is a finding to fix, never one to bypass.

Close the phase: `"$SG" events span end <span> --outcome ok`.

## 7. Import and build

1. `"$SG" plan import <slug> --json`. Status `invalid` quotes the task and line to fix: fix
   `PLAN.md` and import again. Status `blocked` names the state it couldn't read: report it and
   stop. The import links the root `PLAN.md` to `<plan-dir>/PLAN.md` and keeps that link out of
   `git status`; workers read the plan by absolute path. It also sets the plan's index entry to
   `planned`, so `build start` needs no `index set`.
2. Run the build loop of `/swift-harness:build` (its `SKILL.md` and `references/event-loop.md`) with
   these changes:
   - Start it with `"$SG" build start <slug> --preset brownfield --session <session> --json`.
   - Its `main` is `<plan-branch>`, checked out in `<checkout>`: run its steps there.
   - Build each worker's pack with `"$SG" context-pack --role worker --ledger <plan-dir>/ledger.json
     --task-id <task> --build-run <run> --json`, with no `--design`: the pack holds the task's
     `PLAN.md` section, its areas' commands and the brownfield rules.
   - Where it halts and asks, decide yourself: take the option it marks recommended, record the
     halt with `build halt` and `build resume` as it says, and add 1 assumption naming the halt
     and what you chose. An option that stops the build ends the run at step 9 with the report.
   - Stop at its step 4; this skill's step 8 replaces it.
   - Review is `classified`: Jev rates each task's diff `low`, `medium` or `high`, and paths in
     `[brownfield] sensitive` are always `high`. When Jev can't answer, the review runs at
     `medium` and the report says so; a missing answer is never read as `low`. You decide every
     finding that would block.

## 8. Final

When `build next` reports nothing to start and nothing running, open the phase:
`"$SG" events span start --phase final --build-run <run>`, kept as `<span>`.

1. In `<checkout>`, `"$SG" check --tier final --base <base> --json`. It runs every area's `test`,
   `lint` and `build` against the baseline, plus each area's `e2e`.
2. Record it: `"$SG" build record-gate <slug> --kind final --run-id <its run id> --session <session> --json`.
3. Not GREEN: close the span with `"$SG" events span end <span> --outcome red`, add 1 fix task
   to `PLAN.md` that owns the failing files, import again, run the build loop until it merges, then
   open a new `final` span as above and run `final` once more. A second red `final` closes its
   span with `"$SG" events span end <span> --outcome red` and ends the run RED; the report quotes
   its findings as `rule: message`.
4. `"$SG" build finish <slug> --session <session> --json`, then close the phase:
   `"$SG" events span end <span> --outcome ok`.
5. `git worktree remove <checkout>`. `<plan-branch>` holds everything.

## 9. Report

`"$SG" run report <slug>` writes the report to `<plan-dir>` and prints it: the assumptions, the
baseline failures, the build-only areas, the dropped steps, the review fallbacks and the plan
branch to merge. Print it as your last message, with the final verdict on the first line. Merging
`<plan-branch>` is the user's call; never merge it into their branch.

## Rules

- Every choice is yours. A question you would ask becomes an assumption in `PLAN.md`.
- Commits land on `<plan-branch>` only, from `<checkout>` or a task worktree under the git dir.
- The repository's git hooks run on every commit; our own commit-message check doesn't run here.
- `<config>` changes only through `"$SG" discover --apply` and `"$SG" allow`.
- Explorer and worker models are pinned ids, never aliases.
- Every gate is a `swiftgate` command. Never hand-write a check or read a gate's verdict from its
  exit status alone; read its JSON.
