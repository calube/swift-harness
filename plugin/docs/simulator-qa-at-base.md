# Simulator QA at the merge base

How `swiftgate qa run --at-base` proves each validation row red before its tasks merge (simulator
QA amendment §5.2), and how it takes the rows a validation worker already proved. The other flags
and the layer order are in [`simulator-qa.md`](simulator-qa.md#qa-run). Rule ids are in
[`standards.md` § Rule id index](standards.md#rule-id-index).

## Running every row at the merge base

`--at-base` runs every row, whatever its tasks, at the merge base of `HEAD` and `main` (a brownfield
clone's plan branch) in a scratch worktree, with no layer stop, recording each failure's exit
status. A row that reads `pass` there is `qa.check-passes-at-base`: its check can't tell the change
from its absence. An `unverified` row there is a nit: no red run.

## A validation worker's prepared run

With `--prepared-by <task>`, only `<task>`'s rows run, their `qa/<name>` checks and `QA_DIR` read
from the checkout's `.harness/qa/<slug>/`: a validation worker's red run before `qa adopt`. It needs
`--at-base`, and takes neither `--after` nor `--final`.

The run leaves `at-base-run.json` in that folder: its run id, the merge base, and each row's result,
message and exit status with the SHA-256 digest of its check. The digest covers the row's layer,
its check's text and, when the check names a file, that file's bytes. `qa adopt` copies the record
into plan state beside the checks.

## Reusing the prepared rows

A later `--at-base` without `--prepared-by` reads that record and takes a row's recorded result,
without running it, when a recorded row has the same requirement, layer and check text, the same
digest as the adopted check, and read `pass` or `red`. The row names that run in `reusedFrom`, in
`qa/report.json` and in its `qa.check` event, and its message starts `reused from qa run <id>`. A
note counts the reused rows, and 1 note per other ready row says why it ran: the record doesn't
hold it, its check changed, or it read `unverified` there.

A flow row and its requirement's state rows are taken together or run together: a state check
reads what its flow left on a device that only a run of that flow brings up. When every ready row
is taken, no scratch worktree is made.
