---
name: build
description: This skill should be used to build a planned swift-harness plan, running its ledger tasks in parallel worktrees until merged main is green. It starts a build run with a preset, asks `swiftgate build next` which tasks to start, launches the build-task workflow in the background for each one, and on each completion checks the return, merges it, runs the merge gate on main, sets the ledger and republishes the ledger page. It halts and asks on a red main after the fixer, a design conflict, a task still red after its fix pass, and a time-budget cutoff. Use when the user says "build the plan", "start the build", "run the ledger", "/swift-harness:build", or after /swift-harness:plan reports a planned ledger.
---

# Build

Invoking this skill is the user's opt-in to run the build: 1 workflow per task, each with a worker,
and at the `full` review preset 2 reviewers, plus a fixer for each merge that goes red. This skill
is the orchestrator. It runs every git, ledger and gate step as a `swiftgate` command in this main
session, launches workflows, and asks the user. It never edits code and never writes the ledger by
hand.

`SG="${CLAUDE_PLUGIN_ROOT}/bin/swiftgate"`. Run every command from the main checkout's toplevel,
on `main`: `build merge` merges there.

The long form of every step, the halt options and the resume rules are in
[`references/event-loop.md`](references/event-loop.md). Read it before step 1.

## Names

| Name | Value |
|---|---|
| `<slug>` | the plan slug: the argument, or the plan the SessionStart context lists as `planned` or `building` |
| `<preset>` | `--preset <name>`, else `default`; a name `.swiftgate.toml` defines under `[build.presets]` |
| `<session>` | the `Session id: <id>` line of the SessionStart context. Absent: stop, never invent one |
| `<plans>` | `$(git rev-parse --git-common-dir)/swift-harness/plans` |
| `<run>` | the `runId` that `build start` or `build next` prints |
| `<returns>` | `<plans>/<slug>/build/<run>/returns/` |

## Halt and ask

**Halt** means: start nothing new, keep every running workflow alive, and ask the user with
`AskUserQuestion`. Put the recommended option first with `(Recommended)` in its label, and ask at
most 4 questions per prompt. Quote the failing command's `message` or its findings as `rule: message`.
A headless session has no `AskUserQuestion`: end the turn with the questions and their options,
recommended first. Never work around a halt by hand. The reference lists the options for each halt.

## 1. Start

1. `"$SG" plan claim <slug> --session <session> --json`. Exit 1 names the session that holds the
   plan: halt.
2. `"$SG" build start <slug> --preset <preset> --session <session> --json`. Keep `runId`. Exit 1
   because the index is `building` means a run already exists: resume it instead
   ([resume](references/event-loop.md#resume)). Any other non-zero exit: halt.
3. Read `<plans>/<slug>/build/<run>/run.json` for the preset, `<plans>/<slug>/plan.json` for the
   design doc, and start the cutoff timer when `timeBudgetMin` isn't 0
   ([time budget](references/event-loop.md#time-budget)).

## 2. Start ready tasks

`"$SG" build next <slug> --session <session> --json` gives `phase`, `toStart`, `running` and `refused`.
For each task in `toStart`:

1. `"$SG" worktree create <slug> <task> --session <session> --json`. Keep `worktree` and `branch`.
2. Build the worker's pack:
   `"$SG" context-pack --role worker --design <doc> --ledger <plans>/<slug>/ledger.json --task-id <task> --build-run <run>`.
3. `"$SG" ledger set <slug> <task> in-progress --session <session> --json`.
4. Launch `workflows/build-task.js` with the Workflow tool, in the background, with the
   [args](references/event-loop.md#launch) the task and preset give. Keep the task id the tool
   returns, for its completion notice and for `TaskStop`.

A non-zero exit at any of these halts that task alone. `refused` tasks never start: list them for
the user once. Then wait for a completion notice.

## 3. On each completion

Handle notices one at a time: merges run in completion order.

1. A null or thrown workflow halts that task. Otherwise write the return and check it:
   `"$SG" build check-return <file> --plan <slug> --session <session> --json`. Exit 0 passes; any
   other exit halts that task.
2. Write the checked return, byte for byte, to `<returns><task>.json`: dependent tasks' packs read
   its `notes` from there.
3. By `outcome`: `gate-red` or `review-blocked` halts that task, and `design-conflict` follows
   [§8.4](references/event-loop.md#design-conflict). `ready-to-merge` goes on.
4. `"$SG" build merge <slug> <task> --session <session> --json`, then
   `"$SG" check --tier <mergeGate>` on main. A conflict or a red gate goes to
   [the fixer](references/event-loop.md#conflict-or-red-main).
5. `"$SG" ledger set <slug> <task> done --session <session> --json`, then
   `"$SG" worktree remove <slug> <task> --session <session> --json`.
6. Republish the ledger page: `"$SG" design-render --ledger <slug> --json`, then the Artifact tool
   with the same file path every time.

Go back to step 2.

## 4. Finish

When `build next` reports nothing to start and nothing running, or at the cutoff:

1. Wait for the machine's other `ready` runs, then `"$SG" check --tier ready`
   ([final gate](references/event-loop.md#final-gate)). Not GREEN: halt.
2. The `validate` stage: print `validate: not configured` and go on.
3. `"$SG" build finish <slug> --session <session> --json`.
4. `"$SG" stats --build <run> --plan <slug>` for the wall time.

## Report

The ledger page link, then: tasks done, and the unfinished ones with their status from `build finish`;
each halt and the user's answer; the `ready` verdict and run id; wall time against the budget;
`resume` when the index stays `building`. The claim stays with this session.

## Rules

- Only `swiftgate` writes the ledger, the index, run state and git. This skill writes only the
  return files and the ledger page.
- Never merge by hand, never reset `main` except through `build merge --undo`, never push.
- A subagent or a workflow never runs a `build`, `ledger` or `worktree` command; the guard denies it.
- When a `swiftgate` command and your reading disagree, the command wins.
