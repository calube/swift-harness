# The build event loop in detail

The long form of the build skill's steps. `<slug>`, `<preset>`, `<session>`, `<plans>`, `<run>` and
`<returns>` mean what the skill's table says. `SG="${CLAUDE_PLUGIN_ROOT}/bin/swiftgate"`.

Contents:

- [State this skill keeps](#state-this-skill-keeps)
- [Worker pack](#worker-pack): what `context-pack --role worker` derives itself
- [Launch](#launch): the workflow's args
- [Returns](#returns): where each file goes
- [Conflict or red main](#conflict-or-red-main): undo, fixer, fix merge
- [Task halts](#task-halts): a null workflow, a failed check, `gate-red`, `review-blocked`
- [Design conflict](#design-conflict)
- [Stall watch](#stall-watch): a worker that stops without returning
- [Time budget](#time-budget)
- [Final gate](#final-gate)
- [Resume](#resume)

## State this skill keeps

Keep these in the conversation; none of them is a file:

- per running task: its Workflow task id, its stall watch's task id, `worktree`, `branch`;
- the order tasks merged in, for the fixer's second return;
- the ledger page's file path, `.harness/design-render/<slug>-ledger.html`.

Every other fact comes from `swiftgate`: the ledger from `<plans>/<slug>/ledger.json`, the preset
from `<plans>/<slug>/build/<run>/run.json`, the running set from `build next`.

`<plans>` must stay repo-relative when a command takes it as a path: `context-pack` refuses an
absolute path. From the main checkout's toplevel, `git rev-parse --git-common-dir` prints `.git`.

## Worker pack

Build it with exactly the flags the skill's step names:

```
"$SG" context-pack --role worker --design <doc> --ledger <plans>/<slug>/ledger.json --task-id <task> --build-run <run>
```

Never pass `--module-kind`: the command refuses it for a worker. It reads the task's write set
against the repo's module graph (`.swiftgate.toml`'s packages) and packs the standards sections for
every module kind the write set touches. A test target counts as the module it tests. The
standards are the repo's `docs/standards.md` plus `docs/testing-playbook.md`, else the harness
plugin's; `--standards` overrides that.

An entry outside every module (a doc, a manifest, a fixture) adds no kind. A write set with no
module entries gets a standards section saying "No module kinds in this task's write set; no
standards excerpt." A module kind `.swiftgate.toml` names outside the known kinds exits 1 with
`context-pack.module-kind-unknown` and writes no pack. That halts the task: tell the user.

## Launch

The task's ledger entry and the run's preset give the args. Pass them as a JSON object, never as a
string:

```
Workflow({
  scriptPath: "${CLAUDE_PLUGIN_ROOT}/workflows/build-task.js",
  args: {
    task: "<task>",
    plan: "<slug>",
    worktree: "<absolute worktree path from worktree create>",
    branch: "<slug>/<task>",
    writeSet: ["<the task's writeSet>"],
    taskGate: "<fast|push|ready>",
    tests: ["<the task's tests>"],
    contextPack: "<absolute path of .harness/context-pack/worker-<task>.md>",
    model: "<sonnet|opus>",
    review: "<full|gate>",
    taskProof: "<per-task|final>"
  }
})
```

- `taskGate`: the preset's `taskGate` when it names a tier; under `ledger`, the task's own `gate`.
  The workflow tells the worker to run it as `check --tier <taskGate> --base main`, with
  `--proof-base <surface commit>` when the task adds API, and adds `--prove --mutate` under
  `per-task` proof.
- `model`: the task's `model` when the preset's `workerModel` is `tagged`, else the preset's
  `workerModel`. `build next` refuses a task with no model to use, so one always exists.
- `review`: the preset's `review`. Leave out `reviewers`; `full` then runs both.
- `taskProof`: the preset's `taskProof`. Under `per-task` every task proves and mutates its own
  change, and `build check-return` fails a worker's green gate that skipped either. Under `final`
  no task gate does, and the [final gate](#final-gate) proves and mutates every merged task once.

Unknown or missing args make the workflow throw `build-task: …` at once: that is a skill bug, so fix
the args and relaunch, and don't count it as the task's attempt.

The workflow runs in the background. Its completion arrives as a notice with its result. Go on
with other tasks, or end the turn to wait; never poll.

## Returns

1. Write the workflow's return, byte for byte, to `.harness/build/<run>/<task>.json`. Take it from
   the `result` key of the task's output file, the path the completion notice names. The notice
   text HTML-escapes the return, so `->` arrives as `-&gt;`, and a copy of it is corrupt.
2. `"$SG" build check-return .harness/build/<run>/<task>.json --plan <slug> --session <session> --json`.
   Exit 0 is `verdict` GREEN. Exit 1 lists `findings` as `{rule, message}`: the return claims more
   than git or the run store shows. Exit 2 means the file is unreadable or isn't a task return.
3. After exit 0, write the same bytes to `<returns><task>.json` with the Write tool. The edit
   guard lets the session that holds the plan's lock write inside the plan directory. Store
   `design-conflict` returns too: they carry the conflict report.

This skill never stores a return that fails the check, so no dependent pack quotes its notes.
`context-pack --build-run` exits 1 when a dependency's return is missing, so a dependent can't
start from a return this skill skipped.

## Conflict or red main

The merge gate is the preset's `mergeGate`. Run it on `main` after every clean merge:
`"$SG" check --tier <mergeGate>`.

When the user chose **go on** at the start's green-main check, compare the gate's gating findings
with that baseline by `rule`, `file` and `message`. The same set counts as GREEN. Anything new is a
red gate, and the fixer gets only the new findings.

| What happened | Next |
|---|---|
| `build merge` exits 1 with `status` `conflicted` | `main` is untouched, and the fix worktree is cut |
| the merge gate isn't GREEN | `"$SG" build merge <slug> <task> --undo --session <session> --json` resets `main` and cuts the fix worktree |
| `build merge` exits 1 with another `reason` | halt: `main-moved`, `dirty-checkout` and `not-on-main` need the user; `already-merged` means the ledger lags, so run `ledger set … done` and go on |
| `build merge` exits 2 | halt |

An `--undo` that exits non-zero halts: `main` may still hold the red merge. Quote its `reason`.

Then the fixer, 1 attempt. Launch `swift-harness:build-fixer` with the Agent tool, in the foreground,
and give it:

- the plan slug and the task id;
- `fixWorktree` and `fixBranch` from the `build merge` JSON;
- the case: `conflicted` with `conflictedFiles`, or a clean merge that turned the merge gate red;
- both returns: this task's, and that of the task it collides with, read from `<returns>`. For a
  conflict, that's the merged task whose `writeSet` holds a conflicted file; otherwise, or when none
  does, the task merged last;
- the merge gate tier.

Write its reply to `.harness/build/<run>/fix-<task>.json` and check it:
`"$SG" build check-return .harness/build/<run>/fix-<task>.json --plan <slug> --fix --session <session> --json`.

- The check passes and `outcome` is `ready-to-merge`:
  `"$SG" build merge <slug> <task> --fix --session <session> --json`, then the merge gate on
  `main` again, recorded with `build record-gate --kind merge --task <task>` like the first.
  GREEN: go on to `ledger set … done` as for a clean merge, and after the task's
  `worktree remove`, remove the fix worktree and branch too:
  `"$SG" worktree remove <slug> <task> --fix --session <session> --json`.
- Anything else, or a red gate after the fix merge (undo it first with `--undo`): halt, and
  set the task `blocked`. Options: stop the build (Recommended), abandon this task and go on, or
  leave it blocked and go on with the rest.

## Task halts

A null or thrown workflow, a return that fails `check-return`, and a `gate-red` or `review-blocked`
outcome each halt that task alone. The workflow already spent its 1 fix pass.

1. `"$SG" ledger set <slug> <task> blocked --session <session> --json`. `build next` never lists a
   `blocked` task, and neither does a resumed build.
2. Ask. Quote the check's findings, the return's `gate`, or the blocking review findings as
   `severity file: title`. Options:
   - **Go on without it** (Recommended): it stays `blocked`; its dependents never start.
   - **Retry**: `ledger set … pending`, then let `build next` start it again. Its worktree and
     branch still exist, so skip `worktree create` and launch into the same worktree.
   - **Abandon**: `ledger set … abandoned`.
   - **Stop the build**: start nothing new; running tasks still merge, then [finish](#final-gate).

## Design conflict

A checked `design-conflict` return carries `designConflict` with `section`, `ids` and `claim`. The
preset's `onDesignConflict` decides.

`block`:

1. `ledger set <task> blocked` for the reporting task. For each other `in-progress` task whose
   `covers` intersects `ids`, stop its workflow with `TaskStop` and set it `blocked` too.
2. `ledger set <task> blocked` for every `pending` task whose `covers` intersects `ids`, then for
   every `pending` task that depends on a blocked one, however far down the chain. The block lives
   in the ledger, so a resumed build sees it.
3. Ask once, quoting `section: claim` and the ids. Options: **stop** (Recommended), **drop** the
   blocked tasks (`ledger set … abandoned`), or **retry** them (`ledger set … pending`). A retried
   task that already had a worktree relaunches into it; the others start through `worktree create`
   as usual. The workflow args carry no note, so a retry with a note means the user edits the design
   or the plan first.

`amend`: set the reporting task `blocked`, and run the amend flow
with the Skill tool: `swift-harness:design` with `--amend <slug>`. It marks the affected tasks
`needs-replan`. The other tasks keep building; the report names the `needs-replan` tasks, which wait
for `/swift-harness:plan`.

## Stall watch

A background worker can stop without returning. A permission prompt it can't show is 1 cause: the
tool call never runs, and nothing tells the orchestrator. The workflow script has no clock, so the
orchestrator watches from outside. After each launch, run this with `run_in_background`, where
`<dir>` is the transcript directory the Workflow tool printed:

```bash
d=<dir>; while /bin/sleep 120; do [ -z "$(find "$d" -name 'agent-*.jsonl' -mmin -15)" ] && { echo "stalled: $d"; exit 0; }; done
```

Every tool call and result appends to an agent's transcript, so 15 minutes with no change means no
agent in that workflow has moved. Keep the watch's task id beside the workflow's. When the
workflow's completion notice arrives, `TaskStop` its watch.

When a watch fires, read the last line of the newest `agent-*.jsonl` in `<dir>`. Halt, and quote its
last tool call. Options:

- **Stop and retry** (Recommended): `TaskStop` the workflow, `ledger set … pending`, and relaunch
  into the same worktree. The worker's uncommitted edits stay there.
- **Wait**: restart the watch. Pick this when the last call is a long gate, such as a `ready` tier.
- **Abandon**: `TaskStop` the workflow, then `ledger set … abandoned`.

## Time budget

With `timeBudgetMin` 0 there is no budget. Otherwise, right after `build start`, start a timer: a
Bash `/bin/sleep <seconds left until startedAt + timeBudgetMin>` with `run_in_background`, which
wakes the loop when it exits. `build next` stops listing new starts on its own once `phase` is
`no-new-starts`.

When the timer fires, or any `build next` reports `phase` `cutoff`:

- Nothing running: go to the [final gate](#final-gate).
- Tasks running: halt. Options: **stop them now** (Recommended), or **let them finish** without new
  starts. A headless session stops them. To stop them: `TaskStop` each workflow, then
  `ledger set <task> abandoned`, then go to the final gate. `main` stays green: every merge ran
  the merge gate.

## Final gate

Only 1 `ready` tier runs at a time on this machine. Wait for the others in the foreground first.
Then pass every merged task's surface commit as a proof base, so a test of API that `main` lacked
before the build is proven where that API first existed without its behavior:

```bash
until ! pgrep -f 'swiftgate-mutate-sel[f]-' >/dev/null; do /bin/sleep 30; done
"$SG" build proof-bases <slug>
"$SG" check --tier ready <the --proof-base arguments it printed>
```

`build proof-bases` exits 2 when a merged task has no stored return: halt, since the final gate
can't prove that task's tests. Record the final gate whatever its verdict, so the ledger page
shows it: `"$SG" build record-gate <slug> --kind final --run-id <its run id> --session <session> --json`.

Keep its verdict and run id for the report. Not GREEN: halt, and quote its findings. Options:
**finish anyway** (Recommended when every finding is outside this plan's write sets), or **stop**,
which leaves the index at `building`.

Then the `validate` stage prints `validate: not configured` and passes, and
`"$SG" build finish <slug> --session <session> --json` sets the index to `done` when every task is
`done`, or leaves it `building` with a `resume` note. Its `unfinished` list goes in the report.

## Resume

`build start` exits 1 when the index is already `building`. `build next` reads the plan's newest run,
so resume from step 2 with that `runId`. A task left `in-progress` has no workflow in this session:
ask whether to retry it (`ledger set … pending`, then launch into its existing worktree) or abandon
it. Restart the cutoff timer from `run.json`'s `startedAt`.
