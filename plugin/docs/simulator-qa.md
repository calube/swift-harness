# Simulator QA validation

How `swiftgate qa run` and `swiftgate qa adopt` treat a plan's validation rows. The rule ids they
report are in [`standards.md` § Rule id index](standards.md#rule-id-index).

## qa run

`swiftgate qa run [--plan <slug>] [--after <task>] [--at-base] [--json]` runs the rows of a plan's
validation.json (simulator QA amendment §6, §6.2). Without `--plan` it takes the 1 plan holding a
validation.json; with none it is GREEN with a note, and with several it exits 2 naming them. A row
runs once every `Runs after` task is `done` in the ledger, the `--after` task counting as merged;
`--after` keeps only the rows that name it, and a row with an unmerged task reads `waiting`.

Rows run in the current checkout in layer order, acceptance, then flow, then state, and a layer with
a red row leaves every later row `unverified`. An acceptance or state check is a shell command run by
`/bin/sh -c`, or a file under the plan's state directory such as `qa/<name>.state.sh`, run as its own
program when executable and by `/bin/sh` otherwise. Each gets `QA_PORT`, a loopback port the OS
assigned that run, `QA_DIR`, the plan's `qa/` folder, and `QA_EVIDENCE_DIR`, the run's `qa/` folder.

Exit 0 is `pass`; any other exit, a signal or the 10-minute timeout is `red`; a check that couldn't
start is `unverified`. Only the exit status decides: a screenshot, tree or log beside a row never
passes it. A flow row reads `unverified` with "flow runner not built", and a state row runs only once
every flow row for its requirement passed.

`--at-base` runs every row, whatever its tasks, at the merge base of `HEAD` and `main` (a brownfield
clone's plan branch) in a scratch worktree, with no layer stop, and records each failure's exit
status.

The run writes `.harness/runs/<runID>/qa/report.json`, each row's command, exit status, stdout and
stderr in `qa/<NN>-<requirement>.<layer>.txt`, and 1 qa.check event per row.

## qa adopt

`swiftgate qa adopt <worktree> [--json]` replaces each plan's `qa/` folder in plan state with a copy
of `<worktree>/.harness/qa/<plan>/`. It exits 1 and copies nothing for a path that isn't a checkout
of this repository, a worktree with no prepared folder, or a folder naming no plan.
