# Simulator QA run bounds

How a `qa run` is bounded in time and where its JSON goes, and which rows the final run takes once
the build has ended. The command itself is in [`simulator-qa.md`](simulator-qa.md), and the runs
before a merge in [`simulator-qa-at-base.md`](simulator-qa-at-base.md). Rule ids are in
[`standards.md` § Rule id index](standards.md#rule-id-index).

## --output and --deadline

`qa run --output <path>` writes the JSON report, as `--json` prints it, to `<path>` and nothing
else: the `run <id> started` line and any other output stay on the terminal, so the file always
parses. A relative path is from the checkout's toplevel, and missing folders are made. The
terminal gets the 1-line summary. Send the JSON there, never with `--json > file 2>&1`, which puts
the start line first.

`qa run --deadline <time>` takes an ISO 8601 time or whole seconds from now. The wait for the
build run's device and every row end by then: a row that can't finish before it doesn't start and
reads `unverified` naming why, and a device still held then leaves the flow rows `unverified`
naming its holder. Inside a run's box the earlier of the box's own deadline and `--deadline`
wins. Never wrap `qa run` in `timeout`: a kill leaves no report, and the hook denies it
(`guard.qa-run-timeout`).

## The final run's rows

Once the build has ended, a row whose task the ledger reads unmerged still runs when that task's
branch tip is in `HEAD`, landed by another task's merge: a fixer's branch that took it in for a RED
run over both. A tip that is a commit the plan branch itself stood at landed nothing. Only a task
whose commits aren't in `HEAD` leaves its rows `abandoned`.

`qa run --final` also takes, for each ready row, the pass a `qa run --before-merge` recorded on a
trial merge whose tree is `HEAD`'s tree, when the row's check is byte-identical to the one that
ran, as a merge's own run does. A row whose check changed since, such as a repaired flow, runs
again.

## A fix that carries another task

`build merge --fix` refuses `fix-carries-unmerged` while a task its branch took in is still
running. Once that task is abandoned or blocked, the fix lands it: the merge event names it in
`carried`, the ledger marks it `done`, and a row over both needs a GREEN `qa run --before-merge`
that took both branches at their tips. The cutoff prices that fix with the carried branches, so
it reads the fixer's run over both rather than no row at all.
