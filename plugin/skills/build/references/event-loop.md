# The build event loop in detail

The long form of the build skill's steps. `<slug>`, `<preset>`, `<session>`, `<plans>`, `<run>` and
`<returns>` mean what the skill's table says. `SG="${CLAUDE_PLUGIN_ROOT}/bin/swiftgate"`.

Contents:

- [State this skill keeps](#state-this-skill-keeps)
- [Launch](#launch): the workflow's args
- [Returns](#returns): where each file goes
- [Conflict or red main](#conflict-or-red-main): undo, fixer, fix merge
- [Task halts](#task-halts): a null workflow, a failed check, `gate-red`, `review-blocked`
- [Design conflict](#design-conflict)
- [Time budget](#time-budget)
- [Final gate](#final-gate)
- [Resume](#resume)

## State this skill keeps

Keep these in the conversation; none of them is a file:

- per running task: its Workflow task id, `worktree`, `branch`;
- the tasks set aside by a halt or a design conflict, which the loop never starts again unless the
  user says retry;
- the order tasks merged in, for the fixer's second return;
- the ledger page's file path, `.harness/design-render/<slug>-ledger.html`.

Every other fact comes from `swiftgate`: the ledger from `<plans>/<slug>/ledger.json`, the preset
from `<plans>/<slug>/build/<run>/run.json`, the running set from `build next`.

`<plans>` must stay repo-relative when a command takes it as a path: `context-pack` refuses an
absolute path. From the main checkout's toplevel, `git rev-parse --git-common-dir` prints `.git`.

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
    review: "<full|gate>"
  }
})
```

- `taskGate`: the preset's `taskGate` when it names a tier; under `ledger`, the task's own `gate`.
- `model`: the task's `model` when the preset's `workerModel` is `tagged`, else the preset's
  `workerModel`. `build next` refuses a task with no model to use, so one always exists.
- `review`: the preset's `review`. Leave out `reviewers`; `full` then runs both.

Unknown or missing args make the workflow throw `build-task: …` at once: that is a skill bug, so fix
the args and relaunch, and don't count it as the task's attempt.

The workflow runs in the background. Its completion arrives as a notice with its result. Go on
with other tasks, or end the turn to wait; never poll.

## Returns

1. Write the workflow's return, byte for byte, to `.harness/build/<run>/<task>.json`.
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
  `main` again. GREEN: go on to `ledger set … done` as for a clean merge. `worktree remove` then
  removes the task worktree; the fix worktree and branch stay, so name them in the report.
- Anything else, or a red gate after the fix merge (undo it first with `--undo`): halt, and
  set the task `blocked`. Options: stop the build (Recommended), abandon this task and go on, or
  leave it blocked and go on with the rest.

## Task halts

A null or thrown workflow, a return that fails `check-return`, and a `gate-red` or `review-blocked`
outcome each halt that task alone. The workflow already spent its 1 fix pass.

1. `"$SG" ledger set <slug> <task> blocked --session <session> --json`, and set the task aside.
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
2. Set aside every `pending` task whose `covers` intersects `ids`, and every task that depends on a
   blocked one. The ledger can't move a `pending` task to `blocked`, so the loop skips them when
   `build next` lists them.
3. Ask once, quoting `section: claim` and the ids. Options: **stop** (Recommended), **drop** the
   blocked tasks (`ledger set … abandoned`), or **retry** them (`ledger set … pending`, then relaunch
   into their existing worktrees). The workflow args carry no note, so a retry with a note means the
   user edits the design or the plan first.

`amend`: set the reporting task `blocked`, set aside the tasks step 2 names, and run the amend flow
with the Skill tool: `swift-harness:design` with `--amend <slug>`. It marks the affected tasks
`needs-replan`. The other tasks keep building; the report names the `needs-replan` tasks, which wait
for `/swift-harness:plan`.

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

Only 1 `ready` tier runs at a time on this machine. Wait for the others in the foreground first:

```bash
until ! pgrep -f 'swiftgate-mutate-sel[f]-' >/dev/null; do /bin/sleep 30; done
"$SG" check --tier ready
```

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
