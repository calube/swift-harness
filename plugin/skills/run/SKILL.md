---
name: run
description: This skill should be used by the orchestrator session that `swiftgate run <spec.md>` launches in a brownfield clone, a repository the harness doesn't own. It takes the spec to a merged plan branch with no human input — reads the spec, picks the areas it touches, runs 1 read-only explorer per area against a deadline, fixes failing command guesses through `swiftgate discover --apply`, writes the live `PLAN.md` with its assumptions, lands a contract commit on the plan branch, imports the plan, builds it with the brownfield preset, runs the `final` gate and prints the end-of-run report, all inside the run's time box, whose cutoff it decides by rule. Use when the prompt says it comes from `swiftgate run`, or names a brownfield plan slug and a spec to build.
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
| `<checkout>` | `<top>-<slug>`, where `<top>` is the user's checkout (`git rev-parse --show-toplevel` there): the worktree on `<plan-branch>` beside it, outside the git dir and the user's tree, that `run checkout create` makes and names in its JSON's `worktree`. You commit there, merges land there and gates run there. Task and fix worktrees are pooled slots beside it, `<top>-<slug>.slot-<n>`: use the `worktree` `worktree create` or `build merge` names |
| `<config>` | `<common>/swift-harness/config.toml`, written only by `discover --apply` and `allow` |
| `<session>` | the `Session id: <id>` line of the SessionStart context |
| `<run>` | the `runId` that `build start` prints in step 7 |
| `<span>` | the span id `events span start` printed for the phase open now |
| `<out>` | `<plan-dir>/out`, made with `mkdir -p` before its first use: the 1 place this run keeps a gate's or `qa run`'s JSON in a file, as `<out>/<name>.json`. Never a machine-wide temp directory, where another run's file of the same name is overwritten |

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

## Time box

A run ends inside its time box: `[build.presets.brownfield] time_budget_min` minutes from the
launch, 40 unless the config or the `--time-box <min>` option of `swiftgate run` says otherwise. The box keeps a
reserve at its end for the merges of the tasks still running, `final` and this report: starts
stop `stop_starts_before_min` minutes before the end, and the cutoff comes 5 minutes before it.
`"$SG" run clock <slug> --json` prints where the run stands: its `phase`, each deadline in
`deadlines` and the seconds to the `next` one. Read it at the start of steps 1, 3, 5, 6 and 7.

| Deadline | At 40 min | When it passes |
|---|---|---|
| `exploreBy` | 5 min | stop every explorer still running and plan their areas from your own reading |
| `planBy` | 8 min | write `PLAN.md` now from what you know, with an assumption for each open question |
| `contractBy` | 12 min | land the smallest contract that builds: fewer types, more stubs |
| `noNewStartsAt` | 27 min | `build next` starts nothing new; running tasks go on |
| `cutoffAt` | 35 min | `build cutoff` decides every running task (step 7) |
| `endsAt` | 40 min | the report is printed |

No early deadline is a reason to skip a step: past one, finish that step at its smallest and go
on. A contract with no GREEN `slice` by `noNewStartsAt` lets no task start: go to step 8 with
nothing merged.

## Foreground work

A headless run ends when a turn ends with only background Bash work left, and that work dies
with it: a gate cut short leaves no run and no verdict. On a cold cache, the first `swiftgate`
call also builds the binary, which can take minutes, so before step 1 warm it with
`"$SG" --version`. That call and every `check`, `qa run`, `build cutoff` and area command run in
the foreground, with the Bash tool's `timeout` at 600000, its longest. Never pass
`run_in_background` to one and never end one with a shell `&`.
The hook holds any other foreground call to 120 s (`guard.foreground-timeout`); one that moves
to the background reports through its notification, so keep the turn going.

The merge gates and `final` are the exception, since a hung test can hold one for an hour. Each
runs with `run_in_background: true`, its JSON redirected to `<out>`. Then `"$SG" build gate-wait`
holds the turn in the foreground until it ends or overruns its deadline, as the build loop's
[merge gate watch](../build/references/event-loop.md#merge-gate-watch) says. The `--at-base` and
before-merge `qa run`s, which hold a device for minutes, run the same way with
`--output <out>/qa-<name>.json`, watched by `build gate-wait --qa`, as its
[qa run watch](../build/references/event-loop.md#qa-run-watch) says, so a worker's return is
checked while they run.
The other background work in a run is the Workflow and Agent tool calls, which keep the session
alive until they return; no timer runs beside them. Every Agent tool call, each explorer, the validation worker and the merge fixer,
passes `run_in_background: true`: a foreground one blocks every merge and start until it returns.

## 1. Read the spec

Start the live run viewer: `"$SG" view --ensure` prints its URL, or nothing under
`SWIFTGATE_VIEW=off`. Print `Live: <url>`. It shows the build run once step 7 starts it, and step 7's
call reuses it. A failure prints 1 line for the report and never stops the run.

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

With 1 touched area, or a repository small enough to read in a few minutes, read the code yourself
and skip the explorers. That reading is planning: open step 5's phase now,
`"$SG" events span start --phase plan --build-run <slug>`, kept as `<span>`, and open no explore
span. Otherwise launch 1 `swift-harness:brownfield-explorer` per touched area with the Agent
tool, all in 1 message and in the background (`run_in_background: true`), opening the phase just
before: `"$SG" events span start --phase explore --build-run <slug>`, kept as `<span>`. Each prompt
names the area, its `root`, its commands from `<config>`, the absolute path of `<spec>`, and the
requirements that touch it. Note the time you launched them.

Each explorer has a 3-minute soft and 4-minute hard deadline and returns in 300 words or fewer.
At 3 minutes, send each explorer still running a message to return what it has now. At 4 minutes,
or at `exploreBy` if that comes first, stop any still running and drop its report: write 1
assumption naming the area and that you planned it from your own reading.

While they run, draft the plan skeleton: the contract task, 1 task per requirement or per area a
requirement crosses, their dependencies, and the goal line of each. Fill in write sets, tests and
acceptance as reports arrive.

Close the explore phase, when you opened one: `"$SG" events span end <span> --outcome ok`.

## 4. Fix the commands before planning ends

The warm-up started when discovery finished and runs every area's `generate`, `build` and `test`
at `<base>`, in parallel, to the end. Every checkout builds a `swiftpm` area in the 1 scratch path
the warm-up fills, and proves it in a scratch path of its own. Then it runs each `xcode` area's
`build` in `<checkout>`, which `swiftgate run` checked out at launch, and each `swiftpm` area's into
that checkout's prove scratch path. After that it adds `max_parallel` + 1 worktree slots, since a task
waiting to merge keeps its slot, and builds there too, so the first builds and proves in each start
warm; a build of yours there waits for its build. When `sim up` can build the app, it adds 1 more
slot and builds only the app there, kept for `qa run`'s trees. It waits for nothing and you don't wait for it either; read
what it has recorded so far with `"$SG" events list --kind warmup.run`. Each event names an
`area`, a `step`, its `ms`, `cache` and `outcome` (`passed`, `failed`, `dropped`,
`not-installed`).

- **A guessed command failed.** Find the command the repository really uses: its CI workflow,
  its task runner, its README, the explorer's working commands. Try it in `<checkout>`. When it
  works, record it: `"$SG" discover --apply --set <area>.<step>=<command>`. Repeat `--set` for
  several steps in 1 call.
- **No command works.** Drop the step: `"$SG" discover --apply --drop <area>.<step> --reason "<why>"`.
  The area keeps its other steps, and the report carries the reason.
- **A tool isn't installed** (`not-installed`, or a gate's `area.step-dropped` saying so). Drop the
  step with that reason; installing toolchains is outside a run.
- **Build-only areas.** An area whose warm test run takes longer than `slice_budget_s` in
  `<config>`'s `[brownfield]` doesn't run its whole suite at `slice`. If its `test_files` narrows a
  run to the changed tests (`{tests}` or `{files}`), `slice` still runs and proves the task's
  changed tests. Otherwise it builds only (an `xcode` area's slice runs `build-for-testing`, so its
  test targets compile), and its tests and their proof run at `merge`, which proves only the tests
  that merge brought, and at `final`. Mark it build-only in `## Areas`. An area with no warm time yet, because the warm-up is still
  running, is marked as unknown; `slice` measures it.

Never edit `<config>` by hand.

## 5. Write `PLAN.md`

Open the phase: `"$SG" events span start --phase plan --build-run <slug>`, kept as `<span>`,
unless step 3 left it already open.

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
- `## Validation` maps each requirement to the checks that prove it once its tasks merge:
  `acceptance` at a boundary, `flow` for a journey in the running app, and `state` for what the app
  stored or sent. `flow` rows exist only for screens of an `xcode` area; a repository with none
  checks at the boundary instead. A plan with any `flow` or `state` row, or any acceptance script,
  adds the validation task the reference shows, which writes those checks beside the first wave.
- A requirement whose task writes a screen or a feature of an `xcode` area has at least 1 `flow`
  row, even when an acceptance UI test also checks it, so `qa run` records its journey and proves
  it red first. A screen is a `Writes` path inside the area's root with a folder or file named
  `…View`, `…Views`, `…Screen`, `…Screens`, `…ViewController`, `…UI` or `…UITests`, or a
  `.storyboard` or `.xib`; a feature, the state a screen shows, is one named `…Feature`,
  `…Reducer` or `…ViewModel`. The contract's stubs don't count. Such a requirement no flow can check
  opens its row's `Reason` with the obstacle: `network:`, `hardware:`, `account:`, `data:` or
  `system:`, then what the simulator lacks. "Unit tests prove it" is no obstacle. An existing-tests requirement opens its reason-only row with `gate:` and the tier, `final` or `merge`. A reason
  excuses 1 requirement, never the app: every `xcode` area whose screens a task writes gets at
  least 1 `flow` row. The import fails naming each requirement and area that breaks this.
- A screen fed by a dependency client, a `…Client` module such as `APIClient`, runs its flows
  against a fake of that client chosen by the `-harness-scenario <name>` launch argument, never
  the live service; `network:` excuses none of its journeys. The contract adds that seam when the
  app has none, and a task or the contract gives the fake 1 scenario per journey: loading, error,
  retry and refresh are flow rows. The reference's "Network-fed screens" has the shape.
- A task whose own check exercises another task's work depends on that task: an acceptance row's
  `Writer` on every other `Runs after` task, a task on any task whose files its `Acceptance`
  names, and a UI test's writer on every task whose behaviour the test shows, such as a fake's
  seed data. The reference's "Dependencies a check needs" says which of these the import checks.

Close the phase: `"$SG" events span end <span> --outcome ok`.

## 6. Land the contract commit

Open the phase: `"$SG" events span start --phase contract --build-run <slug>`, kept as `<span>`.

1. `"$SG" run checkout create <slug> --session <session> --json` from the user's checkout. It
   takes the checkout `swiftgate run` made at launch. Its `worktree` is `<checkout>`; work only
   there. Never add or remove a worktree with git itself:
   only `swiftgate` keeps the gate reports a checkout holds when it goes.
   `run checkout create` and `worktree create` install each node area's dependencies once, frozen
   to its lockfile, and list each install in the JSON's `installs`. Never prefix an area command
   with an install, here or in a worker's brief: run `<config>`'s commands as they are. An install
   whose `outcome` isn't `passed` is a report line; its area's commands still run, and a step
   that then fails is handled as any failing command is.
2. Write the contract: the new types, signatures and stubs every task compiles against, with
   behaviour unchanged. It also fixes every name a `## Validation` check targets, so the check can
   exist before the code. Those names are each element identifier and label a flow drives, each
   route with its request and response shapes, each storage key and table, and each log line with
   its subsystem. An identifier goes in the repository's typed accessibility-id module when
   `[qa] accessibility_ids` names one. It must build in every touched area, and step 4's `slice`
   gate is what builds it: warm, in the scratch path the warm-up filled. Don't build by hand
   first. A raw `swift build` or `swift test` in the clone builds cold in the package's own
   `.build`, and the hook denies it (`guard.raw-swift-build`), as it denies a raw `xcodebuild`.
   To only build a `swiftpm` area, add the `--scratch-path` that denial names.
3. Commit on `<plan-branch>` with a message in the repository's own style. The repository's git
   hooks run on every commit of the run; a failing hook is a finding to fix, never one to bypass.
4. With the tree clean, `"$SG" check --tier slice --base <base> --json` in `<checkout>`. Fix any
   finding the contract caused in a new commit and gate again. A finding on a line that must stay
   as it is, such as a generated file, gets `"$SG" allow <rule> <path>:<line> --reason "<why>"`.
   Keep the GREEN run's `runId` as `<contract-run>`: it gated the commit at the tip of
   `<plan-branch>`, which is what step 7 records.

Close the phase: `"$SG" events span end <span> --outcome ok`.

## 7. Import and build

1. `"$SG" plan import <slug> --contract <contract-task> --contract-run <contract-run> --json`,
   where `<contract-task>` is the contract task's id. Status `invalid` quotes the task and line to
   fix: fix `PLAN.md` and import again. Status `blocked` names the state it couldn't read: report
   it and go to step 8. The import links the root `PLAN.md` to `<plan-dir>/PLAN.md` and keeps that
   link out of `git status`; workers read the plan by absolute path. It also sets the plan's index
   entry to `planned`, so `build start` needs no `index set`.
   - `contract.status` `done`: the contract task is done, with the contract commit and its gate
     run as its return, which `build start` hands to the dependents' packs. `build next` never
     offers it.
   - `contract.status` `pending` (exit 1): its `message` says why, such as a RED run or a run of an
     older commit, a `Writes` file the commit left untouched, or a missing `-harness-scenario`
     seam. Fix the contract, commit, gate it as in step 6 and import again with the new run. Never move the contract through `ledger set` or write its return by hand.
2. Run the build loop of `/swift-harness:build` (its `SKILL.md` and `references/event-loop.md`) with
   these changes:
   - Start it with `"$SG" build start <slug> --preset brownfield --session <session> --json`.
   - Its `main` is `<plan-branch>`, checked out in `<checkout>`: run its steps there.
   - Build each worker's pack with `"$SG" context-pack --role worker --ledger <plan-dir>/ledger.json
     --task-id <task> --build-run <run> --json`, with no `--design`: the pack holds the task's
     `PLAN.md` section, its areas' commands and the brownfield rules. The task's worktree already
     has its node dependencies, so the worker runs those commands without an install first.
   - **The validation task commits nothing**, so it never merges and never runs the build-task
     workflow. When `build next` lists it, run `worktree create` and `ledger set … in-progress` as
     for any task, then launch 1 Agent tool call in the background, passing
     `run_in_background: true`, with `subagent_type` `general-purpose` and `model` `opus`, the 1
     alias the tool takes here. Its prompt names the
     task's worktree and id, `<slug>` as its plan, its rows from `## Validation`, the contract
     commit's sha, and says to work in that worktree and follow
     `${CLAUDE_PLUGIN_ROOT}/skills/qa/references/validation-worker.md`. Its write set names no
     test file, so it writes `.harness/qa/<slug>/` alone. When it returns, first record its usage
     under its task, `"$SG" events ingest --session <session> --agent-id <agent> --role qa --task <task> --build-run <run>`,
     with the `<agent>` of the `agentId: <agent>` line its launch printed: each task's completion
     ingest leaves it untagged. An exit 2 that says `telemetry is off` means say nothing, and any
     other non-zero exit prints 1 line for the report and the step goes on. Then:
     1. From `<checkout>`, `"$SG" qa adopt <worktree> --session <session> --json` copies its
        `.harness/qa/<slug>/` into `<plan-dir>/qa/`, where `qa run` reads every check. A non-GREEN
        adopt is 1 report line. Its `unblocks` names each checked return that waited on this
        task, with the exact `build merge` command.
     2. `/bin/rm -rf <worktree>/.harness/qa`, then
        `"$SG" ledger set <slug> <task> done --session <session> --json` and
        `"$SG" worktree remove <slug> <task> --session <session> --json`.
     3. Confirm each check fails before its tasks merge (amendment §5.2):
        `"$SG" qa run --plan <slug> --at-base --json --output <out>/qa-at-base.json` in
        `<checkout>`, in the background under the qa run watch. This `--at-base` run is never skipped, and
        no task that a row's `Runs after` names merges before it has run: such a task that
        finishes first keeps its checked return and merges once this run is done. It takes each
        row the worker's `--prepared-by` run proved from the `at-base-run.json` the adopt copied
        while its check is byte-identical, naming that run in the row's `reusedFrom`, and runs
        only the rest. A row that reads `pass` there fails it with
        `qa.check-passes-at-base`: that check can't tell the change from its absence. Drop the row
        from `## Validation`, giving a requirement left with no row the reason-only row, add 1
        assumption naming it, and `"$SG" plan import <slug> --json`. Each `missing:` line of its
        return gets the same treatment for the row that needed the name. A row that reads
        `unverified` there has no red run behind it, whatever the worker returned: 1 report line,
        `<requirement> <layer> <check>: no red run, <message>`.
     4. After every adopt and its `--at-base` run, run
        `"$SG" build next <slug> --session <session> --json` before ending the turn, and merge the
        first task in its `readyToMerge` while `merging` is absent, as the adopt's `unblocks`
        named: the next worker notice may be many minutes away.

     An acceptance test in the area's framework is never the validation task's: its row's
     `Writer` is the last `Runs after` task, whose slice gate proves it fails with that task's
     source reverted. The brownfield tiers refuse `--proof-base`, and that prove stands in for it.
     At the cutoff, `TaskStop` a validation task still running, set it `abandoned` and
     `worktree remove … --abandoned` it, which
     frees the merges waiting on item 3; its rows have no checks, so `qa run` reads them red and
     the report quotes them.
   - **Validate before each merge**, as [the build loop's before-merge step](../build/references/event-loop.md#before-each-merge)
     says: before `build merge`,
     `"$SG" qa run --plan <slug> --after <task> --before-merge --json --output <out>/qa-<task>.json`
     in `<checkout>`, in the background under the qa run watch, runs the rows that merge makes ready, acceptance, then flow, then state, on
     the task's branch merged into `<plan-branch>` in a scratch tree; `<plan-branch>` doesn't
     move. `build merge` refuses `flows-unchecked` until that run is GREEN at the branch's tip.
     A row whose other tasks all have checked returns waiting to merge runs before the first of
     them lands, on 1 trial merge of all their branches: the refusal names the command,
     `--after <task>,<other>,…`. A RED run there goes to the fixer of the task that owns the red
     behaviour: run `build merge` for that task first, so it cuts that task's fix worktree, then
     merge the others, which no longer wait on it.
     A RED run is a red merge gate before the merge: `build merge` refuses `flows-red` and cuts
     the fix worktree, then `"$SG" build halt --run <run> --task <task> --reason gate-red`,
     `"$SG" build resume --run <run> --task <task> --answer retry` and the fixer, given the red
     rows; its branch runs the same command with `--fix` before `build merge --fix`. At the
     cutoff, abandon as its item 2 says. Never merge on your own judgement, whatever you think
     caused the red.
   - **Flow repair before any halt.** A fixer's `flow row:` line, or a flow row red again after its
     fix, takes [the build loop's flow repair](../build/references/event-loop.md#flow-repair). A
     validation worker in repair mode rewrites that row alone, 1 requirement per folder, and
     proves it red at the base itself. `qa adopt --repair` takes it back, a second time only
     before `noNewStartsAt`, and the fixer runs again. Add 1 assumption naming the repaired row,
     its cause and the reason the adopt recorded. A refused repair is never a reason to stop the
     build while time remains: before `cutoffAt`, send the row back to the repair worker with the
     refusal's messages, which say what would pass, and adopt again. Only a `no repair:` return
     halts, decided as the next bullet says.
   - Where it halts and asks, decide yourself: take the option it marks recommended, record the
     halt with `build halt` and `build resume` as it says, and add 1 assumption naming the halt
     and what you chose. An option that stops the build starts nothing new: let running tasks
     merge or stop them, then go to step 8. No answer skips step 8. The time budget's cutoff is
     never one of these halts: the next bullet decides it by rule. Never halt, block or abandon a
     task on time grounds, such as a retry or a check that seems not to fit: before `cutoffAt`,
     time is `build cutoff`'s to price from measured costs, and `build halt` refuses a `budget`
     halt before it. A fixer's unconfirmed fix, `haltAdvice.answer` `verify`, is checked as
     [the build loop's fixer return](../build/references/event-loop.md#conflict-or-red-main) says:
     its gate, `check-return --fix` and its before-merge `qa run`, run by you, never a halt.
   - **The time box replaces the build skill's cutoff timer and its halt.** The cutoff is a
     check at every step of the loop. `build next` reports the box in `timeBox`, and
     `"$SG" run clock <slug> --json` reports its `phase`. Read `run clock` at each completion
     notice, before each merge and its merge gate, and before each `qa run`. Before you end a
     turn to wait on a background agent, a worker, fixer or the validation task, arm the cutoff
     wake if none is running: `"$SG" run clock <slug> --wait-until cutoffAt --json` with
     `run_in_background: true`. It exits once `cutoffAt` has passed, and its completion notice
     wakes you to read the clock. Arm 1 at a time, never as a
     foreground call, and only while an agent runs: a turn left with nothing but it in the
     background ends the run. Run
     `"$SG" build cutoff <slug> --session <session> --json` when `run clock` or any `build next`
     reports `phase` `cutoff`, or when a `build next` reports `no-new-starts` with nothing in
     `toStart` or `running` while tasks are still pending. Exit 1 means the cutoff hasn't come:
     go on with the loop. It prices each task's landing from this run's recorded merge and
     `final` gates, using fixed estimates only before any is recorded; before any `final`, it
     prices `final` by the area steps it can't take from the merge gates' passes, and charges a task's
     before-merge `qa run` unless a GREEN one covers its tip. It lands a task whenever that fits
     before the box ends. Its JSON decides every task, and you follow it as written. Its `steps`
     give each task's `next` commands in order: run them as written, with `<base>` and `<out>` as
     above and `<gate run>` the `runID` its gate printed.
     1. `TaskStop` the workflow and the stall watch of each task in `abandoned`: the command
        already set it `abandoned`, with the reason the report quotes. Then discard its
        worktrees: `"$SG" worktree remove <slug> <task> --abandoned --session <session> --json`
        removes the task's and its fixer's, merged or not, and keeps their branches.
     2. Merge each task in `finish`, in order, as the build loop's completion step does, from
        where it stands: a task already merged skips `build merge`, and one in `landed` skips
        its merge gate too, going straight to `ledger set … done` and `worktree remove` (with
        `--fix` after a fix merge). A task not yet merged runs its `qa run --before-merge` first,
        which takes the rows a run on the same merged tree already passed.
        A conflict, a `flows-red` refusal, a RED `merge` gate or one `build gate-wait` reads as
        `overrun` gets no fixer at the cutoff: `build merge --undo` when the merge landed, then
        `"$SG" ledger set <slug> <task> abandoned --session <session> --json` and
        `worktree remove … --abandoned` as item 1 says. A BLOCKED merge gate, such as a prove the
        time left couldn't hold, is run again with the same `next` commands and never undone:
        `build merge --undo` refuses a task in `finish` whose newest merge gate isn't RED. Never
        undo or abandon a task in `finish` for any other reason.
     3. Start nothing else, and go to step 8.

     `build cutoff` records the cutoff as `budget` halts it answers itself, so never run
     `build halt` for it. The tasks it names under `notStarted` stay `pending`, and the report
     lists them as tasks that didn't fit the box.
   - A design conflict halts with `"$SG" build halt --run <run> --task <task> --reason amend`,
     whatever the preset's `on_design_conflict` says. A brownfield plan has no design to amend:
     `PLAN.md` is what changes. **Retry with a widened write set** (Recommended) when every path
     the conflict names can join the task's `- Writes:` without 2 tasks of 1 wave sharing a path,
     adding a `Deps:` entry where it must:
     1. `"$SG" ledger set <slug> <task> blocked --session <session> --json`, if it isn't already.
     2. Add the paths to the task's `- Writes:` in `PLAN.md`, and 1 assumption naming the
        conflict and the paths.
     3. `"$SG" plan import <slug> --json`. It keeps every task's status and rewrites each write
        set from `PLAN.md`.
     4. `"$SG" ledger set <slug> <task> pending --session <session> --json`, then
        `"$SG" build resume --run <run> --task <task> --answer retry`. A dependent the conflict
        set `blocked` goes back to `pending` the same way. `build next` starts the task again,
        into the worktree it already has.

     **Stop** is recommended only when widening can't resolve it: the conflict needs a change to
     work already done, such as the contract or a merged task, or a path a running task owns. A
     task that conflicts again after its retry stays `blocked`: go on without it.
   - **Merges follow `build next`'s queue, and each merge gate has a deadline.** Merge the first
     task in `readyToMerge`, only while `merging` is absent, as the build loop's
     [merge queue](../build/references/event-loop.md#merge-queue) says. Each merge gate is
     `"$SG" check --tier merge --base <base> --json > <out>/merge-<task>.json`, launched with
     `run_in_background: true`, then watched in the foreground with
     `"$SG" build gate-wait <slug> --tier merge --output <out>/merge-<task>.json --session <session> --json`
     until it reads. A `worker-returned` means a task's Workflow ended: check its return, then
     watch again. An `overrun` is a RED merge gate: undo it, then merge the next task in
     `readyToMerge` before its fixer returns. A BLOCKED one runs again, as the build loop's table
     says; while the time left can't hold it, go on with other work, and after the cutoff
     `build cutoff`'s `next` commands run it again. At the cutoff it gets no fixer, as a RED merge
     gate doesn't.
   - Stop at its step 4; this skill's step 8 replaces it.
   - Review is `classified`: `swiftgate judge diff-risk` asks the `[judge]` in `<config>` to rate
     each task's diff `low`, `medium` or `high`, and paths in `[brownfield] sensitive` are always
     `high`. The first discovery writes `[judge]` with the Claude backend and the default
     thresholds; Jev rates only when the config opts in to it. When the judge can't answer, the
     review runs at `medium`, the return's `notes` say why, and the report names each such task
     with that reason; a missing answer is never read as `low`. You decide every finding that
     would block.

## 8. Final

Every run ends here, however its build ended: `build next` reports nothing to start and nothing
running, an answer stopped the build and its running tasks have merged or stopped, or the cutoff
decided its running tasks. Blocked, abandoned and pending tasks never skip this step: `final`
gates whatever merged, the contract alone when nothing else did. A run whose `plan import` never succeeded has no ledger and no
`<run>`: it runs item 1 alone, naming `<slug>` for its span, then step 9.

Open the phase: `"$SG" events span start --phase final --build-run <run>`, kept as `<span>`.

1. In `<checkout>`, `"$SG" check --tier final --base <base> --json > <out>/final.json`, launched
   with `run_in_background: true` and watched in the foreground with
   `"$SG" build gate-wait <slug> --tier final --output <out>/final.json --json` until it reads,
   as a merge gate is. Its deadline is never past the box's end. An `overrun` is a RED `final`
   with no run to record: `TaskStop` it, skip item 2 and go on from item 3, and the report names
   the overrun. It runs every area's `test`, `lint` and `build` against the baseline, plus each
   area's `e2e`. A step, or a prove of changed tests on the same reverted tree, that a merge gate
   passed on the same inputs is taken, not run, and a `gate.reused` note names that gate. A test step that also fails
   whole at the merge base, with no test id, is `baseline.whole-step` and RED. Each baseline finding
   names where the head's and the merge base's output tail and report were kept: read those first.
2. Record it: `"$SG" build record-gate <slug> --kind final --run-id <its run id> --session <session> --json`.
3. `"$SG" qa run --plan <slug> --final --json` in `<checkout>` runs every validation row whose
   tasks merged, and records each flow with a video. Read its verdict, and keep its `runID` and
   rows for item 5 and step 9. A RED verdict with a `red` row
   counts as a red `final` in item 4, whose fix task owns the files the red rows' checks exercise,
   and item 4's second `final` runs this item again. After `final` a row that never verified,
   `unverified` or `abandoned`, is RED too, as is a table with no row a check runs; with no `red`
   row no fix task makes it run, so it goes to the report as is.
4. Not GREEN: close the span with `"$SG" events span end <span> --outcome red`, add 1 fix task
   to `PLAN.md` that owns the failing files, import again, run the build loop until it merges, then
   open a new `final` span as above and run `final` once more. A second red `final` closes its
   span with `"$SG" events span end <span> --outcome red`, goes on to item 5 and ends the run RED;
   the report quotes its findings as `rule: message`. Past the cutoff a fix task doesn't fit in
   the box: a red `final` then goes straight to item 5 and ends the run RED.
5. `"$SG" build finish <slug> --session <session> --qa-run <runID> --json`, naming item 3's
   newest `runID`. A plan with a validation table can't finish without the newest `qa run
   --final` and its id: `build finish` refuses, naming that run and its verdict. It records the
   verdict, and a RED one ends the run RED. Then close the phase:
   `"$SG" events span end <span> --outcome ok`.
6. `"$SG" run checkout remove <slug> --session <session> --json`. It stops any gate or `qa run`
   still live in a tree it removes, refusing when one won't stop, then keeps the checkout's gate
   reports in the user's checkout, then removes every task and fix worktree the run left, merged
   or not, keeping their branches, and `<plan-branch>` holds every commit.

## 9. Report

First record every message the session and its agents wrote since their last ingest:
`"$SG" events ingest --session <session> --role orchestrator --build-run <run>`. It reads the
session's transcript, its Agent-tool subagents' and every Workflow agent's, so the build run's
cost is whole. An exit 2 that says `telemetry is off` means say nothing, and any other non-zero
exit prints 1 line for the report and the step goes on.

`"$SG" run report <slug>` writes the report to `<plan-dir>`, rewrites the run's report page, whose path
its JSON names as `runReport`, and prints the report: the assumptions, the
baseline failures, the build-only areas, the dropped steps, each task's review depth, the review
fallbacks, the time box with each task that didn't fit it, and the plan branch to merge. Its first
line says whether the run finished: a run that left any task blocked
or pending leads with `run: INCOMPLETE` and names each one, and its `final` verdict, on the next
line, covers only what merged. A plan with a validation table adds `validation: <n> of <m> rows
verified` after it, from the newest `qa run` over every row: after `final`, a row that never
verified makes it RED. Print it as your last message as written, then 1 line per row of
step 8's `qa run`, `<requirement> <layer> <check>: <result>, <message>`, and its `runID`, then the
cost section's `total` and `total with judge` lines of `"$SG" events summary --build-run <run>`;
a failed summary prints 1 line. Merging
`<plan-branch>` is the user's call; never merge it into their branch.

## Rules

- Every choice is yours. A question you would ask becomes an assumption in `PLAN.md`.
- The run ends inside its time box. `run clock` holds the early steps to their deadlines, and
  `build cutoff` decides the running tasks at the cutoff; neither waits for anyone.
- Commits land on `<plan-branch>` only, from `<checkout>` or a task worktree beside it.
- The repository's git hooks run on every commit; our own commit-message check doesn't run here.
- `<config>` changes only through `"$SG" discover --apply` and `"$SG" allow`.
- Explorer and worker models are pinned ids, never aliases. The validation worker's Agent tool
  call is the 1 exception: that tool takes only aliases.
- Every gate is a `swiftgate` command. Never hand-write a check or read a gate's verdict from its
  exit status alone; read its JSON, kept under `<out>` when kept in a file.
- Gates and `qa run` run in the foreground, except the merge gates, `final` and the `--at-base`
  and before-merge `qa run`s, which run in the background while `build gate-wait` watches them
  in the foreground (Foreground work).
