# Simulator QA flow repair

How a flow row that stays red because of its flow file, not the app, gets rewritten and taken back
into plan state with `swiftgate qa adopt --repair`, without anyone stepping in. The flags of
`qa run` are in [`simulator-qa.md`](simulator-qa.md#qa-run), the prepared at-base run in
[`simulator-qa-at-base.md`](simulator-qa-at-base.md), and the steps a gesture needs in
[`simulator-qa-flow-gestures.md`](simulator-qa-flow-gestures.md). Rule ids are in
[`standards.md` § Rule id index](standards.md#rule-id-index).

## When the build loop repairs a row

A merge fixer that reads 1 flow row red in 2 `qa run`s stops and names the row in its `gate-red`
notes, which `build check-return` accepts beside a GREEN gate once a `flow row:` line names
the red `qa run`s. It says whether the failing step is the flow's fault: a step the pinned tool can't drive as
written, such as a `scroll` where a pull to refresh needs a `gesture` drag. A selector that names
the wrong element, or a step the app can't satisfy as written, counts too. The build loop then sends that row
alone to a validation worker in repair mode. The fixer itself never edits a flow file: they live in
plan state, which only `qa adopt` writes.

## The repair worker's red run

The worker rewrites only that requirement's check files in its checkout's `.harness/qa/<plan>/`,
which the orchestrator fills with that requirement's adopted copies alone, and proves them red at
the merge base itself. The build loop repairs several rows 1 requirement at a time, each in its
own folder:

```bash
"$SG" qa run --plan <plan> --at-base --prepared-by <writer> --requirement <requirement> --json
```

`--requirement` needs `--prepared-by`, and runs only the rows of that requirement the writer
writes. Its `at-base-run.json` holds those rows alone. Its `qa.check` events carry
`repairProof`, so a row's history leaves the run out until a repair adopts it.

## What `qa adopt --repair` checks

```bash
"$SG" qa adopt <worktree> --repair <requirement> --build-run <run> --cause flow-side|still-red \
  --reason "<why>" --red-run <run id> --red-run <run id> --json
```

It reads the requirement's rows from `validation.json`, the adopted checks and record in plan
state, the worktree's prepared folder and record, each red run's `qa/report.json` from the
worktree's runs or the main checkout's, and plan state's `qa/repairs.json`. It copies nothing when
any rule fails, and exits 1 naming each finding:

- `qa.repair-cap`: 2 repairs of the requirement already landed in this build run, or 1 did and
  the run's no-new-starts time has passed, or the run has no box. A row still red then goes to
  the user.
- `qa.repair-outside-row`: the prepared folder holds a file no row of the requirement checks. The
  message names the files the folder may hold.
- `qa.repair-weakens-check`: a `wait` or `is` step of the adopted flow is gone, out of order, or
  has a shorter `timeoutMs`. A repair may change, add or drop any other step, and may lengthen a
  timeout. A `wait` whose target moves to the key its `kind` reads
  ([`simulator-qa-flow-steps.md`](simulator-qa-flow-steps.md)) keeps its check; an `is` never
  keeps a `wait`. The message quotes the step that would pass.
- `qa.repair-unchanged`: every check is byte-identical to the adopted one.
- `qa.repair-not-red`: a check has no row in the prepared record, changed after that run, or read
  `pass` or `unverified` there.
- `qa.repair-wrong-red`: the flow read red at the base without failing a step, as a flow file the
  tool refuses does. Or it failed a step that is neither a `wait` or `is` step of the adopted flow
  nor the step the adopted flow failed at there. The red must come from what the requirement
  checks.
- `qa.repair-red-runs`: the command names no red run, or 1 doesn't read the requirement red.

## What it writes

When every rule passes, it copies the requirement's prepared check files over plan state's,
keeping their permissions, and replaces that requirement's rows in plan state's `at-base-run.json`
with the prepared ones. Each such row names the prepared run as its `runID`, so a later
`qa run --at-base` takes it, naming that run in `reusedFrom`, while every other row keeps the
record's own run. It appends the repair to `qa/repairs.json`: the requirement, rows, checks, build
run, cause, reason, red runs, the prepared run, the step the red runs failed at, and the commands
of the steps it took out and put in.

It writes 1 `qa.repair` event under the prepared run's id, with ids, row numbers and commands only;
the reason stays in `qa/repairs.json`. The run viewer reads it with the build run's `qa.check`
events and shows each repaired row's note in its history, naming the cause, the red runs, their
failing step, the commands replaced and the run that proved it.

The JSON names `repaired`, the record it appended, and `findings`; `adopted` names the plan and
how many check files it copied.
