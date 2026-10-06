# Simulator QA

This page covers the 4 `swiftgate qa` commands that check a plan's validation rows: `qa lint`
checks flow files offline, `qa run` runs the rows, `qa adopt` takes a validation worker's
checks into plan state, and `qa stage` copies 1 requirement's adopted checks back out for a repair. Read it when you write, run or read a validation row.

| Topic | Page |
|---|---|
| How `qa run` drives a flow row, the record it leaves, and the final pass | [`simulator-qa-flows.md`](simulator-qa-flows.md) |
| How T3 records each kept XCUITest flow | [`simulator-qa-kept-flows.md`](simulator-qa-kept-flows.md) |
| Writing `wait` and `is` steps | [`simulator-qa-flow-steps.md`](simulator-qa-flow-steps.md) |
| Selector keys and matching | [`simulator-qa-flow-selectors.md`](simulator-qa-flow-selectors.md) |
| Gestures: pull to refresh, a search field, a swipe | [`simulator-qa-flow-gestures.md`](simulator-qa-flow-gestures.md) |
| `test:` acceptance rows and the shared simulator | [`simulator-qa-test-rows.md`](simulator-qa-test-rows.md) |
| `--output`, `--deadline`, and the rows the final run takes | [`simulator-qa-run-bounds.md`](simulator-qa-run-bounds.md) |
| `--at-base`, `--before-merge` and a validation worker's prepared run | [`simulator-qa-at-base.md`](simulator-qa-at-base.md) |
| Staging a flow row with `qa stage` and rewriting it with `qa adopt --repair` | [`simulator-qa-flow-repair.md`](simulator-qa-flow-repair.md) |
| `sim up`, `sim verify` and `sim down` | [`simulator-qa-sim.md`](simulator-qa-sim.md) |
| Which controls `sim verify`'s accessibility audit judges | [`simulator-qa-audit.md`](simulator-qa-audit.md) |

Rule ids are in [`standards.md` § Rule id index](standards.md#rule-id-index).

## qa lint

```bash
swiftgate qa lint <flow file>... [--json]
```

`qa lint` checks `agent-device batch` steps files before any device boots. A steps file is a JSON
list of `{"command": "<name>", "input": {...}}` steps.

It checks each step against the pinned `agent-device`'s step schemas from its MCP `tools/list`,
which the plugin ships as `qa/agent-device-schemas-<pin>.json`. It checks
each `id="…"` selector against the raw values of the 1 `enum AccessibilityID: String` in the Swift
file that `[qa] accessibility_ids` names. A brownfield clone has no such key, so its flows get no
id check and no note. Strings under `text` and `value` are app content, never selectors or refs.

| Rule id | Severity | Finds |
|---|---|---|
| `qa.flow-unparsed` | major | a file that isn't a JSON list of steps; the file earns no other finding |
| `qa.flow-schema` | major | a step the pinned tool's schema refuses, or a command it has no schema for |
| `qa.flow-ref-target` | major | a step that targets a ref such as `@e3` or a point, not a selector |
| `qa.flow-kind-key` | major | a `wait` target under the wrong key, an `is` `value` on the wrong predicate, a `swipe` with no `preset` ([flow steps](simulator-qa-flow-steps.md#what-qa-lint-refuses)) |
| `qa.flow-unknown-id` | major | an `id="…"` selector that `AccessibilityID` doesn't declare |
| `qa.flow-no-assert` | major | a flow with no `wait` or `is` step that checks a result; a `duration` or `stable` wait only pauses |
| `qa.flow-transient-state` | minor | a selector the flow sees appear and then go with only checks between, outside a `held` scenario ([flow steps](simulator-qa-flow-steps.md#a-state-that-ends-on-its-own)) |
| `qa.flow-ids-unknown` | nit | no `.swiftgate.toml` or no `[qa] accessibility_ids`, so no id was checked; once per run |

The verdict is RED (exit 1) on any major finding. A minor or nit finding never gates. `qa lint`
reads BLOCKED (exit 2) when:

- `SWIFTGATE_HARNESS_ROOT`, the plugin root, is unset;
- the schema file is missing or unparsable, uses an unsupported keyword, or records a version
  other than the pin;
- the config (`.swiftgate.toml`, or a brownfield clone's `config.toml`) doesn't load;
- the configured id file doesn't read, or holds no single String-backed `AccessibilityID` enum
  with plain string raw values;
- or a flow file doesn't read.

## qa run

```bash
swiftgate qa run [--plan <slug>] [--after <task>[,<task>…] [--before-merge [--fix]]] \
  [--at-base [--prepared-by <task> [--requirement <id>]]] [--final] \
  [--json] [--output <path>] [--deadline <time>]
```

`qa run` runs the rows of a plan's `validation.json`. Without `--plan` it takes the 1 plan that
holds a `validation.json`. With none, the verdict is GREEN with a note. With several, it exits 2.

| Flag | What it does |
|---|---|
| `--after <task>` | Counts the task as merged and runs only the rows that name it. A flow records its video when the recorder is free |
| `--before-merge` | With `--after`, runs on a trial merge of the task's branch into `main`'s tip ([at-base page](simulator-qa-at-base.md#before-a-task-merges)) |
| `--fix` | With `--before-merge`, merges the task's fixer's branch in place of the task's |
| `--at-base` | Runs every row at the merge base and records why each fails ([at-base page](simulator-qa-at-base.md)) |
| `--prepared-by <task>` | With `--at-base`, runs a validation worker's rows from its checkout, before `qa adopt` |
| `--requirement <id>` | With `--prepared-by`, runs only that requirement's rows: a [flow repair](simulator-qa-flow-repair.md)'s red run |
| `--final` | Runs every ready row, recording each flow and saving its logs ([the final pass](simulator-qa-flows.md#the-final-pass)). Takes neither `--at-base` nor `--after` |
| `--output <path>` | Writes the JSON report to the file alone ([run bounds](simulator-qa-run-bounds.md#--output-and---deadline)) |
| `--deadline <time>` | Stops by this time ([run bounds](simulator-qa-run-bounds.md#--output-and---deadline)) |

### Which rows run

A row runs once each task in its `Runs after` has merged, going by the ledger or the build
events. A task named in `--after` counts as merged.

A row with an unmerged task reads `waiting`. Once the build has ended (`--final`, or a `final`
gate after the last merge), such a row reads `abandoned` when its task's commits never landed, and
`unverified` otherwise. See [the final run's rows](simulator-qa-run-bounds.md#the-final-runs-rows).

### Layers

Rows run in the checkout in layer order: acceptance, flow, state.

- A red row leaves only its own requirement's later-layer rows `unverified`.
- A state row runs only after its requirement's flow rows all pass. It runs straight after the
  requirement's last flow row, on that flow's device.
- An acceptance or state check is a shell command run by `/bin/sh -c`, or a file in plan state,
  such as `qa/<name>.state.sh`, run as its own program when executable and by `/bin/sh` otherwise.
- A check of the form `test: <id>` runs 1 test through the area's test command. See
  [`simulator-qa-test-rows.md`](simulator-qa-test-rows.md).
- A flow row runs as 1 `agent-device batch` on a device that `sim up` leases. See
  [`simulator-qa-flows.md`](simulator-qa-flows.md).

Each acceptance or state check gets these environment variables:

| Variable | Value |
|---|---|
| `QA_PORT` | a loopback port the OS assigned for this run |
| `QA_DIR` | the plan's `qa/` folder |
| `QA_EVIDENCE_DIR` | the run's `qa/` folder |
| `QA_JUNIT` | where the check may write a JUnit or xUnit report; a `test:` row passes this path as `{junit}` |

A state row that runs on a flow's device also gets the `QA_SIM_*` variables listed in
[`simulator-qa-flows.md`](simulator-qa-flows.md#running-a-flow-row).

### Results

| Result | When |
|---|---|
| `pass` | the check exits 0 |
| `red` | any other exit, a signal, or the 10-minute timeout per check |
| `unverified` | the check couldn't start, or it can't finish before the run's cutoff and so never starts |

- The cutoff is the run's deadline. With `--final` it is the end of the run's time box.
- A red row's message adds the check's first failure line.
- A JUnit or xUnit report, or a result bundle, that shows no test ran reads `red` at the merge
  base and `unverified` otherwise.
- A pass counts the tests the report shows passed, and lists them as evidence.
- A screenshot, tree or log never passes a row.

### What a run writes

- `.harness/runs/<runID>/qa/report.json`, the report.
- `qa/<NN>-<requirement>.<layer>.txt` per row: the command, exit status, stdout and stderr.
- 1 `qa.check` event per row.

The message leads with how many rows got a `pass` or `red`. Its total counts the table's
reason-only rows and names them.

During merges, an `unverified` row is a nit but leaves the run BLOCKED, naming why. Once the build
has ended, an `unverified` or `abandoned` row gates. A table with no row that a check runs reads
`unverified` with `qa.no-verifiable-row`: a nit during merges, and a gate once the build has
ended. `run report` repeats the count under its `final` line.

Every `qa run` ends its output with 1 line that names the verdict, the run id and the run's
`report.json`. With `--json` that line is the last member, `summary`.

## qa adopt

```bash
swiftgate qa adopt <worktree> [--session <id>] [--json]
```

`qa adopt` replaces each plan's `qa/` in plan state with `<worktree>/.harness/qa/<plan>/`, then
removes `<worktree>/.harness/qa`. Its report lists each task the adoption unblocked: a task in the
build run's merge queue, ready to merge, that a validation row runs after. Each comes with its
next `build merge` command. `--session` puts the id of the session that holds the plan's lock into
those commands, which read `<session>` without it.

It exits 1 and changes nothing when the path isn't a checkout of this repository, when the
worktree has no prepared folder, or when the folder names no plan.

`--repair <requirement>` takes only 1 requirement's rewritten checks. See
[`simulator-qa-flow-repair.md`](simulator-qa-flow-repair.md).

## qa stage

```bash
swiftgate qa stage <worktree> --plan <slug> --requirement <requirement> [--json]
```

`qa stage` is the reverse of `qa adopt`, for a [flow repair](simulator-qa-flow-repair.md). It
removes `<worktree>/.harness/qa/`, then copies into `<worktree>/.harness/qa/<plan>/` each check file
that the plan's `validation.json` rows for that requirement name, from the plan's `qa/` in plan
state. Each file keeps its permissions.

| Flag | What it does |
|---|---|
| `--plan <slug>` | The plan whose adopted checks it copies |
| `--requirement <requirement>` | The requirement whose rows' check files it copies |
| `--json` | Prints the report as JSON |

It copies nothing unless the path is a checkout that `git worktree list` names, some row of the
requirement checks a `qa/` file, and every such file is in plan state.

| Exit | When |
|---|---|
| 0 | GREEN: it filled the folder |
| 1 | RED: it refused, and the message ends "nothing was staged" |
| 2 | BLOCKED: it couldn't list the checkouts, resolve or read plan state, or copy a file |

Text output is `qa stage: <verdict> <message>`, then 1 indented line per copied file. The JSON
report holds `command`, `worktree`, `plan`, `requirement`, `verdict`, `destination` (the folder it
filled), `files` (each copied file's name) and `message`. A copy that fails partway says to remove
`.harness/qa/` before a repair worker starts there.
