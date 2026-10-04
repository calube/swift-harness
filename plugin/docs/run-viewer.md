# The run viewer

`swiftgate report` and `swiftgate view` show 1 build run as 1 page: what ran, in what order, for how long, at
what token count, and with what proof. The page lives in the plugin's `viewer/` directory as plain HTML, CSS
and JavaScript with no framework or build step. It reads the events in [`telemetry.md`](telemetry.md), the
plan's ledger and the task returns, and never writes.

## Commands

- `swiftgate report --html <build run id> [--out <path>]` writes 1 self-contained page, with its styles,
  scripts and data inlined, to `reports/<build run id>.html` under the run's state root unless `--out` names a
  path. It loads nothing from the network, so it works offline and you can publish it as is.
- `swiftgate report --json <build run id> [--out <path>]` prints the run view, or writes it to `--out`.
- `swiftgate view [--build-run <id>] [--port <n>]` serves the page live on `127.0.0.1`, for the newest build
  run and on a free port unless told otherwise, and runs until interrupted.
- `swiftgate events span start --phase <phase> --build-run <id> [--task <id>] [--role <role>] [--parent <span id>]`
  prints the new 16-hex span id alone on stdout; empty stdout means telemetry is off.
  `swiftgate events span end <span id> --outcome ok|red|halted|abandoned` reads that start and records the ms
  since.

`report` and `view` find `viewer/` through the plugin's `bin/swiftgate`. Both exit 1, BLOCKED, when no plan
holds the run, the reader can't read its state, or a string fails the guard; the message names the field, never its
value. `events span end` exits 1, writing nothing, when no start has the id or the span already ended. A span
command exits 2 for a value outside its list. Spans go to the main checkout's store from any worktree.

## Who emits spans

Skills and workflows emit spans only for phases no other event times: `spec-read`, `discover`, `explore`, `plan`, `contract`,
`worker`, `review`, `verify`, `fix`, `final` and `ship`. A failed span call prints 1 line and never stops a
skill or a task.

| Caller | Spans |
|---|---|
| build skill | `final`, and a `fix` span around the merge fixer, whose usage it ingests alone with `events ingest --agent-id` |
| each `build-task.js` stage agent | its own `worker`, `review`, `verify` or `fix` span, with `--task` and the previous stage as parent; the workflow requires `buildRun` and `pluginRoot`, and stages run `<pluginRoot>/bin/swiftgate` |
| ship skill | `ship` |
| brownfield run skill | `spec-read`, `explore`, `plan`, `contract` and `final` |

A reviewer's or verifier's Bash may run only 1 span line through the plugin's own `swiftgate`
(`guard.reviewer-bash`, [`hooks.md`](hooks.md)).

## What the page shows

The reader derives run, task, merge, gate, tier and step spans from the ledger and gate events. A step with
a start offset nests in place; the page lays a step with no offset end to end and marks it approximate. An
unended span stays open while the run goes; in a finished run it reads "never ended" and the footer names
it. A brownfield run's phases before `build start` name the plan slug, and the plan's first build run folds
them in, with spans derived from `discover.run` and `warmup.run`. Requirements come from the plan's design or
spec page, or from a brownfield `PLAN.md`'s `## Requirements` and each task's `- Covers:` line.

The page has a header and a span timeline with a 1x, 2x and 4x zoom, where each bar opens a popover with its
tool summary. Below sit requirements against tasks, a row per changed test `prove` ran, tokens per task and
role, every gate run, and a footer naming what the reader couldn't read. A running worker's tokens read
"pending" until its ingest. A `swiftgate run`'s header also names its time box: its minutes, where they came
from, and the times starts stop, the cutoff comes and the box ends. The cutoff's decisions show as `budget`
halts, each answered at once: `continue` for the run and for a task let merge, `abandon` for a task dropped.

A red span, a blocked task and a `gate-red` halt say why, in the popover and in more detail in the
task drawer: see [why a run failed](run-viewer-failures.md).

The board and the plan graph are optional modules: the page inlines every `run-viewer-*.js` and `.css`
present. The board puts each task in queued, building, gating, review, merged or a blocked lane, which also
holds a task with an open halt. The graph draws the deps as SVG in waves left to right. A card or node opens
the task drawer: the brief when the plan has one, properties, links and activity.

## Live mode

`view` answers `GET /`, `/view.json` and `/changes?after=<cursor>`, the rows changed since that cursor and a
new one, and 404 for anything else. A changed row comes whole, its failure or block reason
included. An unknown cursor gets the whole view. A request whose `Host` isn't
`127.0.0.1` or `localhost` at its port gets 403, so a page elsewhere can't reach it through a rebound name.

The page polls `/changes` each second, merges rows by id, and keeps polling after a failure, which it shows
in the header. A now strip shows each running task's open phase, elapsed time and last event age, a stall
badge once the preset's `stall_min` passes with no event of that task, and a halt badge until the resume.

## Privacy

Every string in the view passes the event guard before either command writes or serves it. The view drops
the ledger's worktree path and holds no prompt, source line, commit subject or tool output.  A RED gate's
finding messages are the 1 piece of report text it keeps, with machine paths taken out.
