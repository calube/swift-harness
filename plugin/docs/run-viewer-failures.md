# Why a run failed

The [run viewer](run-viewer.md) says why a span is red, a task stopped or a build halted, from the
gate's `report.json` and the run's events. Nothing here changes what a gate decides.

## A red span

Hovering or focusing a timeline bar previews its popover without moving focus; a click or Enter
pins it. A red gate, tier or step span, a merge span closed by a RED gate, and a red `worker`,
`fix`, `verify` or `review` span whose task's RED gate run ended inside it, say why in a "Why it
failed" section:

- the test tiers that failed (T0 to T3), the `check` tier the run gated at (`push`, or a
  brownfield `slice`, `merge` or `final`), and whether it was a task's, a worker's, a merge or the
  final gate;
- the passed, failed and skipped counts;
- the gating findings, each with its rule id, severity, repo-relative `file:line` and message: the
  popover shows 3 with each message cut to 140 characters, the task drawer every one the view
  holds, whole;
- the failing tests, from `test.result`, each at the assertion its test failure finding names, and
  each changed test `prove` couldn't prove, at its `prove.result` assertion;
- the gate run id, its `report.json` relative to the main checkout (a task worktree's beside it as
  `../<worktree>/…`, or `<git dir of <worktree>>/…` in a brownfield clone), and
  `swiftgate events list --run <id>`.

The view holds at most 10 gating findings and 10 failing tests per gate run and counts the rest as
"+N more in the report". A task that ended `blocked` or `needs-replan` ends its task span there,
halted, and its popover and drawer say "Why it stopped": its newest gate run RED, no return of it
stored (`build check-return` rejected it, or none came back), or a halt of it, with the halt's
reason and its last gate run. A `gate-red` halt names the RED gate run it stopped on. A gate run
whose `report.json` no live checkout holds, as in a removed worktree, still shows its failed tiers,
rule counts and failing tests, and says its report isn't there; one that exists and doesn't read is
a damage row.

A worker's gate run, which no return or ledger event names, belongs to the task whose worktree's
run store holds it; failing that, to the task whose window holds its time.


## Privacy

A RED gate's finding messages are the 1 piece of report text the view keeps. Each is put on 1 line
and cut to 400 bytes. A path under a checkout becomes repo-relative; every other absolute path,
home path or `file://` URL becomes `<path>`. A message the guard still rejects reads "message
withheld". A finding with no file, or one outside the repository, shows no location.
