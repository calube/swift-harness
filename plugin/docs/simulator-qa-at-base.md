# Simulator QA at the merge base

This page covers the `qa run` modes that run validation rows outside the checkout. `--at-base`
proves each row red before its tasks merge, `--before-merge` runs a task's rows on a trial merge,
and `--prepared-by` runs a validation worker's rows before `qa adopt`. Read it when
`build merge` refuses a task over its rows.

The other flags and the layer order are in [`simulator-qa.md`](simulator-qa.md#qa-run). Rule ids
are in [`standards.md` § Rule id index](standards.md#rule-id-index).

## Running every row at the merge base

`--at-base` runs every row, whatever its tasks, in a scratch worktree at the merge base of `HEAD`
and `main`. In a brownfield clone the plan branch stands in for `main`. It runs every layer with
no stop, and records each failure's exit status.

- A row that reads `pass` there is `qa.check-passes-at-base`: its check can't tell the change from
  its absence.
- A row that reads `unverified` there is a nit: it has no red run.

## Before a task merges

`--after <task> --before-merge` runs that task's ready rows, as `--after` picks them, in a scratch
worktree. There `qa run` merges the task's branch `<plan>/<task>` into `main`'s tip, so `main`
doesn't move. `--fix` merges the fixer's branch `<plan>/fix-<task>` instead.

- The report's `trialMerge` names the branch, its tip and `main`'s commit.
- A branch that conflicts runs no row. Each row reads `unverified`, and `trialMerge.conflicts`
  names the files.

`build merge` checks these runs before it lands a task:

| Refusal | When |
|---|---|
| `build-merge.flows-unchecked` | a ready row has no GREEN or conflicted run at the branch's tip on `main`'s commit |
| `build-merge.flows-red` | that run is RED; `build merge` cuts the fix worktree, as it does for a conflict |
| `build-merge.at-base-unchecked` | the row passed, but no `--at-base` run without `--prepared-by` has taken that row with the same requirement, layer and check |

After another merge moves `main`, a run counts as if it ran on `main`'s commit when its trial
merge made the same tree this merge lands. Its `merged-tree-run.json` records that tree. A task
whose rows all wait on other tasks needs neither run, so it never waits for the at-base run.

### Several tasks at once

`--after <task>,<other>,… --before-merge` merges each named branch in turn. It runs every row that
names any of them, and counts each as merged. `trialMerge.alongside` names the other branches and
their tips.

`build merge` never waits for such a run. A row over tasks that haven't all merged needs no run
before the first of them lands, and runs on the last one's trial merge.

A run that took every unmerged task the row waits on still counts, as long as it took each at the
commit its standing check names. When it is RED in the row, `build merge` refuses each of those
tasks. A check stands while it is GREEN for a `ready-to-merge` return, with no ledger reset and no
halt answered `retry` since.

With a build run, `qa run` takes each branch alongside at the commit its standing check names,
whatever the branch head is. It reads BLOCKED for a task with no standing check.

### Reusing a merged tree's run

Each merged run leaves `merged-tree-run.json` beside its report. The file holds the merge's tree
and each row's result with its check's digest.

A later run whose trial merge makes the same tree reads the newest such record from any checkout
of the clone. From it, the run takes each row that read `pass` with a byte-identical check, and
names that run in `reusedFrom`. So `qa run` doesn't repeat a fixer's passing run before the merge.
A row that read `red` there runs again.

## A validation worker's prepared run

With `--prepared-by <task>`, only `<task>`'s rows run. Their `qa/<name>` checks and `QA_DIR` come
from the checkout's `.harness/qa/<slug>/`. This is a validation worker's red run before
`qa adopt`.

- It needs `--at-base`, and takes neither `--after` nor `--final`.
- With `--requirement <id>` it runs only that requirement's rows: a
  [flow repair](simulator-qa-flow-repair.md)'s red run.

The run leaves `at-base-run.json` in that folder. It holds the run id, the merge base, and each
row's result, message and exit status, with the SHA-256 digest of its check. The digest covers the
row's layer, its check's text and, when the check names a file, that file's bytes.

`qa adopt` copies the record into plan state beside the checks. The report's `atBaseRecord`, printed
as `at-base record:`, is the record's absolute path, or `null` when the run writes none.

## Reusing the prepared rows

A later `--at-base` run without `--prepared-by` reads that record. It takes a row's recorded
result, without running the row, when a recorded row:

- has the same requirement, layer and check text;
- has the same digest as the adopted check;
- and read `pass` or `red`.

The taken row names that run in `reusedFrom`, in `qa/report.json` and in its `qa.check` event, and
its message starts `reused from qa run <id>`. A note counts the reused rows. 1 note per other
ready row says why it ran: the record doesn't hold it, its check changed, or it read `unverified`
there.

`qa run` takes a flow row and its requirement's state rows together, or runs them together. A
state check reads what its flow left on a device, and only a run of that flow brings the device
up. When `qa run` takes every ready row, it makes no scratch worktree.
