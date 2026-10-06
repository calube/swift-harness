# The run viewer

`swiftgate report` and `swiftgate view` show 1 build run as 1 page: what ran, in what order, for how
long, at what token count, and with what proof. Read this page to open a run's page, to emit a span
from a skill or workflow, or to read what a tab shows.

The page lives in the plugin's `viewer/` directory as plain HTML, CSS and JavaScript with no
framework or build step. It reads the events in [`telemetry.md`](telemetry.md), the plan's ledger
and the task returns, and never writes.

Related pages:

- [Live pages and saved reports](run-viewer-live.md): when a report is final, what a live page
  polls, and how the live server starts and stops.
- [Why a run failed](run-viewer-failures.md): the failure reasons and "Why it failed" sections.
- [Validation rows](run-viewer-validation.md): the Validation tab.

## Commands

| Command | Does |
|---|---|
| `swiftgate report --html <build run id> [--out <folder>]` | Writes the report folder (below), `reports/<build run id>/` under the run's state root unless `--out` names one. |
| `swiftgate report --html --from <folder>` | Writes `index.html` again from the folder's `view.json`, with no plan state or run store. |
| `swiftgate report --json <build run id> [--out <path>]` | Prints the run view, or writes it to `--out`. |
| `swiftgate view [--build-run <id>] [--port <n>]` | Serves the page live on `127.0.0.1` until interrupted: the newest build run on a free port, unless told otherwise. |
| `swiftgate view --ensure` | Prints the URL of the repository's 1 live viewer, starting it detached when none answers: see [the live server](run-viewer-live.md#the-live-server). |

The report folder holds 3 things and nothing else (no event store, ledger or spec page):

- `index.html`, 1 self-contained page that loads nothing from the network;
- `view.json`, the guarded run view it embeds;
- under `runs/`, a copy of each video and contact sheet its flows link.

`report` and `view` find `viewer/` through the plugin's `bin/swiftgate`. Both exit 1, BLOCKED, when
no plan holds the run, the reader can't read its state, or a string fails the guard. The message
names the field, never its value.

## Spans

A span times a phase no other event times. Skills and workflows emit them; the viewer draws them.

```sh
swiftgate events span start --phase <phase> --build-run <id> [--task <id>] [--role <role>] [--parent <span id>] [--end-parent <outcome>]
swiftgate events span end <span id> --outcome ok|red|halted|abandoned
```

- `start` prints the new 16-hex span id alone on stdout. Empty stdout means telemetry is off.
- `--end-parent <outcome>`, with `--parent`, first ends the parent span with that outcome when it
  is still open. A parent already ended or never started doesn't stop the start.
- `end` reads that start and records the ms since. It exits 1, writing nothing, when no start has
  the id or the span already ended.
- A span command exits 2 for a value outside its list.
- Spans go to the main checkout's store from any worktree.

The phases are `spec-read`, `discover`, `explore`, `plan`, `contract`, `worker`, `review`, `verify`,
`fix`, `final` and `ship`. A failed span call prints 1 line and never stops a skill or a task.

| Caller | Spans |
|---|---|
| build skill | `final`, and a `fix` span around the merge fixer, whose usage it ingests alone with `events ingest --agent-id` |
| `build-task.js` | The worker and the fix pass run their own `worker` or `fix` span. A plain span agent started beside each reviewer and verifier runs its `review` or `verify` span. Each has `--task` and the previous stage as parent. The workflow requires `buildRun` and `pluginRoot`, and every span runs `<pluginRoot>/bin/swiftgate`. |
| ship skill | `ship` |
| brownfield run skill | `spec-read`, `explore`, `plan`, `contract` and `final` |

Reviewers and verifiers hold no Bash. If a launch grants it Bash anyway, it may run only 1 span line
through the plugin's own `swiftgate` (`guard.reviewer-bash`, [`hooks.md`](hooks.md)).

## What the page shows

### Spans and requirements

- **Derived spans.** The reader derives run, task, merge, gate, tier and step spans from the ledger
  and gate events.
- **Steps.** A step with a start offset nests in place. The page lays a step with no offset end to
  end and marks it approximate.
- **Open spans.** An unended span stays open while the run goes. In a finished run it reads "never
  ended" and the footer names it.
- **Brownfield runs.** A brownfield run's phases before `build start` name the plan slug, and the
  plan's first build run folds them in, with spans derived from `discover.run` and `warmup.run`. A
  `swiftgate run`'s header names its time box; its cutoff shows as `budget` halts.
- **Requirements** come from the plan's design or spec page, or from a brownfield `PLAN.md`'s
  `## Requirements` and each task's `- Covers:` line.

### Tabs

The URL's `#token`, such as `#gates`, picks a tab; the default is Overview. Each tab's label carries
badges counted from the view.

| Tab | Shows | Badges count |
|---|---|---|
| Overview | the run's summary, the now strip in live mode, and a row per task | open halts |
| Timeline | spans with a 1x, 2x and 4x zoom; a bar opens a popover with its tool summary | red or halted spans, stalled tasks, spans that never ended |
| Board | the board module | blocked or halted tasks, tasks in progress |
| Graph | the plan graph module | merged tasks of all |
| Spec | requirements against tasks, commits and merge gates | uncovered requirements |
| Gates | every gate run, and a row per changed test `prove` ran | RED runs, a task's runs after its first RED, unproven tests |
| Tokens | tokens and dollar cost per task and role, "pending" for a running worker until its ingest | pending tasks |
| Validation | each validation row's newest `qa run` result: see [validation rows](run-viewer-validation.md) | red, unverified, waiting and abandoned rows |

The footer, under every tab, names what the reader couldn't read.

A red span, a blocked task and a `gate-red` halt say why, in the popover and in more detail in the
task drawer: see [why a run failed](run-viewer-failures.md).

### Board, graph and task details

The board and the graph are optional modules. The page inlines every `run-viewer-*.js` and
`run-viewer-*.css` present, and a module's tab shows once it draws.

- **Board.** It puts each task in a lane: queued, building, gating, review, merged or blocked. The
  blocked lane holds a task whose status is blocked, needs-replan or abandoned, and a task with an
  open halt.
- **Graph.** It draws the deps as SVG, in waves.
- **Task popover.** A card, node or Overview row opens it: status, column, deps, latest gate,
  commits, covers, and why the task failed or stopped.
- **Task drawer.** The popover's Open task opens it: the brief, properties, links and activity.

## Privacy

Every string in the view passes the event guard before either command writes or serves it. The view
drops the ledger's worktree path. It holds no prompt, source line, commit subject or tool output,
except a RED gate's findings and a red check's last output lines, without machine paths.
