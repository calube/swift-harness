---
name: build
description: This skill should be used to build a planned swift-harness plan, running its ledger tasks in parallel worktrees until merged main is green. It starts a build run with a preset, asks `swiftgate build next` which tasks to start, launches the build-task workflow in the background for each one, and on each completion checks the return, merges it, runs the merge gate on main, sets the ledger and republishes the ledger page. It halts and asks on a red main after the fixer, a design conflict, a task still red after its fix pass, and a time-budget cutoff. Use when the user says "build the plan", "start the build", "run the ledger", "/swift-harness:build", or after /swift-harness:plan reports a planned ledger.
---

# Build

Invoking this skill is the user's opt-in to run the build: 1 workflow per task, each with a worker,
and at the `full` review preset 2 reviewers and a verifier for each reviewer's findings, plus a
fixer for each merge that goes red. This skill
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
| `<preset>` | `--preset <name>`; else the `profile` key of `[harness]` in `.swiftgate.toml`; else `default`. When `.swiftgate.toml` has no `[build.presets.<preset>]` table, stop and list the names it defines; never fall back to another preset |
| `<session>` | the `Session id: <id>` line of the SessionStart context. Absent: stop, never invent one |
| `<plans>` | `$(git rev-parse --git-common-dir)/swift-harness/plans` |
| `<run>` | the `runId` that `build start` or `build next` prints |
| `<returns>` | `<plans>/<slug>/build/<run>/returns/` |
| `<transcripts>` | per task, the transcript directory the Workflow tool printed when it launched the task |
| `<surfaceCommit>` | `plan.json`'s `surfaceCommit`: the plan surface, when the plan has one (step 1) |
| `<span>` | the span id `events span start` printed for the phase open now |

## Halt and ask

**Halt** means: start nothing new, keep every running workflow alive, and ask the user with
`AskUserQuestion`. Put the recommended option first with `(Recommended)` in its label, and ask at
most 4 questions per prompt. Quote the failing command's `message` or its findings as `rule: message`.
A headless session has no `AskUserQuestion`: end the turn with the questions and their options,
recommended first. Never work around a halt by hand. The reference lists the options for each halt.

Once `build start` has printed `<run>`, time every halt: just before asking,
`"$SG" build halt --run <run> [--task <task>] --reason <reason>`; just after the answer, before
acting on it, `"$SG" build resume --run <run> [--task <task>] --answer <answer>` with the same
`--task`. A headless session records the halt and ends its turn; the resume comes when the answer
does. Never pass question or answer text. Neither command's exit changes what happens next: a
failure prints 1 line, so name it in the report. The reference maps each halt to its
[reason and answers](references/event-loop.md#recording-halts).

## Phase spans

The build times its `final` phase as a span the run viewer draws. Opening it with
`events span start` prints the new span id alone on stdout: keep it as `<span>`, and close it
with `events span end` on every way out of the phase. Empty output means telemetry is off and
there is no span: skip its end. Span calls never stop the build: any other non-zero exit of
either prints 1 line for the report, and the step goes on without that span. The run skill times
the phases before `build start`; this skill has no build run id until then.

## 1. Start

1. `"$SG" doctor --session <session>`. A running session keeps the skills and agent prompts it
   loaded at start, so a plugin change reaches only new sessions. `doctor.plugin-changed` means
   this session runs the old text: stop, and tell the user to start a fresh session. Any other
   non-zero exit: quote its findings as `rule: message` and stop.
2. `"$SG" plan claim <slug> --session <session> --json`. Exit 1 names the session that holds the
   plan: halt.
3. Read `<plans>/<slug>/plan.json` for the plan's source and surface. `"source": "specPage"` marks a
   spec page plan: its page is `<plans>/<slug>/<specPage.path>`. Any other plan builds from the
   design doc in `design`. Keep `surfaceCommit` as the plan surface, or `null` when the key is
   absent: every worker gets it ([launch](references/event-loop.md#launch)), and every gate this
   skill runs on `main` measures from it.
4. Unless the index is already `building` (a resume), check that `main` is green:
   `"$SG" check --tier <merge_gate>`, with the preset's `merge_gate` from `.swiftgate.toml`; with a
   plan surface, `"$SG" check --tier <merge_gate> --base <surfaceCommit>`. Not
   GREEN: halt, and quote the findings as `rule: message`. Options: **stop** (Recommended) so
   `main` gets fixed first, or **go on** with these findings as the baseline. With a baseline, a
   later merge gate passes when every gating finding it has is one of the baseline's. Every merge gate
   runs on `main`, so a finding already there would read as the task's fault.

   With a plan surface, 1 red needs no question: when every gating finding is
   `coverage.no-t1-tests` for a module the surface commit added, take them as the baseline without
   asking. A surface can't add a test target (an empty one fails `t1.no-tests`), so the task that
   tests the module adds it. The surface added the module at a finding's `file` when
   `git diff --name-only <surfaceCommit>^ <surfaceCommit> -- <file>` lists files and
   `git ls-tree -r --name-only <surfaceCommit>^ -- <file>` lists none. Any other gating finding
   beside them still halts, quoting every finding, theirs included.
5. `"$SG" build start <slug> --preset <preset> --session <session> --json`. Keep `runId`. Exit 1
   because the index is `building` means a run already exists: resume it instead
   ([resume](references/event-loop.md#resume)). Any other non-zero exit: halt.
6. Read `<plans>/<slug>/build/<run>/run.json` for the preset, and start the cutoff timer when
   `timeBudgetMin` isn't 0 ([time budget](references/event-loop.md#time-budget)).

A plan surface is on `main` before the build starts, and its stubs add API no test covers yet.
Measuring from it judges what the tasks change on top of it. Workers' task gates keep
`--base main` ([launch](references/event-loop.md#launch)).

## 2. Start ready tasks

`"$SG" build next <slug> --session <session> --json` gives `phase`, `toStart`, `running`, `refused`
and `required`. Run it from the main checkout's toplevel: it reads `.swiftgate.toml`'s `packages` to find
the tasks the app target needs, and exits 2 when it can't, so fix the config rather than go on.
At `no-new-starts`, `toStart` holds only those [required tasks](references/event-loop.md#time-budget).
For each task in `toStart`:

1. `"$SG" worktree create <slug> <task> --session <session> --json`. Keep `worktree` and `branch`.
2. Build the worker's pack ([worker pack](references/event-loop.md#worker-pack)): for a design
   plan,
   `"$SG" context-pack --role worker --design <doc> --ledger <plans>/<slug>/ledger.json --task-id <task> --build-run <run>`;
   for a spec page plan, `--spec-page <page>` in place of `--design <doc>`.
3. `"$SG" ledger set <slug> <task> in-progress --session <session> --json`.
4. Launch `workflows/build-task.js` with the Workflow tool, in the background, with the
   [args](references/event-loop.md#launch) the task and preset give. Keep the task id the tool
   returns, for its completion notice and for `TaskStop`.
5. Start the task's [stall watch](references/event-loop.md#stall-watch) on `<transcripts>`, the
   transcript directory the Workflow tool printed.

A non-zero exit at any of these halts that task alone. `refused` tasks never start: list them for
the user once. A design plan's validation task commits nothing, so it never runs the build-task
workflow: launch it as [the validation task](references/event-loop.md#validation-task) says. Then
wait for a completion notice.

## 3. On each completion

Handle notices one at a time: merges run in completion order. First record the task's agent usage,
whatever its outcome:
`"$SG" events ingest --session <session> --workflow-transcripts <transcripts> --role build-worker --task <task> --build-run <run>`.
Telemetry never stops the build: an exit 2 that says `telemetry is off` means the repo opted out,
so say nothing; any other non-zero exit prints 1 line for the report, and the step goes on.

1. A null or thrown workflow halts that task. Otherwise write the return and check it:
   `"$SG" build check-return <file> --plan <slug> --session <session> --json`. Exit 0 passes; any
   other exit halts that task.
2. Write the checked return, byte for byte, to `<returns><task>.json`: dependent tasks' packs read
   its `notes` from there.
3. By `outcome`: `gate-red` or `review-blocked` halts that task, and `design-conflict` follows
   [§8.4](references/event-loop.md#design-conflict). `ready-to-merge` goes on.
4. `"$SG" build merge <slug> <task> --session <session> --json`, only after step 1 exits 0 and as
   its own command: `build merge` refuses unless the build run's newest check of this return is
   GREEN at the branch tip (`return-unchecked`, `return-not-green`, `return-stale`). Then
   `"$SG" check --tier <mergeGate>` on main (with a plan surface,
   `"$SG" check --tier <mergeGate> --base <surfaceCommit>`), then record it for the ledger page:
   `"$SG" build record-gate <slug> --kind merge --task <task> --run-id <its run id> --session <session> --json`.
   A conflict or a red gate goes to [the fixer](references/event-loop.md#conflict-or-red-main). A
   gate whose every gating finding is one of the step 1 baseline's counts as GREEN: a task that
   tests 1 of the surface's modules clears its finding and leaves the others. A plan with a
   `validation.json` then runs the rows this merge unblocks, as
   [after each merge](references/event-loop.md#after-each-merge) says.
5. `"$SG" ledger set <slug> <task> done --session <session> --json`, then
   `"$SG" worktree remove <slug> <task> --session <session> --json`. After a fix merge, also
   `"$SG" worktree remove <slug> <task> --fix --session <session> --json`.
6. Republish the ledger page: `"$SG" design-render --ledger <slug> --json`, then the Artifact tool
   with the same file path every time. When this session has no Artifact tool, don't publish:
   report the rendered page's path, `.harness/design-render/<slug>-ledger.html`, in its place and
   go on. The page is a view, never a gate.

Go back to step 2.

## 4. Finish

When `build next` reports nothing to start and nothing running, or at the cutoff:

1. Open the phase: `"$SG" events span start --phase final --build-run <run>`, kept as `<span>`.
   Wait for the machine's other `ready` runs, then run `"$SG" build proof-bases <slug>` and
   `"$SG" check --tier ready` (with a plan surface, `"$SG" check --tier ready --base <surfaceCommit>`)
   with the `--proof-base` arguments it prints
   ([final gate](references/event-loop.md#final-gate)). Record it with
   `"$SG" build record-gate <slug> --kind final --run-id <its run id> --session <session> --json`
   and republish the ledger page. Not GREEN: `"$SG" events span end <span> --outcome halted`,
   then halt; after the answer, open a new `final` span before going on. This gate takes no
   baseline: the step 1 baseline, asked for or not, covers only the merge gates.
2. The `validate` stage, on merged `main` after the `ready` gate. Read `sim_qa` in
   `[build.presets.<preset>]` of `.swiftgate.toml`; a preset without it reads `off`. At `off`,
   print `validate: sim_qa off` and go on. At `changed`:
   1. When `<plans>/<slug>/validation.json` exists, `"$SG" qa run --plan <slug> --final --json`.
      It runs every ready row and records each flow with a video, a contact sheet and its logs.
   2. Then `/swift-harness:qa`, as a validate stage: it takes that run's rows, drives the screens
      the plan changed, and hands nothing to `/swift-harness:tdd`.

   A RED from either: `"$SG" events span end <span> --outcome halted`, then halt as the
   [validate stage](references/event-loop.md#validate-stage) says; after the answer, open a new
   `final` span before going on.
3. `"$SG" build finish <slug> --session <session> --json`, then close the phase:
   `"$SG" events span end <span> --outcome ok`.
4. `"$SG" stats --build <run> --plan <slug>` for the wall time.

## Report

The ledger page link, then: tasks done, and the unfinished ones with their status from `build finish`;
each halt and the user's answer; each failed `events ingest` or `events span` line; the green-main baseline taken without asking, as
`rule: file` per finding; the `ready` verdict and run id; wall time against the budget;
`resume` when the index stays `building`. Then the `validate` stage: its `qa run` id and verdict
and the QA skill's report, or `validate: sim_qa off`. The claim stays with this session.

## Rules

- Only `swiftgate` writes the ledger, the index, run state and git. This skill writes only the
  return files and the ledger page.
- Never merge by hand, never reset `main` except through `build merge --undo`, never push.
- A subagent or a workflow never runs a `build`, `ledger` or `worktree` command; the guard denies it.
- When a `swiftgate` command and your reading disagree, the command wins.
