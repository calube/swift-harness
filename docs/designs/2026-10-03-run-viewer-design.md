# swift-harness: the run viewer

<!-- RESUME
Status: DRAFT 2026-10-03: the user's 5 decisions in §3; open questions in §10.
Why: a build run spreads across skills, workflows, worktrees and shell commands. Nobody can see it as 1 thing,
either while it runs or after. Telemetry records most of it, but only as JSON lines and a text summary.
Builds on: the telemetry store and its guard, `EventStoreReader`, `BuildJoinReader`, the ledger, and the brownfield
`PLAN.md`.
Read first: this header, §3, §4 and §6.
-->

## 1. Purpose

Show 1 build run as 1 page: what ran, in what order, for how long, at what token count, and with what proof. The
operator uses it to steer a run. Reviewers use it to watch a run or to read its report afterwards, and it shows
them how the harness works.

### Goals

- `swiftgate report --html <build run id>` writes 1 static file that works offline and can go up as an Artifact.
- `swiftgate view` serves the same page on localhost and grows it as events arrive.
- No framework, no build step, no network beyond localhost.
- The report carries no machine path, prompt or source line.

### Non-goals

- Comparing runs, trends or regressions. That page serves prep and evals, and comes later.
- Dollar cost. The page shows tokens.
- Any control over the run. The page reads; it never writes.

## 2. What exists today

| Source | Holds | Gap for the page |
|---|---|---|
| `gate.run`, `gate.step`, `test.result` | verdicts, tier and step ms, every test | steps carry `ms` but no start, so parallel steps can't nest |
| `build.halt`, `build.resume` | halts and waits | none |
| `agent.usage` | tokens by task, role, build run | lands when a worker completes, not during |
| `BuildJoinReader` | task returns, ledger write sets, the run's ledger events | none |
| ledger `events.jsonl` | task transitions, merges, gate run ids, each with a time | none |
| `LedgerTask.covers` | the design `req-…` ids each task covers | no convention for `PLAN.md` |
| prove | a summary line in the gate report | no per-test record |
| nothing | spec read, discover, explore, plan, worker stages, final | no record at all |

## 3. Decisions

| # | Question | Decision | By |
|---|---|---|---|
| 1 | What form? | 1 self-contained HTML page with 2 modes. Report first: `swiftgate report --html` embeds the run's data. Live second: `swiftgate view` serves the same page on localhost and streams new events. Plain JS and CSS under `plugin/viewer/`. If time runs short, the report ships alone | user, 2026-10-03 |
| 2 | Who reads it? | The operator, and reviewers watching a run or reading its report. The live view replaces following scripts and workflows by hand | user, 2026-10-03 |
| 3 | What does the report hold? | A flame-graph timeline; spec to tasks, commits and gate verdicts; proof for each changed test; time and tokens, tokens over dollars | user, 2026-10-03 |
| 4 | What does the live view add? | A "now" strip per worker, the timeline growing, gates in progress, stalls and halts flagged | user, 2026-10-03 |
| 5 | Cross-run comparison? | A later, separate page for prep and evals; out of scope | user, 2026-10-03 |
| 6 | Which spans get emitted? | Only phases no event records; the reader derives task, merge and gate spans from the ledger and `gate.run` | this design |
| 7 | How does the page get data? | 1 JSON shape, `RunView`, embedded or streamed; the page has 1 `apply` function for both | this design |

## 4. Spans and proof: the data gap

### 4.1 `span.start` and `span.end`

2 new kinds in a new `span` stream. A start/end pair, not 1 event at the end, because the live view must show an
open span.

| Kind | Payload |
|---|---|
| `span.start` | `spanID` (16 hex), `parentSpan?`, `phase`, `buildRun`, `task?`, `role?` (`AgentRole`) |
| `span.end` | `spanID`, `outcome` (`ok`, `red`, `halted`, `abandoned`), `ms`; `parentID` is the start event |

`phase` is a closed enum: `spec-read`, `discover`, `explore`, `plan`, `contract`, `worker`, `review`, `verify`,
`fix`, `final`, `ship`. Each value names a phase that no other event times.

The reader derives the rest, per the telemetry rule that a derived kind never goes to the store:

| Span | Derived from |
|---|---|
| run | the build run's `startedAt` to its last event |
| task | the ledger transition into `in-progress` to `merged`, `abandoned` or the run's end |
| merge | the ledger `merge` event, inside the task span |
| gate | `gate.run` time minus `ms`, joined to a task by the task return's gate run id or the ledger `gate` event |
| tier, step | `gate.step`, nested under its `gate.run` through `parentID` |

`gate.step` gains `startMs?`, the step's offset from its gate's start. Without it, the page lays steps end to end
and marks them approximate.

### 4.2 Who emits

Skills and workflows call `swiftgate events span start --phase <phase> --build-run <id> [--task <id>] [--role
<role>] [--parent <spanID>]`, which prints the new `spanID`, and `swiftgate events span end <spanID> --outcome
<outcome>`, which reads the start and computes `ms`. Nothing writes JSONL by hand. Spans go to the main checkout's
store, as halts do, since the orchestrator runs every caller.

| Caller | Phases |
|---|---|
| build skill | `spec-read`, `discover`, `explore`, `plan`, `contract`, `final` |
| `build-task.js` | `worker`, `review`, `verify`, `fix`, each with `--task` and parent the previous stage's span |
| ship skill | `ship` |

An end with no start exits 1 and writes nothing. A start with no end shows as open in live mode and as "never
ended" in the report, cut at the run's last event.

### 4.3 `prove.result`

1 event per changed test that prove ran, written by `RunStore.record` beside `test.result`, with `parentID` its
`gate.run`.

| Field | Value |
|---|---|
| `test`, `testHashed?`, `target` | as `test.result` |
| `outcome` | `proven`, `passes-reverted`, `compile-only`, `crashed`, `skipped` |
| `proofBase?` | the commit prove reverted to |
| `assertion?` | `{file, line, kind}`: the first failure location of the reverted run, repo-relative; `kind` is `expect`, `require`, `xct-assert` or `other` |

## 5. Spec mapping

Design plans keep today's `covers` with the design's `req-…` ids. A `PLAN.md` adds the same thing in 2 lines:

```markdown
## Requirements
- req-offline-save: Save a draft without a network

### Task save-queue
Covers: req-offline-save
```

`plan import` copies `Covers:` into the ledger's `covers`. The existing coverage lint flags an unknown id and a
requirement no task covers. The reader takes each title from the heading or list line, cut to 120 bytes.

## 6. The data contract

`RunView` is a closed `Codable` struct in `SwiftGateDomain`. A pure `RunViewBuilder` folds events, the build join
and the plan into it. `RunViewReader` in `SwiftGateAdapters` reads the main store, each live task worktree's store
and every imported store, plus `BuildJoinReader` and the plan. The CLI wires them and writes.

```json
{
  "schemaVersion": 1, "cursor": "<opaque>",
  "run": {"id": "", "plan": "", "preset": "", "startedAt": "", "endedAt": null, "state": "running|done|halted"},
  "spec": [{"id": "req-…", "title": "", "tasks": ["save-queue"]}],
  "tasks": [{"id": "", "status": "", "model": "", "commits": ["sha"], "gateRun": "", "mergeGateRun": "",
             "tokens": {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0}}],
  "roles": [{"role": "build-worker", "tokens": {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0}}],
  "spans": [{"id": "", "parent": null, "phase": "", "task": null, "gateRun": null,
             "start": "", "end": null, "outcome": null, "approximate": false}],
  "gates": [{"runId": "", "task": null, "command": "", "verdict": "", "ms": 0, "tests": {"passed": 0, "failed": 0, "skipped": 0},
             "ruleCounts": {}, "steps": [{"tier": "", "step": "", "startMs": 0, "ms": 0, "verdict": ""}]}],
  "proofs": [{"gateRun": "", "task": "", "test": "", "outcome": "", "proofBase": "", "assertion": null}],
  "halts": [{"task": null, "reason": "", "at": "", "answer": null, "waitMs": null}],
  "damage": [{"source": "", "reason": ""}]
}
```

- **Embedded.** `report --html` writes `<script type="application/json" id="run-view">`, with `<` escaped as
  `<`, into a copy of `viewer/run-viewer.html` with its CSS and JS inlined. The template comes from the plugin
  root, as bootstrap reads `templates/`. The default output goes under the run state root as
  `reports/<build run id>.html`; `--out` overrides it.
- **Streamed.** `view` serves `GET /` (the page), `GET /view.json` (a full `RunView`) and `GET /changes?after=
  <cursor>`, which returns a partial `RunView` and a new cursor. The page merges each array by id. The cursor is
  the byte offset of each active stream file plus the ledger log's length.
- **Damage.** An unreadable file shows in `damage` and in the page footer, never as a silent gap.

## 7. Layout

```
+---------------------------------------------------------------+
| run 2026…-a1  plan offline-drafts  preset default   GREEN     |  header
| 41m wall   1.9M tokens   3 tasks   12 proofs   0 halts         |
+---------------------------------------------------------------+
| NOW  save-queue: review 3m | draft-ui: gate push 1m | idle     |  live only
+---------------------------------------------------------------+
| 0m        10m        20m        30m        40m                |  timeline
| [spec][plan ][contract]                          [final]      |  (scrolls
|              [save-queue: worker][review][gate][m]            |   inside)
|              [draft-ui: worker   ][gate: t0 t1 prove][m]      |
+-------------------------------+-------------------------------+
| SPEC          tasks  commits  | PROOF  test  task  outcome    |
| req-offline-save  2   3  GREEN|  saveQueuesWhenOffline  proven|
+-------------------------------+-------------------------------+
| TOKENS AND TIME per task and role, bars                       |
| GATES  run id, tiers, steps, verdict, rule counts             |
| footer: damage, dropped events, schema version                |
+---------------------------------------------------------------+
```

| Region | Shows |
|---|---|
| header | run id, plan, preset, state, wall time, total tokens, task, proof and halt counts |
| now strip | live mode: 1 card per worker slot with task, open phase, elapsed and last event age; stall and halt badges |
| timeline | spans nested by time; colour by outcome; click for a detail panel with ids and ms |
| spec | each requirement, its tasks, merged commits and the merge gate verdict; uncovered ones flagged |
| proof | each changed test: outcome ("failed with the change reverted"), assertion location, proof base, gate run id |
| tokens and time | per task and per role, input, output and cache tokens, wall time |
| gates | each gate run with tiers, steps, tests and rule counts |

A stall is an open task span with no event of that task for the preset's `stall_min`. A halt shows from
`build.halt` until its `build.resume`. Tokens in live mode lag until the worker's ingest.

## 8. Privacy

Every `RunView` string comes from a guarded event, a ledger id, a commit sha or a requirement title. The builder
drops `LedgerTask.worktree`, the 1 absolute path the ledger holds. Before rendering, `report` and `view` run
`EventPayloadGuard` over every string in the `RunView`. A reject fails the command and names the field. No commit
subject, finding message, prompt, test source or assertion text enters it. `view` binds `127.0.0.1` only.

## 9. Testing

`RunViewBuilder` tests use events captured from a real build run, recorded in the fixtures README. A page smoke
test loads the report in a headless browser through the existing walk harness, and checks each region renders and
the console stays empty.

## 10. Open questions

| # | Question | Recommendation |
|---|---|---|
| 1 | Show the assertion's source line in the proof table? | No. Show `file:line` and its kind; a published report must carry no source |
| 2 | `view` transport: server-sent events or polling `/changes` each second? | Polling: 1 short request, no long-lived connection in a Foundation server, same cursor contract |
| 3 | Run `events ingest` every minute during live mode, so tokens don't lag? | No. Ingest stays at worker completion; the page marks running tasks' tokens as pending |
| 4 | Build the page on HeroUI, the React and Tailwind component library? For: finished components at no design cost. Against: it needs React, Tailwind and a bundle step, so `plugin/` carries a node build or a committed bundle; it breaks decision 1's "no framework, no build step"; the single-file report and the Artifact need all of it inlined | Plain HTML and CSS for now, with tokens for radius, spacing and palette modelled on HeroUI's look. A HeroUI port stays a later option |

## 11. Tasks for a later plan

1. `span.start`, `span.end`, `prove.result` and `gate.step.startMs`, with the guard and the stream.
2. `swiftgate events span start|end`.
3. `RunView`, `RunViewBuilder` and `RunViewReader`, with captured fixtures.
4. `plugin/viewer/` page: report regions, starting from the report mock.
5. `swiftgate report --html`, the guard pass and the page smoke test.
6. Span calls in the build skill, `build-task.js` and the ship skill; `Covers:` in `plan import`.
7. `swiftgate view`, `/changes` and the now strip.

Tasks 1 to 4 run in parallel after a contract commit holding the types; 5 needs 3 and 4; 6 needs 2; 7 follows 5.
The report ships after 5 and 6.
