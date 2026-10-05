# Simulator QA

How `swiftgate qa lint` checks flow files, and how `swiftgate qa run` and `swiftgate qa adopt` treat a
plan's validation rows. Simulator sessions (`sim verify`, `sim down`) are in
[`simulator-qa-sim.md`](simulator-qa-sim.md). Rule ids are in
[`standards.md` § Rule id index](standards.md#rule-id-index).

## qa lint

`swiftgate qa lint <flow file>... [--json]` checks `agent-device batch` steps files offline, before
any device boots (simulator QA amendment §6.1). A steps file is a JSON list of
`{"command": "<name>", "input": {...}}`. Each step is checked against the step schemas
the pinned `agent-device` reports from its MCP `tools/list`, shipped as the plugin's
`qa/agent-device-schemas-<pin>.json`. They check each `id="…"` selector against the raw
values of the 1 `enum AccessibilityID: String` in the Swift file `[qa] accessibility_ids` names; a
brownfield clone, with no such key, gets no id check and no note. Strings under `text` and
`value` are app content, never selectors or refs.

The verdict is RED (exit 1) on any finding but the note, and BLOCKED (exit 2) when:

- the plugin root (`SWIFTGATE_HARNESS_ROOT`) is unset;
- the schema file is missing, unparsable, uses an unsupported keyword or records another version
  than the pin;
- the config (`.swiftgate.toml`, or a brownfield clone's `config.toml`) doesn't load;
- the configured id file doesn't read or holds no single String-backed `AccessibilityID` enum with
  plain string raw values;
- or a flow file doesn't read.

## qa run

`swiftgate qa run [--plan <slug>] [--after <task> [--before-merge [--fix]]] [--at-base [--prepared-by <task>]] [--final] [--json]` runs the rows of a plan's
validation.json (simulator QA amendment §6, §6.2). Without `--plan` it takes the 1 plan holding a
validation.json: none is GREEN with a note, several exit 2. A row runs once each `Runs after`
task merged, per the ledger or build events, `--after` counting as merged and keeping only its
rows. A row with an unmerged task reads `waiting`; once the build ended (`--final`, or a `final`
gate after the last merge) `abandoned` if its task was, else `unverified`.

Rows run in the checkout in layer order: acceptance, flow, state. A red row
leaves only its own requirement's later-layer rows `unverified`. A requirement's state rows run straight after
its last flow row, on that flow's device. An acceptance or state check is a shell command run by
`/bin/sh -c`, or a file under the plan's state directory such as `qa/<name>.state.sh`, run as its own
program when executable and by `/bin/sh` otherwise. For a `test: <id>` check see
[`simulator-qa-test-rows.md`](simulator-qa-test-rows.md).
Each gets `QA_PORT`, a loopback port the OS
assigned that run, `QA_DIR`, the plan's `qa/` folder, and `QA_EVIDENCE_DIR`, the run's `qa/` folder.

Exit 0 is `pass`; any other exit, a signal or the 10-minute timeout is `red`; a check that couldn't
start is `unverified`. Inside a run's box, a row that can't finish before the cutoff (`--final`: the
box's end) doesn't start and is `unverified`. A red row's message adds its first failure line. An acceptance check may write
a JUnit or xUnit report to `$QA_JUNIT`, the path a `test:` row passes as `{junit}`; a report or result bundle showing
no test ran is `red` at the merge base and `unverified` otherwise. A pass counts the tests they show
passed and lists them as evidence. A screenshot, tree or log never
passes a row. A state row runs only after its requirement's flow rows all pass.

`--at-base` runs every row at the merge base, and `--prepared-by` a validation worker's rows before
`qa adopt`, and `--before-merge` a task's rows before it merges; see
[`simulator-qa-at-base.md`](simulator-qa-at-base.md).

`--final` runs every ready row and records each flow, with its logs (see
[the final pass](simulator-qa-flows.md#the-final-pass)). It takes neither `--at-base` nor `--after`.

The run writes `.harness/runs/<runID>/qa/report.json`, each row's command, exit status, stdout and
stderr in `qa/<NN>-<requirement>.<layer>.txt`, and 1 qa.check event per row. Its message leads with
how many rows got a `pass` or `red`, counting the table's reason-only rows in the total and naming
them. An unverified row is a nit during merges; once the build ended, it and an abandoned row
gate. A table with no row a check runs reads `unverified` with `qa.no-verifiable-row`, a nit during
merges that gates once the build ended. `run report` repeats the count under its `final` line.

A flow row runs as 1 `agent-device batch` on a device `sim up` leases; see
[`simulator-qa-flows.md`](simulator-qa-flows.md).

`sim up` and `sim hold` read `.swiftgate.toml`, or in a brownfield clone its 1 `xcode` area: the
workspace or project, the scheme in its `test` command, and the device its `-destination` names,
on the newest iOS runtime holding it. A clone with no `xcode` area, or several, reads BLOCKED.

## qa adopt

`swiftgate qa adopt <worktree> [--json]` replaces each plan's `qa/` folder in plan state with a copy
of `<worktree>/.harness/qa/<plan>/`. It exits 1 and copies nothing for a path that isn't a checkout
of this repository, a worktree with no prepared folder, or a folder naming no plan.
