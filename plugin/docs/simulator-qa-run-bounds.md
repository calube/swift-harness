# Simulator QA run bounds

This page covers how to bound a `qa run` in time, where its JSON report goes, and which rows the
final run takes once the build has ended. Read it when you run `qa run` in the background or under
a time box, or when a row reads `abandoned`.

The command itself is in [`simulator-qa.md`](simulator-qa.md#qa-run), and the runs before a merge
in [`simulator-qa-at-base.md`](simulator-qa-at-base.md). Rule ids are in
[`standards.md` § Rule id index](standards.md#rule-id-index).

## --output and --deadline

`--output <path>` writes the JSON report, as `--json` prints it, to `<path>` and nothing else. The
`run <id> started` line and all other output stay on the terminal, which gets the 1-line summary,
so the file always parses. A relative path starts from the checkout's top level, and `qa run`
makes any missing folders. It creates the file empty as the run starts and fills it once the run
ends; `build gate-wait --qa` watches it. Send the JSON there, never with `--json > file 2>&1`,
which puts the start line first.

`--deadline <time>` takes an ISO 8601 time or whole seconds from now. The wait for the build
run's device and every row end by then:

- A row that can't finish before the deadline doesn't start, and reads `unverified` naming why.
- A device someone still holds at the deadline leaves the flow rows `unverified`, naming its
  holder.
- Inside a run's time box, the earlier of the box's deadline and `--deadline` wins.

Never wrap `qa run` in `timeout`. A kill leaves no report, and the hook denies it as
`guard.qa-run-timeout`.

## The final run's rows

Once the build has ended, a row whose task the ledger reads unmerged still runs when that task's
branch tip is in `HEAD`. Another task's merge landed it: a fixer's branch that took it in for a
RED run over both. A tip that is a commit the plan branch itself stood at landed nothing. Only a
task whose commits aren't in `HEAD` leaves its rows `abandoned`.

`qa run --final` also reuses a pass that a `qa run --before-merge` recorded on a trial merge whose
tree is `HEAD`'s tree, when the row's check is byte-identical to the one that ran. A merge's own
run does the same. A row whose check changed since, such as a repaired flow, runs again.

## A fix that carries another task

`build merge --fix` refuses `fix-carries-unmerged` while a task that the fixer's branch took in is
still running. Once the build loop abandons or blocks that task, the fix lands it:

- the merge event names it in `carried`;
- the ledger marks it `done`;
- a row over both tasks needs a GREEN `qa run --before-merge` that took both branches at their
  tips.

The cutoff prices that fix with the carried branches, so it reads the fixer's run over both
rather than no row at all.
