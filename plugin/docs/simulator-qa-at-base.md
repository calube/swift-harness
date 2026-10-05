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

## Before a task merges

`--after <task> --before-merge` runs that task's ready rows, as `--after` picks them, in a scratch
worktree where the task's branch `<plan>/<task>` is merged into `main`'s tip, so `main` doesn't
move; `--fix` merges its fixer's branch `<plan>/fix-<task>`. The report's `trialMerge` names the
branch, its tip and `main`'s commit. A branch that conflicts runs no row: each reads `unverified`
and `trialMerge.conflicts` names the files. `build merge` refuses `build-merge.flows-unchecked`
while a ready row has no GREEN or conflicted run at the branch's tip on `main`'s commit, and
`build-merge.flows-red` for a RED one, cutting the fix worktree as a conflict does.

`--after <task>,<other>,… --before-merge` merges each named branch in turn and runs every row that
names any of them, each counting as merged; `trialMerge.alongside` names the others' branches and
tips. Once each unmerged task a row waits on has a checked return that still stands at its branch
tip, and no fixer's branch, `build merge` of any of them refuses `flows-unchecked` until such a run
took all their branches at those commits on `main`'s commit, so the row runs before the first of
them lands. A check stands while it is GREEN for a `ready-to-merge` return with no ledger reset or
halt answered `retry` since. With a build run, `qa run` takes each branch alongside at the commit
its standing check names, whatever its branch head is, and is BLOCKED for a task with none.

Each merged run leaves `merged-tree-run.json` beside its report: the merge's tree and each row's
result with its check's digest. A later run whose trial merge makes the same tree takes, from the
newest such record in any checkout of the clone, each row that read `pass` with a byte-identical check, naming that run in
`reusedFrom`, so a fixer's passing run isn't repeated before the merge. A row that read `red` there
runs again.

## A validation worker's prepared run

With `--prepared-by <task>`, only `<task>`'s rows run, their `qa/<name>` checks and `QA_DIR` read
from the checkout's `.harness/qa/<slug>/`: a validation worker's red run before `qa adopt`. It needs
`--at-base`, and takes neither `--after` nor `--final`. With `--requirement <id>` it runs only that
requirement's rows: a [flow repair](simulator-qa-flow-repair.md)'s red run.

The run leaves `at-base-run.json` in that folder: its run id, the merge base, and each row's result,
message and exit status with the SHA-256 digest of its check. The digest covers the row's layer,
its check's text and, when the check names a file, that file's bytes. `qa adopt` copies the record
into plan state beside the checks. The report's `atBaseRecord` is the record's absolute path, and
the text output prints it as `at-base record:`; a run that writes no record leaves it `null`.

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

Every `qa run` ends its output with 1 line naming the verdict, the run id and the run's
`report.json` (with `--json`, the last member, `summary`), so a cut output still names its run.
