# The build event loop in detail

The long form of the build skill's steps. `<slug>`, `<preset>`, `<session>`, `<plans>`, `<run>` and
`<returns>` mean what the skill's table says. `SG="${CLAUDE_PLUGIN_ROOT}/bin/swiftgate"`.

Contents:

- [State this skill keeps](#state-this-skill-keeps)
- [Worker pack](#worker-pack): what `context-pack --role worker` derives itself
- [Launch](#launch): the workflow's args
- [Validation task](#validation-task): the 1 task that commits nothing
- [Returns](#returns): where each file goes
- [Merge queue](#merge-queue): 1 merge at a time, in `build next`'s order
- [Merge gate watch](#merge-gate-watch): a background merge gate and its deadline
- [qa run watch](#qa-run-watch): a background `--at-base` or before-merge `qa run`
- [Conflict or red main](#conflict-or-red-main): undo, fixer, fix merge
- [Before each merge](#before-each-merge): the validation rows a merge makes ready
- [Flow repair](#flow-repair): a flow row its own flow file keeps red, rewritten once
- [No repair](#no-repair): `build no-repair` amends the contract or merges with the row unverified
- [Recording halts](#recording-halts): `build halt` and `build resume` for every halt
- [Recording usage](#recording-usage): `events ingest` at each completion
- [Task halts](#task-halts): a null workflow, a failed check, `gate-red`, `review-blocked`
- [Design conflict](#design-conflict)
- [Stall watch](#stall-watch): a worker that stops without returning
- [Time budget](#time-budget)
- [Final gate](#final-gate)
- [Validate stage](#validate-stage): simulator QA under the preset's `sim_qa`
- [Resume](#resume)

## State this skill keeps

Keep these in the conversation; none of them is a file:

- the plan's source (its design doc, or its spec page) and its plan surface, from `plan.json`;
- per running task: its Workflow task id, its stall watch's task id, `worktree`, `branch` and
  `<transcripts>`, the transcript directory the Workflow tool printed;
- the merge gate's Bash task id while it runs;
- the order tasks merged in, for the fixer's second return;
- the ledger page's file path, `.harness/design-render/<slug>-ledger.html`.

Every other fact comes from `swiftgate`: the ledger from `<plans>/<slug>/ledger.json`, the preset
from `<plans>/<slug>/build/<run>/run.json`, the running set and the merge queue from `build next`.

`<plans>` must stay repo-relative when a command takes it as a path: `context-pack` reads an
absolute path only for `--spec-page`, and only inside the repository. From the main checkout's
toplevel, `git rev-parse --git-common-dir` prints `.git`.

## Worker pack

Build it with exactly the flags the skill's step names. A design plan:

```
"$SG" context-pack --role worker --design <doc> --ledger <plans>/<slug>/ledger.json --task-id <task> --build-run <run>
```

A spec page plan (`"source": "specPage"` in `plan.json`), with its page at
`<plans>/<slug>/<specPage.path>`:

```
"$SG" context-pack --role worker --spec-page <plans>/<slug>/spec-page.md --ledger <plans>/<slug>/ledger.json --task-id <task> --build-run <run>
```

Pass exactly 1 of `--design` and `--spec-page`; the command exits 2 on both or neither. A spec page
pack names the slices the task covers, as `<slice id>: T<n>`, where a design pack names design
sections. A page that doesn't parse, or a task covering a slice id the page lacks, exits 1 and halts
the task.

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
    taskGate: "<fast|push|ready|slice>",
    tests: ["<the task's tests>"],
    contextPack: "<absolute path of .harness/context-pack/worker-<task>.md>",
    model: "<sonnet|opus|claude-sonnet-5-5|claude-opus-5-5>",
    review: "<full|gate|classified>",
    taskProof: "<per-task|final|prove>",
    planSurface: "<plan.json's surfaceCommit, or null>",
    buildRun: "<run>",
    pluginRoot: "${CLAUDE_PLUGIN_ROOT}",
    siblings: [{ task: "<sibling>", writeSet: ["<its writeSet>"] }]
  }
})
```

In a `swiftgate run`, also pass `cutoffAt`: `deadlines.cutoffAt` from `run clock --json`, an
ISO 8601 UTC time. The worker and its fix pass get it as their deadline. Leave it out elsewhere.

- `taskGate`: the preset's `taskGate` when it names a tier; under `ledger`, the task's own `gate`.
  The workflow tells the worker to run it as `check --tier <taskGate> --base main`, with
  `--proof-base <surface commit>` when the task adds API, and adds `--prove --mutate` under
  `per-task` proof.
- `model`: the task's `model` when the preset's `workerModel` is `tagged`, else the preset's
  `workerModel`. `build next` refuses a task with no model to use, so one always exists.
- `review`: the preset's `review`. Leave out `reviewers`; `full` then runs both.
- `pluginRoot`: the absolute plugin root, required. A workflow script can't read the environment.
  Every stage runs its gate, span and diff-risk commands through `<pluginRoot>/bin/swiftgate`: a
  `swiftgate` on `PATH` may be an older installed plugin, whose gate code differs and whose runs
  no store of this build holds. The reviewers and their verifiers also open the plugin's
  `docs/standards.md` and `docs/testing-playbook.md` there. Leaving it out throws
  `build-task: pluginRoot is required`.
- `planSurface`: `surfaceCommit` from `plan.json`, or JSON `null` when the plan has none; never
  leave it out. With a sha, the worker writes no surface of its own: its task gate adds
  `--proof-base <planSurface>`, and when a test needs API the plan surface lacks it commits that API
  alone as a stub, checks it with `swiftgate surface-check <sha>`, and returns the stub as
  `surfaceCommit`. [`build proof-bases`](#final-gate) lists the plan surface first, then each stub in
  merge order. `null` leaves the worker's prompt exactly as it was before the arg existed.
- `buildRun`: `<run>`, the `runId` `build start` printed. The worker and the fix pass open and
  close their own run-viewer span in this build run from their prompt. Reviewers and verifiers hold
  no Bash, so a plain span agent started beside each runs its span, and the task returns once every
  span it opened has ended. A span call that fails never changes a stage's outcome. Leaving
  `buildRun` out throws `build-task: buildRun is required`.
- `siblings`: every other ledger task whose status isn't `done` or `abandoned` at launch, each
  as its `id` and `writeSet`; `[]` when there is none, never left out. Their code is only the
  plan's stubs on this task's branch, so the reviewers and the verifier get the list. A verified
  defect whose test could pass only once a sibling merges comes back deferred to it, not
  blocking. Leaving it out throws `build-task: siblings is required`.
- `taskProof`: the preset's `taskProof`. Under `per-task` every task proves and mutates its own
  change, and `build check-return` fails a worker's green gate that skipped either. Under `final`
  no task gate does, and the [final gate](#final-gate) proves and mutates every merged task once.
  Under `prove`, the brownfield preset's, each task gate proves its changed tests and never mutates.
- Under the brownfield preset, whose task gate is `slice`, also pass `stateRoot`, the worktree's
  `$(git -C <worktree> rev-parse --absolute-git-dir)/swift-harness`, and `base`, the plan branch
  the task branched from. The worker writes `task-status.json` and reads its runs there, where
  `build check-return` looks. `model` must be a pinned id. `classified` review takes its depth
  from `swiftgate judge diff-risk --base <base> --json` after the first green gate: `low` the gate
  only, `medium` 1 Sonnet reviewer, `high` the full review. With no level it runs at `medium` and
  says why in the log and the return's `notes`.

Unknown or missing args make the workflow throw `build-task: …` at once: that is a skill bug, so fix
the args and relaunch, and don't count it as the task's attempt.

The workflow runs in the background. Its completion arrives as a notice with its result. Go on
with other tasks, or end the turn to wait; never poll.

## Validation task

A design plan's decomposer adds 1 validation task when 2 or more tasks build UI. Its write set is
`.harness/qa/<slug>/`, which no commit carries, so it never merges and never runs the build-task
workflow. `build next` lists it first, ahead of every other ready task: a merge that makes a
row ready can't land until its `--at-base` run is done. When `build next` lists it, run `worktree create`, the pack and `ledger set … in-progress`
as for any task, then launch 1 Agent tool call in the background, passing
`run_in_background: true`, with `subagent_type` `general-purpose` and `model` `opus`. Its prompt names the task's worktree and id, `<slug>` as its
plan, its rows (the `validation.json` rows whose `writer` is the task), its context pack, the plan
surface, and says to work in that worktree and follow
`${CLAUDE_PLUGIN_ROOT}/skills/qa/references/validation-worker.md`. When it returns:

1. `"$SG" qa adopt <worktree> --session <session> --json` copies its `.harness/qa/<slug>/` into
   `<plans>/<slug>/qa/`, where `qa run` reads every check. A non-GREEN adopt halts that task. Its
   `unblocks` lists each checked return that waited on this task, with the exact `build merge`
   command as `next`.
2. `/bin/rm -rf <worktree>/.harness/qa`, then
   `"$SG" ledger set <slug> <task> done --session <session> --json` and
   `"$SG" worktree remove <slug> <task> --session <session> --json`.
3. Confirm each check fails before its tasks merge:
   `"$SG" qa run --plan <slug> --at-base --json --output <plans>/<slug>/out/qa-at-base.json`, in
   the background under the [qa run watch](#qa-run-watch). This `--at-base` run is never skipped,
   and no row's pass counts before it has run: `build merge` refuses `at-base-unchecked` for a
   merge that makes a row ready until this run took the row. A task whose rows all still wait on
   other tasks merges without waiting for it. It takes each row the worker's `--prepared-by` run proved from
   the `at-base-run.json` the adopt copied while its check is byte-identical, naming that run in
   the row's `reusedFrom`, and runs only the rest. A row that reads `pass` there gets `qa.check-passes-at-base`: its check can't
   tell the change from its absence. Name it in the report, and go on. A row that reads
   `unverified` there has no red run behind it, whatever the worker returned: name it in the
   report as `no red run` with its message.
4. After every adopt and its `--at-base` run, run
   `"$SG" build next <slug> --session <session> --json` before ending the turn, and merge the first
   task in its `readyToMerge` while `merging` is absent, as the adopt's `unblocks` named. The next
   worker notice may be many minutes away.

Its `missing:` lines name contract names a check needed: each goes in the report, and its row
reads red until a task adds the name.

## Returns

1. Write the workflow's return, byte for byte, to `.harness/build/<run>/<task>.json`. Take it from
   the `result` key of the task's output file, the path the completion notice names. The notice
   text HTML-escapes the return, so `->` arrives as `-&gt;`, and a copy of it is corrupt. In a
   brownfield run that path is under the plan checkout: the hook denies a run's write to the
   user's checkout as `guard.run-user-checkout`. The check measures the task branch against the
   branch tasks merge into, from whichever checkout runs it.
2. `"$SG" build check-return .harness/build/<run>/<task>.json --plan <slug> --session <session> --json`.
   Exit 0 is `verdict` GREEN. Exit 1 lists `findings` as `{rule, message}`: the return claims more
   than git or the run store shows. Exit 2 means the file is unreadable or isn't a task return,
   or it couldn't store a passing return.
3. Exit 0 has stored the same bytes in `<returns><task>.json`, replacing any earlier return of
   the task, and the report's `stored` names that file. Never copy, move or write a return into
   `<returns>` yourself. It stores a `design-conflict` return too: that carries the conflict report.

A return's `notes` line `deferred to <sibling>: <severity> <file>: <title>` is a verified review
finding whose test can pass only once that sibling merges. It never blocks: the return merges as
usual. Keep each line, and quote it in the report under deferred findings, naming whether the
sibling merged. A retry of either task quotes it in its brief.

`check-return` stores no return that fails the check, and no fixer's return, so no dependent
pack quotes its notes.
`context-pack --build-run` exits 1 when a dependency's return is missing, so a dependent can't
start from a return this skill skipped.

## Merge queue

Merges land on `main` 1 at a time: `build merge --undo` takes back only the newest merge, so a
second merge on top of an ungated one would block its undo. `build next` reports the queue.
`merging` is the merge on `main` whose task isn't done yet. `readyToMerge` lists each running task
whose checked return waits to merge, in the order `build check-return` passed them, with
`fix: true` for a fixer's return, which merges with `--fix`. A task whose halt was answered `retry`
after its return was checked is in `fixing` instead, until its fixer's return is checked. Merge the
first task in `readyToMerge` only while `merging` is absent. A task merges without waiting for
the `--at-base` run unless its merge makes a validation row ready; `build merge` refuses that one
`at-base-unchecked` until the run is done.

A task whose return `build check-return` passed, or whose merge is on `main`, holds no slot: its
worker is done, so `build next` starts another task in its place. Its write set stays reserved until it
merges, so no task that overlaps it starts. The validation task never holds a slot: it runs beside
`max_parallel`, so it never delays a build task.

## Merge gate watch

A merge gate can hang, so it never runs as a foreground call with no deadline. After each merge,
`mkdir -p <plans>/<slug>/out`, then:

1. Launch the gate with `run_in_background: true` and keep its Bash task id:
   `"$SG" check --tier <mergeGate> --json > <plans>/<slug>/out/merge-<task>.json`, or for a plan
   with a surface
   `"$SG" check --tier <mergeGate> --base <surfaceCommit> --json > <plans>/<slug>/out/merge-<task>.json`.
   Step 2's `"$SG" build gate-wait` holds the turn in the foreground while it runs.
2. In the foreground, with the Bash tool's `timeout` at 600000:
   `"$SG" build gate-wait <slug> --tier <mergeGate> --output <plans>/<slug>/out/merge-<task>.json --session <session> --json`.
   It budgets the gate from the tier's recent runs, or from the warm-up's build and test times
   before the first one, waits up to 2 minutes and prints an `action`:

- `read`: the gate wrote its JSON. Read its `verdict` and `runID` from the output file, and go on
  as the table below says for its verdict.
- `wait`: the gate is inside its deadline. Handle any completion notice that arrived, checking
  its return so it joins the queue, then run `build gate-wait` again. Never end the turn while the
  gate runs, and never wait on it another way, such as a sleep: a headless session that ends its
  turn kills the gate.
- `worker-returned`: a Workflow run of this session ended while the gate ran; `returned` names
  its task. Its completion notice arrives with this result: check its return so it joins the
  queue, then run `build gate-wait` again.
- `overrun`: the gate passed its deadline, 3 times its expected time. `TaskStop` its Bash task and
  treat it as a RED merge gate whose finding is the watch's `message`:
  `"$SG" build halt --run <run> --task <task> --reason gate-red`, then
  `"$SG" build merge <slug> <task> --undo --session <session> --json`, then
  `"$SG" build resume --run <run> --task <task> --answer retry` and the fixer below. Before
  anything else, run `build next` and merge the first task in its `readyToMerge`: a task queued
  behind the slow merge lands first, and the slow one comes back through its fixer.
- `cutoff`: a `swiftgate run`'s cutoff passed with the gate still running. Run `build cutoff` as
  the run skill says, then `build gate-wait` again.

## qa run watch

A `qa run` with flow rows holds a device for minutes, so the `--at-base` run and each
before-merge run go in the background, and a worker's return never waits behind one. Run 1 at a
time: a second borrows the same device and only queues.

1. `mkdir -p <plans>/<slug>/out`, then `/bin/rm -f <file>` and launch the run with
   `run_in_background: true`, its report going to `--output <file>`, where `<file>` is
   `<plans>/<slug>/out/qa-<name>.json` and `<name>` is `at-base` or the run's task list. The run
   makes the file new and empty as it starts and writes its report there as it ends.
2. In the foreground, with the Bash tool's `timeout` at 600000:
   `"$SG" build gate-wait <slug> --qa --output <file> --session <session> --json`. It budgets
   the run from the newest runs' rows and prints an `action`, as for a merge gate:

- `read`: the run wrote its report. Read its `verdict`, `rows` and `runID` from the file and go
  on as the step that launched it says.
- `wait` or `worker-returned`: check any return whose notice arrived, so it joins the queue,
  then run `build gate-wait --qa` again. Never end the turn while the run goes on: a headless
  session that ends its turn kills it.
- `overrun`: `TaskStop` its Bash task. Its rows are unchecked: launch it once more, and treat a
  second overrun as a RED run whose finding is the watch's `message`.
- `cutoff`: run `build cutoff` as the run skill says, then `build gate-wait --qa` again.

## Conflict or red main

The merge gate is the preset's `mergeGate`. Run it on `main` after every clean merge, as the
[merge gate watch](#merge-gate-watch) says, with `--base <surfaceCommit>` for a plan with a
surface. From `origin/main`, the surface's stubs would read as untested changes in
every merge; from the surface, the gate judges what the merged tasks changed on top of it.

The start's green-main check may leave a baseline: its findings when the user chose **go on**, or,
for a plan with a surface, the `coverage.no-t1-tests` findings for modules the surface added, taken
without asking. Compare the gate's gating findings with that baseline by `rule`, `file` and
`message`. A gate whose every gating finding is one of the baseline's counts as GREEN. Anything new
is a red gate, and the fixer gets only the new findings.

| What happened | Next |
|---|---|
| `build merge` exits 1 with `status` `conflicted` | `main` is untouched, and the fix worktree is cut |
| the merge gate is RED | `"$SG" build merge <slug> <task> --undo --session <session> --json` resets `main`, records that gate run as the task's merge gate (`gateRunId`) when `build record-gate` hasn't, and cuts the fix worktree |
| the merge gate is BLOCKED | it couldn't finish, such as a prove the time left couldn't hold, so nothing proved the merge red: run it again once, as the [merge gate watch](#merge-gate-watch) says. A second BLOCKED is a RED gate, except for a task `build cutoff` said to finish: `--undo` refuses it, so leave it merged and name the gate in the report |
| `build merge` exits 1 with another `reason` | halt: `main-moved`, `dirty-checkout` and `not-on-main` need the user; `already-merged` means the ledger lags, so run `ledger set … done` and go on |
| `build merge` exits 1 with `return-unchecked`, `return-not-green` or `return-stale` | the return's newest `check-return` is missing, failed, or checked an older tip: check it again, and merge only after that check exits 0; a check that won't pass halts the task |
| `build merge` exits 1 with `review-blocked-unanswered` | the return is `review-blocked`: halt the task as [Task halts](#task-halts) says. Only the person's **merge as is** lets it merge |
| `build merge` exits 1 with `flows-unchecked` or `flows-red` | run [before each merge](#before-each-merge)'s `qa run`, or send its red rows to the fixer in the fix worktree `flows-red` cut |
| `build merge` exits 1 with `at-base-unchecked` | the `--at-base` run hasn't taken the rows it names: merge once that run is done. Start it if it isn't running |
| `build merge --fix` exits 1 with `fix-carries-unmerged` | merge the tasks it names first, then the fix |
| `build merge` exits 2 | halt |

An `--undo` that exits non-zero halts: `main` may still hold the red merge. Quote its `reason`.

Then the fixer, 1 attempt. Open its span first, a fix pass inside the task as the workflow's own
fix pass is: `"$SG" events span start --phase fix --build-run <run> --task <task> --role build-worker`,
kept as `<span>`.

Launch `swift-harness:build-fixer` with the Agent tool in the background, passing
`run_in_background: true`, as every worker and fixer launch does: a foreground call blocks every
merge and start until it returns. Keep `<agent>`, the id the launch result names in its
`agentId: <agent>` line. Give it:

- the plan slug and the task id;
- `fixWorktree` and `fixBranch` from the `build merge` JSON;
- the case: `conflicted` with `conflictedFiles`, or a clean merge that turned the merge gate red;
- both returns: this task's, and that of the task it collides with, read from `<returns>`. For a
  conflict, that's the merged task whose `writeSet` holds a conflicted file; otherwise, or when none
  does, the task merged last;
- the tier its return must meet: the merge gate in an owned project, the task gate in a
  brownfield clone, where its branch tip lacks every task merged since and the merge gate after
  `build merge --fix` gates the merged tree; and `--base <surfaceCommit>` for a plan with a
  surface, so its gate in the fix worktree measures from where `main`'s gates do;
- the absolute path `$SG` holds, the plugin under test's `bin/swiftgate`, to run its gate and every
  other `swiftgate` command through: a `swiftgate` on `PATH` may be another install, whose runs no
  store of this build holds;
- that the gate run it returns must start at its last commit on a clean tree: commit first, then
  gate. `check-return --fix` rejects any other run as `build-return.stale-gate`;
- that it iterates on `"$SG" test-only --area <area> <Target>/<Class>` for a failing test in a
  brownfield clone, or `"$SG" check --tier fast` in an owned project, and runs that tier only to confirm a fix that
  passes there, plus, for red rows, `qa run --after <task> --before-merge --fix`, its JSON
  written with `--output .harness/tmp/qa-<task>.json` and read by its `summary`, never piped
  through `head` or `tail` (`guard.qa-run-truncated`) nor wrapped in `timeout`
  (`guard.qa-run-timeout`): `--deadline` bounds it. Its fix worktree gets at most 3 full-gate runs, and the hook denies the next
  (`guard.fixer-gate-cap`);
- that after 2 red `qa run`s of the same flow row it stops and returns `gate-red` with that row's
  evidence: its requirement, the failing step and its message, and both run ids. It writes them
  as 1 `flow row:` line per row at the end of its notes, with `flow-side: yes` or `no`. It never reads
  `agent-device`'s source and never writes probe tests to learn why a step fails. Its `gate-red`
  return then takes the path below like any other, quoting the row's evidence;
- that a red from the fake's timing or call count goes to the fake or the flow, never the app's
  behaviour. Each behaviour it adds to the app anyway, such as a cooldown, debounce or guard,
  ends its notes as 1 `assumption: <behaviour>: <why>` line. For such a row, name the fake
  and what it counts or how fast it answers; never ask for an app change that makes 1 gesture load
  once;
- in a `swiftgate run`, the `cutoffAt` time `run clock` reports, as its deadline: it starts no
  gate or `qa run` it can't finish by then, and at that time returns what it has, with `gate`
  `null` when no gate ran on its last commit.

Go on with other tasks, or end the turn to wait; never poll. When its completion notice arrives,
end the span by its outcome: `"$SG" events span end <span> --outcome ok` for `ready-to-merge`,
else `"$SG" events span end <span> --outcome red`.

Then record its usage under the task it fixed:
`"$SG" events ingest --session <session> --agent-id <agent> --role build-fixer --task <task> --build-run <run>`,
with the `<agent>` its launch named. The fixer is
this session's own subagent, which the session's own ingest files as `build-fixer` with no task,
so run this one first. As at each completion, an exit 2 that says `telemetry is off` means say nothing, and any
other non-zero exit prints 1 line for the report and the step goes on.

Write its reply, the notice's `<result>`, to `.harness/build/<run>/fix-<task>.json` and check it.
The notice HTML-escapes it: turn `&lt;`, `&gt;` and `&amp;` back into `<`, `>` and `&`, and never
read the output file the notice names, which is the fixer's whole transcript:
`"$SG" build check-return .harness/build/<run>/fix-<task>.json --plan <slug> --fix --session <session> --json`.

- In a `swiftgate run`, add each `assumption:` line of its notes as 1 bullet under `PLAN.md`'s
  `## Assumptions`, whatever its outcome.
- The check passes and `outcome` is `ready-to-merge`: wait until `build next` lists it in
  `readyToMerge` with `merging` absent. With a `validation.json`,
  `"$SG" qa run --plan <slug> --after <task> --before-merge --fix --json --output <plans>/<slug>/out/qa-<task>.json` first, as
  [before each merge](#before-each-merge) says. A flow row RED there goes to
  [flow repair](#flow-repair) with `--cause still-red`, and any other RED one halts as below. Then
  `"$SG" build merge <slug> <task> --fix --session <session> --json`, as its own command after the
  check exits 0 (it refuses a fix whose newest `--fix` check isn't GREEN at the fix branch's tip),
  then the merge gate on
  `main` again. Watch it and record it with `build record-gate --kind merge --task <task>` like the first.
  GREEN: go on to `ledger set … done` as for a clean merge, and after the task's
  `worktree remove`, remove the fix worktree and branch too:
  `"$SG" worktree remove <slug> <task> --fix --session <session> --json`.
- `outcome` `gate-red` with a `flow row:` line in its notes, whatever `build check-return`
  said: [flow repair](#flow-repair) first. It halts as below only when `qa adopt --repair`
  refuses the repair or the row's 1 repair already ran. A `no repair:` answer goes to
  [no repair](#no-repair).
- `outcome` `gate-red` with commits but no gate verdict is an unconfirmed fix: `haltAdvice.answer`
  `verify`, a `gate` that is `null` or BLOCKED, or notes saying the fixer ran out of time to
  confirm it. Nothing proved it red, so it gets no halt, and it is never set `blocked` on time
  grounds. Verify it yourself in its fix worktree:
  1. `"$SG" check --tier <taskGate> --base main --json > <plans>/<slug>/out/fix-<task>-gate.json`
     on its clean tip, in the foreground with the Bash tool's `timeout` at 600000.
  2. Write the return again with that run as its `gate`, and `outcome` `ready-to-merge` for a GREEN
     run or `gate-red` for a RED one, then check it:
     `"$SG" build check-return .harness/build/<run>/fix-<task>.json --plan <slug> --fix --session <session> --json`.
  3. A GREEN check goes on as the `ready-to-merge` bullet says, from
     `"$SG" qa run --plan <slug> --after <task> --before-merge --fix --json --output <plans>/<slug>/out/qa-<task>.json`. A RED gate, or a
     second BLOCKED one, takes the bullet below.

  Verifying starts no task, so no new starts doesn't stop it. When the cutoff comes first,
  `build cutoff` decides the task as it decides any other.
- Anything else, or a red gate after the fix merge (undo it first with `--undo`): halt, and
  set the task `blocked`. Options: leave it blocked and go on with the rest (Recommended),
  abandon this task and go on, or stop the build. Before `cutoffAt`, stop is never recommended:
  1 task's halt leaves the rest of the plan's work to merge.

## Before each merge

A plan with a `validation.json` runs the rows a task's merge makes ready before `build merge`,
once the [merge queue](#merge-queue) lists the task first, on the task's branch merged into
`main`'s tip in a scratch tree, from the main checkout, in the background under the
[qa run watch](#qa-run-watch):

```
"$SG" qa run --plan <slug> --after <task> --before-merge --json --output <plans>/<slug>/out/qa-<task>.json
```

It runs only the rows whose `Runs after` names `<task>` and whose other tasks are merged, in layer
order: acceptance, then flow, then state, on 1 held device. `main` doesn't move. A red row stops
its own requirement's later layers, never another requirement's (simulator QA amendment §6).
`build merge` refuses `flows-unchecked` while a ready row has no such run GREEN at the branch's
tip on `main`'s commit, so run it again after a commit to the branch. After another merge moves
`main`, `build merge` still takes a run whose trial merge made the very tree this merge lands, as
`merged-tree-run.json` beside its report names it: the code is identical, so merge again before
running anything. Any other change to `main` needs the run again. A run whose trial merge makes
the same tree as an earlier one in any checkout, a fixer's slot included, takes the rows that
passed there with byte-identical checks, naming that run in `reusedFrom`, so repeating a fixer's
passing run costs seconds.

Merge each task as soon as its own rows are GREEN. A row whose `Runs after` names a task that
hasn't merged doesn't hold the others: `build merge` lands each of them on the rows it owns, with a
note naming the rows still waiting, and the row runs before the last of its tasks lands, on that
task's own trial merge. Never hold a ready task for another task's return, and never start a
run over several branches to batch them. One that exists still counts:

```
"$SG" qa run --plan <slug> --after <task>,<other>,… --before-merge --json --output <plans>/<slug>/out/qa-<task>.json
```

Its passes credit the tasks it took, and a RED row refuses the tasks that row's `Runs after`
names, as below.

- RED over several tasks: a red row refuses only the tasks its `Runs after` names. Pick the one
  that owns the red behaviour: the one whose write set holds the screen, state or code each red
  row's message points at. When unsure, take the task the row's `Runs after` names last. Run
  `build merge` for it first: it refuses `flows-red` and cuts its fix worktree with the row's other
  unmerged branches merged in at the run's tips, so the fixer may edit their files too, and the
  halt and fixer follow as below. The fixer reruns the same run with that task first and `--fix`.
  Then merge the other tasks: with the owner set aside, they merge on the rows they own.
  `build merge --fix` refuses `fix-carries-unmerged` until each task its fix branch took in has
  merged on its own, or was abandoned: then the fix lands that task too, names it in `carried`,
  marks it `done`, and needs a GREEN run over both first.
- A red row whose screen belongs to a task already merged: the fixer of the task the row is
  pinned on may edit that merged task's write set too, since its rows ran red after it. Name the
  merged task and the screen's files in the fixer's prompt. `check-return --fix` takes those
  edits as inside the write set; never rewrite a fixer's notes to get a return through.
- GREEN: merge. Rows that read `unverified` or `waiting` go in the report with their messages.
  A branch that conflicts with `main` runs no row and names the files: merge, and the conflict
  goes to the fixer as any conflict does.
- RED: `build merge` refuses `flows-red` and cuts the fix worktree with the task merged in,
  `main` untouched, as for a conflict. It is a halt answered by rule:
  `"$SG" build halt --run <run> --task <task> --reason gate-red`, then
  `"$SG" build resume --run <run> --task <task> --answer retry`, then the fixer as for a red
  merge gate, given each red row's `requirement`, `layer`, `check` and `message` from the JSON.
  The fixer's branch runs it again with `--fix` before `build merge --fix`. Never merge on your
  own judgement: a row red at the newest `--at-base` report too goes to the fixer like any other.
- Exit 2 (BLOCKED): the table, the ledger or the scratch tree failed. Keep its `message` for the
  report; `build merge` keeps refusing until a run is GREEN, so a second BLOCKED halts the task.

## Flow repair

A fixer's `flow row:` line names a flow row 2 `qa run`s left red. Its flow file is plan state,
which neither the fixer nor this skill edits, so a validation worker in repair mode rewrites it.
The cause is `flow-side` when the line says `flow-side: yes`, and `still-red` for `flow-side: no`
or a row red again after a fixer's `ready-to-merge`. A row gets up to 2 adopted repairs per run,
the second only before `noNewStartsAt`: `qa adopt --repair` refuses any other with
`qa.repair-cap`. A repair is no halt, so record none.

Repair 1 requirement per round. With several `flow row:` lines, run a round for each, 1 after
another in the same fix worktree, starting with the row whose step failed first.

1. Fill the fix worktree's prepared folder with this requirement's adopted checks alone, its flow
   and state rows' files:
   `"$SG" qa stage <fixWorktree> --plan <slug> --requirement <requirement> --json`. It empties
   `<fixWorktree>/.harness/qa` first. Never copy a plan state file yourself. A non-GREEN stage
   halts that task.
2. Launch 1 Agent tool call in the background, passing `run_in_background: true`, with
   `subagent_type` `general-purpose` and `model` `opus`. Its prompt names the fix worktree as its
   worktree, `<slug>` as its plan, the rows' `writer` as its task id and the requirement's rows from
   `validation.json`. It quotes the `flow row:` line, both red run ids and the evidence paths their
   `qa/report.json` rows name, and says to follow the repair mode of
   `${CLAUDE_PLUGIN_ROOT}/skills/qa/references/validation-worker.md`, which runs the at-base proof
   itself. Never prescribe the edit: the fixer's suggestion, such as an `is` in place of a `wait`,
   can weaken the check. Record its usage as for the validation task, under the task the row
   runs after.
3. On a `repaired:` return, from the main checkout:

   ```
   "$SG" qa adopt <fixWorktree> --repair <requirement> --build-run <run> --cause <cause> --reason "<why>" --red-run <run id> --red-run <run id> --json
   ```

   `<why>` is the `flow row:` line's reason, on 1 line. Then `/bin/rm -rf <fixWorktree>/.harness/qa`.
   - GREEN: go on to the next requirement's round, if any. Once every round is taken, launch the
     fixer again, 1 more attempt with its own span, ingest and check, given its last return and
     each adopt's `repaired` record. It runs the before-merge `qa run --fix` again and returns
     `ready-to-merge` once its rows are GREEN, which merges as above. A `flow row:` line for a
     repaired row in that return takes a second round while `run clock` is before
     `noNewStartsAt`, and halts after it.
   - RED, before `cutoffAt`: no halt, and never stop the build. Launch the repair worker again
     for that requirement, its prompt quoting each finding's message as written, since each says
     what would pass, and adopt again. A refused adopt records no repair, so this retry isn't
     capped; `build cutoff` decides the task when the cutoff comes first.
   - A `no repair:` return: [no repair](#no-repair) decides it.
   - A RED adopt after `cutoffAt`: halt as the fixer's `Anything else` bullet says, quoting the
     findings.

## No repair

A repair worker's `no repair: <requirement>: <why>` says no flow can pass the row: the fix needs
a contract name the app doesn't have (`contract gap: <name>:` opens its reason), or the app is at
fault. Write its reply to `.harness/build/<run>/no-repair-<task>.txt` and decide it, from the
main checkout:

```
"$SG" build no-repair <slug> <task> --reply .harness/build/<run>/no-repair-<task>.txt --qa-run <red run id> --fix-return .harness/build/<run>/fix-<task>.json --session <session> --json
```

`<red run id>` is the fixer's newest red before-merge run, read from any checkout of the clone,
the fixer's slot included; so is the run `build merge --fix` credits. Quote its `why`. It never answers stop
the build. Its `action`:

- `amend-contract`: a contract gap with time before `noNewStartsAt` for the repair's proof and
  the fixer's run. No halt. In the fix worktree, add the name to the contract, a `held` scenario
  for an in-flight state, or for a screen whose state advances on a clock a `held` scenario whose
  clock starts at the first input or a seeded one that places an entity, as the contract step
  shapes it, and commit it on the fix branch. Then
  take the requirement's [flow repair](#flow-repair) round again from step 1, its prompt naming
  the new name, and launch the fixer again once it adopts; its brief says to name each file that
  commit changed in its notes, since `check-return --fix` passes a fixer's edit outside its write
  set only when its notes name it.
- `merge-unverified`: the fixer's gate is GREEN and every other row of the run passed. The
  command recorded `rows` as left unverified: `build merge --fix` takes a run red on those rows
  alone, and the final `qa run` reports them `unverified` with the reason, unrun.
  `build halt --reason gate-red`, `build resume --answer merge`, then
  `"$SG" build merge <slug> <task> --fix --session <session> --json` and its merge gate, as a
  fixer's `ready-to-merge` merges. A `flows-unchecked` refusal names the run to make first.
- `continue`: halt with `gate-red`, set the task `blocked`, and resume with `continue`.

## Recording halts

Every halt after `build start` gets 1 `build halt` before the question and 1 `build resume` after
the answer, so the wait from halt to answer is data. A halt nobody answers stays open in the
events, which is the point: it shows how long the build sat. Pass `--task <task>` for a halt about
1 task, and leave it out for a halt of the whole run; the resume names the same task, since it
answers only the newest open halt of that run and task. `build resume` exits 1 and writes nothing
when no halt is open for them. Only ids and the closed values below go in: never the question,
the findings or the answer's words.

| Halt | `--task` | `--reason` |
|---|---|---|
| a stall watch fires | the task | `stall`, or `permission` when the last tool call waits on a permission prompt |
| a `gate-red` return, a `build no-repair` decision that merges or goes on, or the fix merge's gate still red | the task | `gate-red` |
| a RED `qa run --before-merge`, resumed with `retry` before its fixer | the task | `gate-red` |
| the fixer's merge still conflicted | the task | `merge-conflict` |
| a `design-conflict` return | the reporting task | `amend` |
| the time budget's cutoff with tasks running | none | `budget` |
| the final gate not GREEN | none | `gate-red` |
| the validate stage RED | none | `gate-red` |
| any other halt: a null workflow, a failed check, `review-blocked`, a `build merge` or `--undo` exit, `proof-bases` exit 2, a resumed `in-progress` task | the task, when there is one | `question` |

| Option the user picks | `--answer` |
|---|---|
| retry, stop and retry | `retry` |
| wait | `wait` |
| abandon, drop, stop the build, stop them now, stop | `abandon` |
| an amend through the design skill | `amend` |
| go on, go on without it, leave it blocked, let them finish, finish anyway | `continue` |
| merge as is, merge with rows unverified | `merge` |

## Recording usage

Each completion notice, whatever the task's outcome, first runs:

```
"$SG" events ingest --session <session> --workflow-transcripts <transcripts> --role build-worker --task <task> --build-run <run>
```

It reads the token counts of the workflow's agents from `<transcripts>`, tagged with the task, and
this session's own, tagged `orchestrator`, all under `<run>`, so `events summary --build-run <run>`
prices the build by role, task and model. The merge fixer, which this session launches itself, gets
its own ingest first ([conflict or red main](#conflict-or-red-main)). Ingesting again adds nothing, so a retried task's second completion stores
only its new messages. Only ids, model ids, counts and times are kept: no transcript text or path.

Telemetry never stops the build. With `[telemetry] enabled = false` the command exits 2 and says
`telemetry is off`: the repo opted out, so say nothing and go on. Any other non-zero exit, such as a
missing session record or a malformed transcript line, prints 1 line: keep it for the report, and
go on with the completion step.

## Task halts

A null or thrown workflow, a return that fails `check-return`, and a `gate-red` or `review-blocked`
outcome each halt that task alone. The workflow already spent its 1 fix pass.

1. `"$SG" ledger set <slug> <task> blocked --session <session> --json`. `build next` never lists a
   `blocked` task, and neither does a resumed build.
2. Ask. Quote the check's findings, the return's `gate`, or the blocking review findings as
   `severity file: title`. A blocking finding has `verified: true` and severity blocker or major,
   and no `deferred to` in its `verification_note`;
   a `review-blocked` return with none names the unreviewed focus in its `notes`. Mark
   recommended the option `check-return`'s `haltAdvice.answer` names, and quote its `why`: `retry`
   for a finding a fix pass resolves (a gate to run again, a missing reason, a formatting fix, a
   flaky launch) while a retry as long as the first run fits before the cutoff and no new starts
   hasn't begun; `continue` for a design conflict or a retry the box can't hold. `verify` is no
   halt: an unconfirmed fix is checked as the fixer's return says. Options:
   - **Retry**: `ledger set … pending`, then let `build next` start it again, its brief quoting
     every finding. Its worktree and branch still exist, so skip `worktree create` and launch into
     the same worktree.
   - **Go on without it**: it stays `blocked`; its dependents never start.
   - **Merge as is**, for a `review-blocked` return only and never recommended: `build merge`
     takes it only after `build resume --answer merge` answers a halt of the task.
   - **Abandon**: `ledger set … abandoned`, then [discard its worktrees](#abandoned-task).
   - **Stop the build**: start nothing new; running tasks still merge, then [finish](#final-gate).

## Design conflict

A checked `design-conflict` return carries `designConflict` with `section`, `ids` and `claim`. The
preset's `onDesignConflict` decides. For a spec page plan, `section` is a spec page section
(`slices`, `surface` or `modules`) and `ids` are slice ids; its preset is always `block`, since a
preset with no design step can't `amend`. A `surface` conflict usually means the plan surface lacks a
target or product the task needs, which only a new surface can add.

`block`:

1. `ledger set <task> blocked` for the reporting task. For each other `in-progress` task whose
   `covers` intersects `ids`, stop its workflow with `TaskStop` and set it `blocked` too.
2. `ledger set <task> blocked` for every `pending` task whose `covers` intersects `ids`, then for
   every `pending` task that depends on a blocked one, however far down the chain. The block lives
   in the ledger, so a resumed build sees it.
3. Ask once, quoting `section: claim` and the ids. Options: **stop** (Recommended), **drop** the
   blocked tasks (`ledger set … abandoned`, then [discard their worktrees](#abandoned-task)), or
   **retry** them (`ledger set … pending`). A retried task that already had a worktree relaunches
   into it; the others start through `worktree create` as usual. The workflow args carry no note, so a retry with a note means the user edits the design
   or the plan first.

`amend`: set the reporting task `blocked`, and run the amend flow
with the Skill tool: `swift-harness:design` with `--amend <slug>`. A brownfield plan has no design:
the run skill's design-conflict step amends its `PLAN.md` instead, widening the task's write set
and retrying it. It marks the affected tasks
`needs-replan`. The other tasks keep building; the report names the `needs-replan` tasks, which wait
for `/swift-harness:plan`.

## Stall watch

A background worker can stop without returning. A permission prompt it can't show is 1 cause: the
tool call never runs, and nothing tells the orchestrator. The workflow script has no clock, so the
orchestrator watches from outside. After each launch, run this with `run_in_background`, where
`<dir>` is the transcript directory the Workflow tool printed:

```bash
d=<dir>; m=<stall minutes>; e="${d%/subagents/workflows/*}/workflows/${d##*/}.json"; while /bin/sleep 60; do [ -e "$e" ] && { echo "ended: $d"; exit 0; }; [ -z "$(find "$d" -name 'agent-*.jsonl' -mmin -$m)" ] && { echo "stalled: $d"; exit 0; }; done
```

`<stall minutes>` is `stallMin` from the newest `build next`: the preset's `stall_min`, or 15, the run viewer's stall badge too. Under a `swiftgate run`'s box, `stallMin` shrinks as the cutoff nears, to half the minutes left to the cutoff and never under 6, so a stall still leaves time to act. Every
tool call and result appends to an agent's transcript, so that long with no change means no agent in
that workflow has moved. The Workflow tool writes `workflows/<id>.json` in the session directory
once the workflow ends, so the watch stops on its own then and prints `ended: <dir>`, which needs
nothing. Keep the watch's task id beside the workflow's. When the workflow's completion notice
arrives, `TaskStop` its watch too, so it doesn't poll on until its next minute.

When a watch fires, read the last line of the newest `agent-*.jsonl` in `<dir>`. Halt, and quote its
last tool call. Options:

- **Stop and retry** (Recommended): `TaskStop` the workflow, `ledger set … pending`, and relaunch
  into the same worktree. The worker's uncommitted edits stay there.
- **Wait**: restart the watch. Pick this when the last call is a long gate, such as a `ready` tier.
- **Abandon**: `TaskStop` the workflow, `ledger set … abandoned`, then
  [discard its worktrees](#abandoned-task).

## Time budget

A `run.json` with a `timeBox` belongs to a `swiftgate run`: its box runs from the run's launch, and
the run skill decides its cutoff by rule with `build cutoff`, asking no one. Everything below is the
owned build's budget.

With `timeBudgetMin` 0 there is no budget. Otherwise, right after `build start`, start a timer: a
Bash `/bin/sleep <seconds left until startedAt + timeBudgetMin>` with `run_in_background`, which
wakes the loop when it exits. `build next` stops listing new starts on its own once `phase` is
`no-new-starts`, except for required tasks.

A task is required when its write set names a `.swift` file outside every package directory that
`.swiftgate.toml`'s `packages` globs match: that file is in the app target, and skipping the
task can leave the final gate's app build RED. Every not-done task it depends on is required too.
`build next` lists them as `required: [{task, appPath}]`, and at `no-new-starts` it still starts
them, within free slots and without write-set overlap. At `cutoff` nothing starts. Start a listed
task as usual. The ledger page shows "Required: the app target needs it to compile (`<appPath>`)"
on each one, or says why it can't tell.

When the timer fires, or any `build next` reports `phase` `cutoff`:

- Nothing running: go to the [final gate](#final-gate).
- Tasks running: halt. Options: **stop them now** (Recommended), or **let them finish** without new
  starts. A headless session stops them. To stop them: `TaskStop` each workflow, then
  `ledger set <task> abandoned` and [discard its worktrees](#abandoned-task), then go to the
  final gate. `main` stays green: every merge ran the merge gate.

## Abandoned task

Every task set `abandoned` loses its worktrees at once, merged or not:
`"$SG" worktree remove <slug> <task> --abandoned --session <session> --json`. It removes the
task's worktree and its fix worktree, whichever exist, uncommitted edits included, and keeps both
branches so their commits stay reachable. It refuses a task the ledger doesn't record as
`abandoned`.

## Final gate

Step 4 holds the `final` span open across this section, and each halt below closes it first with
`"$SG" events span end <span> --outcome halted`; a new `final` span opens after the answer.

Only 1 `ready` tier runs at a time on this machine. Wait for the others in the foreground first.
Then pass every merged task's surface commit as a proof base, so a test of API that `main` lacked
before the build is proven where that API first existed without its behavior. `build proof-bases`
prints `plan.json`'s `surfaceCommit` first when the plan has one, then each merged task's return
`surfaceCommit` in merge order, each sha once:

```bash
until ! pgrep -f 'swiftgate-mutate-sel[f]-' >/dev/null; do /bin/sleep 30; done
"$SG" build proof-bases <slug>
"$SG" check --tier ready <the --proof-base arguments it printed>
```

For a plan with a surface, the last line measures from it, as every merge gate did:

```bash
"$SG" check --tier ready --base <surfaceCommit> <the --proof-base arguments it printed>
```

`build proof-bases` exits 2 when a merged task has no stored return:
`"$SG" events span end <span> --outcome halted`, then halt, since the final gate can't prove that
task's tests. Record the final gate whatever its verdict, so the ledger page
shows it: `"$SG" build record-gate <slug> --kind final --run-id <its run id> --session <session> --json`.

Keep its verdict and run id for the report. Not GREEN: `"$SG" events span end <span> --outcome halted`,
then halt, and quote its findings. Options:
**finish anyway** (Recommended when every finding is outside this plan's write sets), or **stop**,
which leaves the index at `building`.

Then the [validate stage](#validate-stage) runs, and
`"$SG" build finish <slug> --session <session> --json` sets the index to `done` when every task is
`done`, or leaves it `building` with a `resume` note. Its `unfinished` list goes in the report.

## Validate stage

Simulator QA of the merged plan (simulator QA design §8.2, amendment §7 and §9), on `main` after
the final gate. The preset's `sim_qa` key in `.swiftgate.toml` decides it: `changed` runs it, and
`off`, or a preset without the key, prints `validate: sim_qa off` and goes on to `build finish`.

At `changed`, with a `<plans>/<slug>/validation.json`, run the final pass first:

```
"$SG" qa run --plan <slug> --final --json
```

It runs every row whose tasks merged, records each flow under the 1-slot `sim-record` lock, and
writes `.harness/runs/<runID>/qa/report.json`. A video the recorder couldn't take is a
`qa.video-unverified` nit and never fails a row. Keep `runID`, `verdict` and each row's
`requirement`, `layer`, `result` and `message`.

Then run `/swift-harness:qa`, saying it runs as a validate stage. It takes the final pass's rows
rather than running them again, drives the screens the plan changed and judges each flow with
`sim verify`. It hands nothing to `/swift-harness:tdd`, since this skill never edits code.

- GREEN from both: go on.
- RED from either, a red row, a row that never verified (`unverified` or `abandoned`, which gate
  once the build has ended) or a flow `sim verify` judged RED: halt with reason `gate-red`, and
  quote each red row as `<requirement> <layer>: <message>` and each finding as `rule: message`.
  Options: **stop** (Recommended), which leaves the index at `building` so a sprint can fix it, or
  **finish anyway**.
- BLOCKED: the QA skill already ran `doctor`. Keep its lines for the report and go on; `sim verify`
  judged nothing, so the report says QA didn't run.

## Resume

`build start` exits 1 when the index is already `building`. `build next` reads the plan's newest run,
so resume from step 2 with that `runId`. A task left `in-progress` has no workflow in this session:
ask whether to retry it (`ledger set … pending`, then launch into its existing worktree) or abandon
it. Restart the cutoff timer from `run.json`'s `startedAt`.
