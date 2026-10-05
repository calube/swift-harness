# Run viewer: implementation plan

<!-- RESUME
Status: FROZEN at the harness freeze (2026-10-05). main is at the freeze tag `harness-freeze-2026-10-05`, and all 7 practice apps pass the brownfield one-shot. Results and the open follow-ups, none started: docs/handoffs/2026-10-05-practice-app-results.md. No wave is in flight and none is next.
History (before the freeze): the report, live mode (`swiftgate view`), span events, the brownfield spans and the
docs merged; plugin/docs/run-viewer.md describes what shipped. The page doesn't yet render the deferred list.
Spec: docs/designs/2026-10-03-run-viewer-design.md (approved 2026-10-03, 17 decisions in its §3, 15 of them the
user's). Read its RESUME header, §3, §4, §6 and §7.
Scope: `span.start`, `span.end`, `prove.result`, `agent.tools` and `gate.step.startMs`; `swiftgate events span
start|end`; `RunView`, `RunViewBuilder` and `RunViewReader` with fixtures captured from a real build run; the
`plugin/viewer/` page with its popover, zoom and task drawer, seeded from the report mock; `swiftgate report --html|--json`
with the guard pass and a headless page test; span calls in the build skill, the event loop, `build-task.js` and
the ship skill; `swiftgate view` with `/changes` polled each second and the now strip; `Covers:` in `PLAN.md`
and span calls in the brownfield run skill, after the brownfield tasks that own those files; then, trailing, the
kanban board and the plan graph as optional page modules.
Out of scope: cross-run comparison, dollar cost, any control of a run from the page, a HeroUI port.
Time box (user, 2026-10-03): the whole harness in about 24 hours, beside the brownfield plan. The static report
ships before live mode: waves 1 to 3 hold the report, wave 4 adds live mode. The board and the graph trail
(user, 2026-10-03: "build async to not disrupt the speed run"): they run when the pool has room and merge last.
Resume: read this header, then "Wave map", then your task's section (grep for the task id). Grep the spec by §.
Orchestrator procedure: docs/handoffs/subproject-2-orchestrator-runbook.md, with the changes in "How to work this plan".
Interfaces note: docs/handoffs/run-viewer-interfaces.md (the first wave's merge creates it; each wave appends).
Build for correctness (user decision): every task is surface-first, on opus, through the push + prove merge gate.
Progress: git log. Update this header if work resumes after the freeze.
-->

## Decisions made while planning

Rows marked "user, 2026-10-03" restate the design's §3 decisions where the plan leans on them. The other rows are
the plan's own choices within them, for the orchestrator to confirm or overturn at the first wave merge.

| Decision | Evidence | Choice | Needs |
|---|---|---|---|
| Report first | design §3 decision 1; user, 2026-10-03 | Waves 1 to 3 build the report, and every live-mode task waits for `report-writes-the-html` to merge. If time runs short, the report ships alone | user, 2026-10-03 |
| The page starts in wave 1 | the page compiles against no Swift type; design §6 fixes every JSON key | `viewer-page-renders-the-report` runs beside the contract, against §6's keys exactly. Its unit inputs are small `RunView` objects built inside the test. The report task's headless test renders the real captured run and catches any key drift | — |
| Sample data | the mock holds sample data inline | The plan's commit copies the mock unchanged to `V/run-viewer.html`, so the seed outlives the scratch directory it came from. The page task's first commit strips the data. The page then ships with no data. `report` embeds a real `RunView`; the headless test renders the run `run-fixtures-are-captured` records. No `RunView` JSON is hand-written under `F/` | user, 2026-10-03 |
| JSON keys and times | design §6 | `RunView` encodes §6's keys. `start`, `end` and `at` are ISO-8601 strings with milliseconds; the page computes offsets from `run.startedAt`. A running task's `tokens` is `null`, which the page shows as "pending" (decision 10) | user, 2026-10-03 |
| Where `prove.result` goes | design §4.3 puts it beside `test.result` | Stream `test`, `parentID` its `gate.run`. Written by `RunStore.record` from a new `proofs` argument | — |
| `agent.tools` | design §4.4, decision 14 | 1 event per agent per 60 s window in stream `usage`. `ToolKind` is closed: `Read`, `Edit`, `Write`, `MultiEdit`, `NotebookEdit`, `Grep`, `Glob`, `Bash`, `Agent`, `Skill`, `WebFetch`, `WebSearch`, `TodoWrite`, `ToolSearch`, and `mcp` for every `mcp__…` name. Any other name counts in `otherCount`. The reader attributes a window to spans; ingest knows no span | user, 2026-10-03 |
| Where spans go | design §4.2 | `events span` writes through the store `BuildHaltLog` resolves, so spans land where halts land. `end` reads its start from that store and computes `ms`; an end with no start exits 1 and writes nothing | — |
| No new rule ids | design §6 to §8 report damage and guard rejects as command errors and page lines, not findings | This plan adds no row to the rule id index. A task that finds it needs one stops and asks the orchestrator, who adds the row after `brownfield-contract` merges, in a "Run viewer" subsection | orchestrator |
| Page files | design §3 decision 1, decision 11 | `plugin/viewer/run-viewer.html`, `run-viewer.css`, `run-viewer.js`, and `run-view-model.js` (pure functions: `apply`, lanes, zoom, label fit, stalls, formats). `report` inlines the CSS and both scripts into a copy of the HTML. Tokens follow HeroUI's radius, spacing, palette and type scale as CSS custom properties, light and dark. System font stack only, since the report works offline | user, 2026-10-03 |
| The local server | design §3 decision 9; no new dependency | `view` serves through Network.framework's `NWListener`, bound to `127.0.0.1`, behind a `LocalHTTPServing` protocol in `A/RunView/`. No package joins `Package.swift` | user, 2026-10-03 |
| Headless page tests | design §9; Node 22 has a global `WebSocket`; Chrome is installed on this machine | `tests/headless_chrome.mjs` starts Chrome with `--headless=new --remote-debugging-port=0` and drives it over the DevTools protocol: load a file, read console errors and exceptions, press keys, read DOM state. With no Chrome on the machine a test prints a skip line naming the missing binary and passes; the report says so. Each script stays under 15 s, inside `RepositoryScriptTests`' 60 s timeout (issue #8) | — |
| Default report path | design §6; brownfield `state-root-seam` owns `RunLayout` and every `.harness` literal | `report --html` writes `reports/<build run id>.html` under the state root through `StateRoot`. So `report-writes-the-html` waits for `state-root-seam` | — |
| Fixtures from a real run | CLAUDE.md, user, 2026-10-03 | No ledger state exists in this checkout, so `run-fixtures-are-captured` runs a real headless build of a 2-task plan in a scratch clone of `examples/SampleApp`. `span-run-is-captured` repeats it once spans, proofs and tool summaries record. Tool transcripts come from a throwaway `claude -p` session in a `mktemp -d` directory, as the existing `Transcripts/` fixtures did | user, 2026-10-03 |
| Optional page modules | design decisions 15 and 16; user, 2026-10-03: the board and the graph never block the report or the live view | The core page exposes `window.runViewer.register(name, {render(view, mount), apply(view)})` and `window.runViewer.openPopover(anchor, rows)` and `window.runViewer.openTaskDrawer(taskID)`, and holds an empty, hidden mount per module. `report` and `view` inline every `V/run-viewer-*.js` and `V/run-viewer-*.css` present, in name order. A module adds only its own files, so the 2 trailing tasks share no file with the core page or with each other | user, 2026-10-03 |
| Task shape for the board and the graph | design §6 "Task shape" | The contract adds `deps`, `writes`, `gate`, `covers`, `createdAt`, `mergedAt` and an optional `brief` to `RunView.tasks`, and the builder fills all but `brief` from the ledger in wave 2. The trailing modules then need no Swift change | — |
| The task drawer | design decision 17; user, 2026-10-03 | The drawer sits in the core page, so the board and the graph only call `window.runViewer.openTaskDrawer(taskID)`. Its wave comes from the deps and its activity from `spans`, `gates`, `halts` and `commits`, in the page | user, 2026-10-03 |
| Where a brief comes from | design §6; brownfield's `PLAN.md` shape gains `- Why:`, `- Scope:`, `- Acceptance:` and `- Out of scope:` per task | Brownfield's `plan import` writes the brief into the plan state. The reader takes it from there and never parses markdown. `brownfield-runs-carry-spans-and-covers` maps it, using the key names brownfield's interfaces note records. A task with no brief, as in every owned-repository plan today, shows the drawer without the brief sections | — |
| Generic harness | memory, user | The capture plan's spec is a small, generic change to `examples/SampleApp`. No task names a product, an interview, or an app beyond the repository's own example | user |

## How to work this plan

The runbook applies as written, with these changes:

- **Model.** Every worker on `opus`.
- **Surface first.** Each worker commits its new API as a behaviour-free surface commit, then tests and behaviour,
  and proves at it (worker brief pitfall 10), and runs `swiftgate surface-check <surface sha>` on it. For a page
  task the surface commit is the seed page, with today's behaviour and no new function bodies.
- **Merge gate.** Push + `prove --base main` on 1 integration worktree. With more than 1 surfaced branch in a batch,
  merge every surface commit first and prove at that merge.
- **1 pool with the brownfield plan.** Both plans draw workers from 1 pool the orchestrator sizes to the memory
  watchdog (brownfield's own cap is 5). When both plans have a ready task, the one on its plan's critical path
  starts first. Builds stay serialised through the build lock's ticket queue. A run viewer wave starts a task as
  soon as its deps merge; it doesn't wait for the rest of its wave.
- **Speed mode (user, 2026-10-03).** A gate whose only failure is the node walk tests' 60 s timeout (issue #8)
  still merges; the commit body names the run id. Don't wait for load to drop.
- **Id policy.** Task ids and wave numbers never appear in code, comments, test names or commit messages.
- **Network.** Only the 2 capture tasks call a model; no test reaches the network. `view` binds `127.0.0.1` only.
- **Tests never touch shared state.** A test that writes events, ledger or plan state does it in a temp repository
  with its own git dir; none resolves this checkout's common dir.
- **Paths.** `D/` = `plugin/gate/Sources/SwiftGateDomain/`, `A/` = `plugin/gate/Sources/SwiftGateAdapters/`,
  `C/` = `plugin/gate/Sources/SwiftGateCLI/`, `TD/` `TA/` `TC/` = `plugin/gate/Tests/SwiftGate{Domain,Adapters,CLI}Tests/`,
  `F/` = `plugin/gate/Tests/Fixtures/`, `P/` = `plugin/`, `V/` = `plugin/viewer/`, `R/` = `D/RunView/`.

### Shared files with the brownfield plan

The brownfield plan runs at the same time. Its contract reserves `discover.run` and `warmup.run`, adds `area?` to
`gate.step` and `baselineCount` to `gate.run`, and leaves a span seam: 1 named function per run phase, which this
plan reads through those 2 events and never wraps in Swift. Its "Merge points" table names the files below; this
table says who edits each one and when.

| File | Brownfield editor (wave) | Run viewer editor (wave) | How the 2 avoid a conflict |
|---|---|---|---|
| `D/Events/HarnessEvent.swift` (event kinds and streams) | `brownfield-contract` (1) | `run-view-contract` (1) | Both add cases only. The orchestrator merges `brownfield-contract` first; `run-view-contract` rebases onto it before its merge gate. If ours is ready and theirs isn't, ours merges and theirs rebases |
| `D/Events/GateEvents.swift` (`gate.step` fields) | `brownfield-contract` (1): `area?`, new steps, `baselineCount` | `run-view-contract` (1): `startMs?` | as above; each adds 1 optional field and its coding key |
| `D/Events/TranscriptUsage.swift` (`AgentRole`) | `brownfield-contract` (1): `explorer`, `classifier` | nobody | `agent.tools` lives in its own file, `D/Events/AgentToolsEvent.swift`, and reuses `AgentRole` as merged |
| `C/SwiftGate.swift`, `TC/NewSubcommandRegistrationTests.swift` | `brownfield-contract` (1) | `run-view-contract` (1): `report`, `view` | as for `HarnessEvent.swift`: append to the subcommand list and the test's table; keep both sides |
| `P/docs/standards.md` rule id index, `TC/RuleIndexTests.swift` | `brownfield-contract` (1) | nobody | this plan adds no rule id (see decisions) |
| `P/docs/telemetry.md` | `docs-describe-the-brownfield-profile` (4) | `tool-summaries-are-ingested` (2): the `agent.tools` row and the "never recorded" exception; `docs-describe-the-run-viewer` (5): the span and proof rows | ours edit only those rows and that paragraph. Theirs edits in its wave 4; the later merge rebases and keeps both sides |
| `docs/index.md` | `trial-repos-are-proposed` (1): its own row | this plan's commit: a new "run viewer" row; `docs-describe-the-run-viewer` (5) | separate rows; keep both sides |
| `docs/capabilities.md`, `README.md` | `docs-describe-the-brownfield-profile` (4) | `docs-describe-the-run-viewer` (5) | separate sections; the later merge rebases |
| `RunLayout`, `.harness` literals, `StateRoot` | `state-root-seam` (1) | `report-writes-the-html` (3) adds `reports/` through `StateRoot` | ours waits for `state-root-seam` |
| `C/ChangedTestChecks.swift` | nobody | `prove-results-are-recorded` (2) | brownfield prove is new code in `C/BrownfieldProve.swift` |
| `C/Commands/CheckCommand.swift` | `brownfield-contract` (1): tier routing | nobody | `prove.result` flows through `GateRun.swift` and `RunStore.record`, not `CheckCommand` |
| `P/workflows/build-task.js`, `tests/build_task_workflow_test.mjs` | `executor-takes-the-brownfield-preset` (2) | `workflow-marks-worker-stages` (3) | ours waits for theirs to merge |
| `tests/skill_commands_test.mjs` | `run-skill-orchestrates-the-run` (2): new rows | `skills-mark-their-phases` (3): new rows | append only; keep both sides |
| `B/LivePlan.swift`, `P/skills/run/SKILL.md`, `P/skills/run/references/plan-shape.md` | `plan-import-derives-the-ledger`, `run-skill-orchestrates-the-run` (2) | `brownfield-runs-carry-spans-and-covers` (4) | ours waits for both to merge |
| `<common>/swift-harness/plans/<slug>/plan.json` and `ledger.json` (the brief) | `plan-import-derives-the-ledger` (2) writes it | `brownfield-runs-carry-spans-and-covers` (4) reads it | ours reads and never writes; the key names come from brownfield's interfaces note at its wave 2 merge |
| `F/README.md` | each capture task appends its section | `run-fixtures-are-captured` (1), `span-run-is-captured` (4) | append only; keep both sides |

### Merge points inside this plan

| File | Edited only by |
|---|---|
| `D/Events/SpanEvents.swift`, `D/Events/ProveResultEvent.swift`, `D/Events/AgentToolsEvent.swift`, `R/RunView.swift` | `run-view-contract` |
| `R/RunViewBuilder.swift`, `R/RunViewSpans.swift` | `run-view-builder-derives-spans`, then `brownfield-runs-carry-spans-and-covers` (discover and warm-up spans) |
| `R/RunViewEmittedEvents.swift` | created as a stub by the contract, filled by `builder-folds-emitted-events` |
| `R/SpanToolAttribution.swift` | created as a stub by the contract, filled by `tool-summaries-are-ingested` |
| `A/RunView/RunViewReader.swift` | `run-view-reader-collects-stores` (2), then `view-serves-live-changes` (4, the cursor) and `brownfield-runs-carry-spans-and-covers` (4, briefs); the 2 wave 4 edits touch separate functions, and the later merge rebases |
| `C/Commands/EventsCommands.swift` | `run-view-contract` (registers `span`), then `tool-summaries-are-ingested` (ingest) |
| `V/*` | `viewer-page-renders-the-report`, then `page-shows-the-now-strip`. `report-writes-the-html` reads them and never edits them |
| `tests/headless_chrome.mjs` | `viewer-page-renders-the-report` |
| `V/run-viewer-board.*`, `tests/run_viewer_board_test.mjs` | `kanban-board-shows-tasks` |
| `V/run-viewer-graph.*`, `tests/run_viewer_graph_test.mjs` | `plan-graph-draws-the-deps` |

### Risks

| Risk | Where | Mitigation |
|---|---|---|
| The real capture run takes long or fails, and the builder waits on it | `run-fixtures-are-captured` | It starts first in wave 1, on a 2-task plan with a small generic spec. If the run halts, the task captures what the store holds at the halt and says so; a halted run is still a real run and exercises `halts` |
| Headless Chrome adds load and trips the 60 s script timeout (issue #8) | page and report tasks | Each script starts Chrome once, loads 1 page, and stays under 15 s; the speed-mode rule covers an issue #8 timeout |
| `RunView` keys drift between Swift and the page | wave 1 | The page reads §6's keys; `report-writes-the-html`'s headless test renders the real run through the real encoder and fails on any region left empty |
| A capture holds a machine path | capture tasks | The ledger's `worktree` holds a `$TMPDIR` path from the scratch clone; the builder test asserts it never reaches `RunView`. The README's grep allows only the `mktemp -d` prefix |
| Tool paths leak outside the repository | `tool-summaries-are-ingested` | Paths become repo-relative against the git top level of the line's `cwd` before the guard; anything else counts in `droppedPaths`. The captured session reads 1 path outside its directory on purpose |
| The trailing modules take pool slots the speed run needs | `kanban-board-shows-tasks`, `plan-graph-draws-the-deps` | They start last in any pool round and merge after `view-serves-live-changes`. The orchestrator may drop either; nothing depends on them |
| Brownfield tasks this plan waits on slip | waves 3 and 4 | Only `workflow-marks-worker-stages` and `brownfield-runs-carry-spans-and-covers` wait on brownfield wave 2, and neither blocks the report. `state-root-seam` is brownfield wave 1 |

## Wave map

| Wave | Tasks | Why |
|---|---|---|
| 1 | `run-view-contract`, `run-fixtures-are-captured`, `viewer-page-renders-the-report` | the types every Swift task compiles against, a real run to fold, and the page, which needs no Swift type; disjoint files |
| 2 | `run-view-builder-derives-spans`, `run-view-reader-collects-stores`, `span-events-are-recorded`, `prove-results-are-recorded`, `tool-summaries-are-ingested` | each needs only the contract and its fixtures; every write set is its own files or a stub the contract made for it |
| 3 | `report-writes-the-html`, `builder-folds-emitted-events`, `skills-mark-their-phases`, `workflow-marks-worker-stages`, `page-shows-the-now-strip` | the report needs the builder, reader and page; the emitted events need their writers; the skills need `events span`. The now strip runs here but merges after the report |
| 4 | `view-serves-live-changes`, `span-run-is-captured`, `brownfield-runs-carry-spans-and-covers` | live mode follows the report; the second capture needs every writer; the brownfield files merge in brownfield wave 2 |
| 5 (trailing) | `kanban-board-shows-tasks`, `plan-graph-draws-the-deps`, `docs-describe-the-run-viewer` | the 2 modules need only the core page and the builder, so they may start earlier when the pool has room, but they merge after live mode; the docs state what merged |

The static report ships when `report-writes-the-html`, `builder-folds-emitted-events` and `skills-mark-their-phases`
merge: wave 3. `workflow-marks-worker-stages` adds worker stages to it when brownfield's executor task has merged.
Live mode ships when `view-serves-live-changes` and `page-shows-the-now-strip` merge: wave 4. The board and the graph
add to either mode whenever they merge, and neither mode waits for them.

Critical path: `run-view-contract` → `run-view-builder-derives-spans` → `report-writes-the-html` (the report:
3 worker lengths plus 3 merge gates) → `view-serves-live-changes` (live mode: 4 and 4). `run-fixtures-are-captured`
runs beside the contract and must merge before the builder's tests can pass.

### `run-view-contract`
- Deps: none · Gate: push · Model: opus · estLines: 600
- Writes: `D/Events/SpanEvents.swift`, `D/Events/ProveResultEvent.swift`, `D/Events/AgentToolsEvent.swift`, `D/Events/HarnessEvent.swift`, `D/Events/GateEvents.swift`, `R/RunView.swift`, `R/RunViewInput.swift`, `R/RunViewBuilder.swift` (stub), `R/RunViewEmittedEvents.swift` (stub), `R/SpanToolAttribution.swift` (stub), `A/RunView/RunViewReading.swift` (protocol), `A/RunView/RunViewReader.swift` (stub), `C/Commands/ReportCommand.swift`, `C/Commands/ViewCommand.swift`, `C/Commands/EventsSpanCommand.swift` (stubs), `C/Commands/EventsCommands.swift` (registers `span`), `C/SwiftGate.swift`, `TC/NewSubcommandRegistrationTests.swift`, `TD/SpanEventsTests.swift`, `TD/RunViewContractTests.swift`
- Does: design §4, §6. Surface commit: every type, enum case, protocol and stub, with today's behaviour unchanged. `SpanPhase` (`spec-read`, `discover`, `explore`, `plan`, `contract`, `worker`, `review`, `verify`, `fix`, `final`, `ship`) and `SpanOutcome` (`ok`, `red`, `halted`, `abandoned`) are closed. `SpanStartEvent {spanID, parentSpan?, phase, buildRun, task?, role?}` and `SpanEndEvent {spanID, outcome, ms}` in a new `span` stream. `ProveResultEvent {test, testHashed?, target, outcome, proofBase?, assertion?}` with `ProveResultOutcome` (`proven`, `passes-reverted`, `compile-only`, `crashed`, `skipped`) and `ProveAssertion {file, line, kind}`, `kind` closed (`expect`, `require`, `xct-assert`, `other`), in stream `test`. `AgentToolsEvent` and `ToolKind` per §4.4 and the decisions table, in stream `usage`. `GateStepTiming` and `GateStepEvent` gain `startMs: Int?`. `RunView` and its nested structs encode §6's keys, `tokens` optional, each span's `tools` optional, and each task's `deps`, `writes`, `gate`, `covers`, `createdAt`, `mergedAt` and optional `brief {title, why, designRef, scope, acceptance, outOfScope}`. `RunViewInput` gains `briefs`, a map from task id to brief, empty until a reader fills it. `RunViewInput {buildRun, events, join, requirements, damage}`. `RunViewBuilder.build(_:) -> RunView` returns the run header and empty arrays. `RunViewEmittedEvents.fold(_:into:)` and `SpanToolAttribution.attribute(windows:spans:)` return their input and an empty map. `RunViewReading.read(buildRun:) throws -> RunViewInput`; the stub reader returns an empty input. `report --html|--json <build run> [--out <path>]`, `view [--build-run <id>] [--port <n>]`, `events span start --phase … --build-run … [--task] [--role] [--parent]` and `events span end <spanID> --outcome …` parse their flags and exit through `StubCommand.notImplemented`.
- Span seam: none (declarations only).
- Tests, each failing before its code: a span start with `phase = "warmup"` fails decoding naming the field (catches an open string). A `spanID` of 15 or 17 hex characters fails. A `prove.result` with `outcome = "maybe"` fails. An `agent.tools` payload round-trips, and `EventPayloadGuard` rejects 1 holding an absolute path in `files` (catches the guard skipping the new kind). A `gate.step` line written before this change decodes with `startMs == nil` (catches a required field breaking old stores). A `RunView` encodes §6's top-level keys and no other (catches a renamed key the page won't read). Each stub command exits 2 (registration test).

### `run-fixtures-are-captured`
- Deps: none · Gate: push · Model: opus · estLines: 60 (fixture bytes aside) · Needs: a model (headless build)
- Writes: `F/RunView/build-run-1/{SOURCE, events/<stream>.jsonl, ledger.json, ledger-events.jsonl, returns/<task>.json, plan.md}`, `F/Transcripts/<session>.jsonl` (the tool session), `F/README.md` ("Run view" and a "Transcripts" addition)
- Does: design §9, §4.4. In a `mktemp -d` clone of this repository, bootstrap nothing new: write a generic 2-task spec for `examples/SampleApp` with 2 requirements, run `/swift-harness:plan` and `/swift-harness:build` headless to the end with `CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0`, then `swiftgate events ingest`. Copy each event stream for the build run, the ledger, its `events.jsonl` and the task returns, unedited. For tools: in a fresh `mktemp -d` git repository, run `claude -p` asking for 1 `Read`, 1 `Edit`, 1 `Write`, 1 `Grep`, 1 `Bash ls`, 1 `Read` of `/etc/hosts`, and 1 subagent that reads 1 file. Copy both transcripts with the existing `jq` filter, keeping `cwd` and each `tool_use` and `tool_result` content block. `SOURCE` holds the commands, the Claude Code version, the date and the build run id. Nobody edits a file after capture.
- Tests: none of its own (fixture task). The builder, reader, tools and report tasks consume every file; a file no test reads fails that wave's review.

### `viewer-page-renders-the-report`
- Deps: none · Gate: push · Model: opus · estLines: 800
- Writes: `V/run-viewer.html`, `V/run-viewer.css`, `V/run-viewer.js`, `V/run-view-model.js`, `tests/headless_chrome.mjs`, `tests/run_viewer_model_test.mjs`, `tests/run_viewer_page_test.mjs`
- Does: design §6 (keys), §7, decisions 8, 11, 12 and 13. The plan's own commit put the report mock at `V/run-viewer.html` as the seed, unchanged, sample data and font link included. Surface commit: remove its inline sample data, leaving `<script type="application/json" id="run-view">` empty, and its Google Fonts link; split its CSS and script into the 3 files with no other change. Then: read §6's keys (ISO times, `tokens` optional) through `run-view-model.js`, whose pure functions are `apply(view, partial)` (merge each array by id), `lanes(spans)` (nest children under parents; parallel tasks on separate rows), `scale(zoom, width)` for 1x, 2x and 4x, `labelFits(text, px)`, and the formats. The page renders the header, timeline, spec, proof (`file:line` and kind, never source), tokens and time ("pending" for `null`), gates and the damage footer. A bar is a `<button>`; clicking it or pressing Enter opens a popover anchored to it with ids, ms and the tool summary. Under 640 px the popover is a bottom sheet. Escape or an outside click closes it and returns focus to the bar. The zoom control sits on the track and scales inside its scroller. A bar narrower than its label shows no text; its `title` and popover carry the label. Tokens follow HeroUI's look as CSS custom properties, light and dark, system fonts only. `window.onerror` counts into `document.body.dataset.errors`. The page exposes `window.runViewer.register` and `openPopover` (decisions table) and holds hidden `board` and `graph` mounts; a module that throws shows 1 damage line and leaves the core regions drawn. `openTaskDrawer(taskID)` opens the task drawer of decision 17. It shows the title with id and status, then Why with its design §, Scope, Acceptance and Out of scope. Then Properties (status, model, wave from the deps, spec ids as chips, write set, created, merged, id) and Links (blocked by and blocks). Then Activity, built from `spans`, `gates`, `halts` and `commits`, and tool activity, collapsed. A task with no brief shows Properties, Links and Activity. At phone width the drawer is a full-height sheet; Escape closes it and returns focus to the opener.
- Span seam: none.
- Tests: `apply` merges a partial span by id and keeps every other span (catches a replace-all merge). 2 parallel task spans land on 2 rows and their children nest under each (catches overlap). At 4x the track is 4 times its 1x width, and a 30 px bar with a 10-character label shows no text (catches a clipped label). A span with `end = null` lays out to the run's last event and reads "never ended" (design §4.2). In headless Chrome with a test-built `RunView`: Tab to a bar and Enter opens the popover, Escape closes it and focus returns to that bar (catches a popover the keyboard can't reach). An outside click closes it. At a 390 px viewport it is a bottom sheet. The zoom changes the track's width and not the page's. The console holds 0 errors. `blocks(view, id)` inverts the deps and `activity(view, id)` orders a task's worker start, gates, fixes, review and merge by time (catches a link list read 1 way). The drawer of a task with no brief renders Properties, Links and Activity, and 0 errors. A test-registered module whose `render` throws leaves every core region drawn and adds 1 damage line (catches a module able to blank the page).

### `run-view-builder-derives-spans`
- Deps: run-view-contract, run-fixtures-are-captured · Gate: push · Model: opus · estLines: 600
- Writes: `R/RunViewBuilder.swift`, `R/RunViewSpans.swift`, `R/RunViewRequirements.swift`, `TD/RunViewBuilderTests.swift`
- Does: design §4.1 (derived spans), §5, §6, §7 (stalls). Pure. Folds the captured events, the build join and the plan into `RunView`:
  - the run span, from `startedAt` to the last event;
  - task spans, from the ledger's `in-progress` transition to `merged`, `abandoned` or the run's end, and merge spans;
  - gate spans, as `gate.run` time minus `ms`, joined to a task by its return's gate run id or the ledger `gate` event;
  - tiers and steps under their gate through `parentID`, laid end to end and `approximate` when `startMs` is absent;
  - tokens per task and per role from `agent.usage`, `null` for a task still running;
  - halts from `build.halt` to `build.resume`;
  - spec rows from `covers`, titles cut to 120 bytes, uncovered ones kept;
  - each task's `deps`, `writes`, `gate` and `covers` from its ledger entry, `createdAt` from its first ledger event and `mergedAt` from its merge;
  - each task's `brief` from `RunViewInput.briefs`, every string cut to 480 bytes; a string `EventPayloadGuard` rejects drops out as a `damage` row naming the task and field.

   Drops `LedgerTask.worktree`. Calls `RunViewEmittedEvents.fold` and `SpanToolAttribution.attribute` as the contract left them.
- Span seam: none.
- Tests, over `F/RunView/build-run-1`: every task has a task span inside the run span, and each gate span sits inside its task's span (catches a gate joined to the wrong task). Steps without `startMs` are `approximate` and laid end to end. Tokens per task equal the sum of that task's `agent.usage` events (catches double counting across the main and subagent transcripts). No `RunView` string holds the scratch clone's path (catches the worktree leaking). A requirement with no task shows as uncovered. Each task's `deps` and `writes` equal its ledger entry's (catches a field the board and the graph would read empty). A brief string holding a newline drops out with 1 `damage` row and the rest of the brief stays (catches 1 bad line failing the report). Removing the worktree drop turns that test red; restore it (pitfall 6).

### `run-view-reader-collects-stores`
- Deps: run-view-contract, run-fixtures-are-captured, state-root-seam (brownfield) · Gate: push · Model: opus · estLines: 400
- Writes: `A/RunView/RunViewReader.swift`, `TA/RunViewReaderTests.swift`
- Does: design §6. Reads the main store, each live task worktree's store and every imported store through `EventStoreReader`, plus `BuildJoinReader` and the plan's requirements, filtered to 1 build run, into `RunViewInput`. It holds no path literal; every store path resolves through `StateRoot`. An unreadable file becomes a `damage` row naming it, never a silent gap (pitfall 4).
- Span seam: none.
- Tests, in a temp repository seeded from the captured run: events split across a main store, 1 live worktree store and 1 imported store read back as the same set (catches a store left out). A truncated JSONL line becomes 1 `damage` row naming the file, and the other events still read. Another build run's events stay out (catches a missing filter).

### `span-events-are-recorded`
- Deps: run-view-contract · Gate: push · Model: opus · estLines: 300
- Writes: `C/Commands/EventsSpanCommand.swift`, `A/Events/SpanLog.swift`, `TC/EventsSpanCommandTests.swift`, `F/RunView/span-sequence/` (the output of a real `events span` run in a temp repository), `F/README.md` (its capture command)
- Does: design §4.2. `events span start` writes `span.start` through the store `BuildHaltLog` resolves and prints the new 16-hex `spanID`. `events span end <spanID> --outcome <o>` reads that start, writes `span.end` with `ms` and `parentID` the start event. An end with no start, or a second end, exits 1 and writes nothing. With telemetry off both print the opt-out line and exit 0.
- Span seam: none.
- Tests, in a temp repository: start then end writes 2 events and `ms` matches the elapsed time within 1 s. An unknown `spanID` exits 1 and the store gains no line (catches an orphan end). A second end exits 1. `--phase warmup` exits 2 naming the allowed list. A span started in 1 linked worktree ends from another and lands in the main store (catches a per-worktree write).

### `prove-results-are-recorded`
- Deps: run-view-contract · Gate: push · Model: opus · estLines: 350
- Writes: `C/ChangedTestChecks.swift`, `C/GateStepCollector.swift`, `C/GateRun.swift`, `A/RunStore.swift`, `TC/ProveResultRecordTests.swift`, `TA/RunStoreProveResultTests.swift`, `F/RunView/prove-gate/` (a real `check --prove` run's `gate` and `test` streams over a temp package), `F/README.md` (its capture command)
- Does: design §4.1 (`startMs`), §4.3. Prove keeps 1 outcome per changed test it ran, with the proof base and the first failure location of the reverted run, made repo-relative. `RunStore.record` takes `proofs` and writes 1 `prove.result` per test beside `test.result`. `GateStepCollector` stamps each step's `startMs` from the gate's start.
- Span seam: none.
- Tests, in a temp package: a test that fails with the source reverted records `proven` with its `file:line` and `kind = expect` (catches the location of the head run). A test that passes reverted records `passes-reverted` and no assertion. An absolute failure path becomes repo-relative or drops the assertion, never stores the path. 2 steps timed in parallel carry overlapping `startMs` ranges (catches end-to-end stamping). Removing the `proofs` write turns the first test red; restore it.

### `tool-summaries-are-ingested`
- Deps: run-view-contract, run-fixtures-are-captured · Gate: push · Model: opus · estLines: 450
- Writes: `D/Events/TranscriptTools.swift`, `R/SpanToolAttribution.swift`, `C/Commands/EventsCommands.swift` (ingest only), `TD/TranscriptToolsTests.swift`, `TD/SpanToolAttributionTests.swift`, `P/docs/telemetry.md` (the `agent.tools` row and the "never recorded" exception)
- Does: design §4.4, §8, decision 14. `TranscriptTools` pairs each `tool_use` with its `tool_result` by id, buckets calls into 60 s windows per agent, counts by `ToolKind`, sums `ms`, and reads `file_path`, `path` or `notebook_path` from file tools only. A path under the git top level of the line's `cwd` becomes repo-relative; any other path, a `~` path or a `..` escape counts in `droppedPaths`; ingest then drops and counts each kept path `EventPayloadGuard` rejects. `events ingest` writes `agent.tools` beside `agent.usage`, with the same agent, role, task and build run tags. `SpanToolAttribution.attribute` gives each window to the innermost span of that agent's task open at the window's time, summing counts and `ms` and merging files to at most 50. The telemetry doc's "What's recorded" table gains the row, and "What's never recorded" names the exception: repo-relative paths of file tools, nothing else from a tool input.
- Span seam: none.
- Tests, over the captured tool session: the counts per `ToolKind` match the session's calls, `Bash` included, and no command text appears in any event (catches a tool input stored). Ingest drops and counts `/etc/hosts`; the edited file appears as a bare repo-relative name (catches an absolute path kept). The subagent's window carries its `agentID`. A window that straddles 2 spans of 1 task goes to the span open at its start. Ingesting twice writes no duplicate (catches a missing dedup key, the window and agent).

### `report-writes-the-html`
- Deps: run-view-builder-derives-spans, run-view-reader-collects-stores, viewer-page-renders-the-report, state-root-seam (brownfield) · Gate: push · Model: opus · estLines: 450
- Writes: `C/Commands/ReportCommand.swift`, `A/RunView/ViewerTemplate.swift`, `R/RunViewGuard.swift`, `TC/ReportCommandTests.swift`, `TD/RunViewGuardTests.swift`, `tests/run_viewer_report_test.mjs`
- Does: design §6 (embedded), §8. `report --json <id>` prints the `RunView`. `report --html <id>` reads the template from the plugin root as bootstrap reads `templates/`. It inlines the CSS, both scripts and every `V/run-viewer-*.js` and `V/run-viewer-*.css` module present, in name order. It embeds the `RunView` with `ArtifactPageShell.scriptSafeJSON`'s escaping, and writes `reports/<id>.html` under the state root, or `--out`. Before rendering, `RunViewGuard` runs `EventPayloadGuard` over every string; a reject fails the command naming the field.
- Span seam: none.
- Tests: in a temp repository seeded from `F/RunView/build-run-1`, `report --html` writes 1 file holding no `<script src`, no `<link`, no `http` (catches a page that needs the network) and no `</script` inside the data. A module file dropped into a temp copy of the template directory appears inlined after the core script (catches a hard-coded file list that would force the trailing tasks to edit this command). A `RunView` string holding an absolute home path fails naming the field (catches the guard skipped). In headless Chrome, the report of the captured run renders every region with at least 1 row, and the console holds 0 errors: this is the sample data's replacement, and it catches key drift between the encoder and the page.

### `builder-folds-emitted-events`
- Deps: run-view-builder-derives-spans, span-events-are-recorded, prove-results-are-recorded, tool-summaries-are-ingested · Gate: push · Model: opus · estLines: 400
- Writes: `R/RunViewEmittedEvents.swift`, `TD/RunViewEmittedEventsTests.swift`
- Does: design §4.1 to §4.4. Folds `span.start` and `span.end` into spans. An open span has `end = null`; in a finished run the builder cuts a span with no end at its last event and marks it. Folds `prove.result` into `proofs`, joined to tasks through their gate run; `gate.step.startMs` into exact step offsets; and the attributed tool summaries into each span's `tools`.
- Span seam: none.
- Tests, over `F/RunView/span-sequence/`, `F/RunView/prove-gate/` and the ingested tool session: a span with a parent nests under it (catches a flat fold). An unended span in a done run reads "never ended". A `prove.result` lands under its task and its gate. Steps with `startMs` aren't `approximate`. A span's `tools` equals the attribution's output for it.

### `skills-mark-their-phases`
- Deps: span-events-are-recorded · Gate: push · Model: opus · estLines: 200
- Writes: `P/skills/build/SKILL.md`, `P/skills/build/references/event-loop.md`, `P/skills/ship/SKILL.md`, `tests/skill_telemetry_calls_test.mjs`, `tests/skill_commands_test.mjs` (rows appended)
- Does: design §4.2. The build skill wraps `spec-read`, `discover`, `explore`, `plan`, `contract` and `final` in `events span start` and `end`, and the ship skill wraps `ship`. A failed span call prints 1 line and never stops the skill, as the existing telemetry calls do.
- Span seam: none.
- Tests: every `events span` line the skills write runs through the real binary's parser in a temp repository (catches a flag the CLI lacks). Each start has its end on every path, halts included (catches a span left open by a halt). A refused span call doesn't halt the skill.

### `workflow-marks-worker-stages`
- Deps: span-events-are-recorded, executor-takes-the-brownfield-preset (brownfield) · Gate: push · Model: opus · estLines: 200
- Writes: `P/workflows/build-task.js`, `tests/build_task_workflow_test.mjs`
- Does: design §4.2. `build-task.js` opens a `worker`, `review`, `verify` or `fix` span with `--task` and the previous stage's span as parent, and ends it with the stage's outcome. A failed span call logs and never fails the task.
- Span seam: none.
- Tests: a task's run with a fake `swiftgate` records starts and ends in stage order, each parented to the one before (catches stages started flat). A red verify ends its span `red`; a halted task ends its open span `halted`. A span call that exits 1 leaves the task's outcome unchanged.

### `page-shows-the-now-strip`
- Deps: viewer-page-renders-the-report · Gate: push · Model: opus · estLines: 350 · Merge: after `report-writes-the-html`
- Writes: `V/run-viewer.js`, `V/run-view-model.js`, `V/run-viewer.css`, `tests/run_viewer_model_test.mjs`, `tests/run_viewer_page_test.mjs`
- Does: design §7, decisions 9 and 10. When served (not embedded), the page fetches `/view.json`, then polls `/changes?after=<cursor>` every second and calls `apply`. The now strip shows 1 card per worker with its task, open phase, elapsed time and last event age; a stall badge after the preset's `stall_min` with no event of that task; a halt badge from `build.halt` to `build.resume`. Open spans grow with the clock. A failed poll shows 1 line in the header and keeps polling. The embedded report hides the strip.
- Span seam: none.
- Tests: `stalls(view, now, stallMin)` flags a task whose last event is older than `stall_min` and not one with a fresh event (catches a stall from the span's start). In headless Chrome against a stub server built in the test, 3 polls merge 3 partials, the cursor advances, and a halted task shows its badge (catches a poll that refetches everything). The embedded report shows no strip.

### `view-serves-live-changes`
- Deps: report-writes-the-html, run-view-reader-collects-stores · Gate: push · Model: opus · estLines: 500
- Writes: `C/Commands/ViewCommand.swift`, `A/RunView/LocalHTTPServer.swift`, `A/RunView/RunViewReader.swift` (the cursor), `R/RunViewCursor.swift`, `TC/ViewCommandTests.swift`, `TA/RunViewCursorTests.swift`
- Does: design §6 (streamed), §8. `view [--build-run <id>] [--port <n>]` serves `GET /` (the page through `ViewerTemplate`, modules inlined, nothing embedded), `GET /view.json` and `GET /changes?after=<cursor>` on `127.0.0.1`, defaulting to the newest build run. The cursor is each active stream file's byte offset plus the ledger log's length, opaque to the page. `/changes` reads from those offsets, folds through the builder, and returns the partial `RunView` and a new cursor; it runs the guard on every response. A stale or malformed cursor returns a full view and a new cursor.
- Span seam: none.
- Tests: the server refuses a connection on a non-loopback address (catches a `0.0.0.0` bind). After 1 appended event, `/changes` returns only the changed span and a larger cursor (catches a full re-read). A malformed cursor returns a full view, not a 500. A request for another path returns 404 and serves no file (catches a static file server over the repository).

### `span-run-is-captured`
- Deps: skills-mark-their-phases, workflow-marks-worker-stages, builder-folds-emitted-events, report-writes-the-html · Gate: push · Model: opus · estLines: 150 (fixture bytes aside) · Needs: a model (headless build)
- Writes: `F/RunView/build-run-2/…`, `F/README.md` (its section), `TD/RunViewSpanRunTests.swift`, `tests/run_viewer_report_test.mjs` (a second case)
- Does: design §9. Repeat `run-fixtures-are-captured`'s headless build with the span calls, prove results and tool summaries in place, and capture it the same way.
- Span seam: none.
- Tests: the captured run's `RunView` has phase spans for every build skill phase, worker stages nested under each task, at least 1 `prove.result` per task, and tool summaries on worker spans. Its report renders with 0 console errors.

### `brownfield-runs-carry-spans-and-covers`
- Deps: run-view-builder-derives-spans, skills-mark-their-phases, plan-import-derives-the-ledger (brownfield), run-skill-orchestrates-the-run (brownfield) · Gate: push · Model: opus · estLines: 250
- Writes: `A/RunView/RunViewReader.swift` (briefs from the plan state), `B/LivePlan.swift` (the `Covers:` line), `P/skills/run/SKILL.md` (span calls), `P/skills/run/references/plan-shape.md` (`## Requirements` and `Covers:`), `R/RunViewSpans.swift` (discover and warm-up spans), `TD/LivePlanCoversTests.swift`, `TD/RunViewBrownfieldSpansTests.swift`
- Does: design §5, and brownfield's "Seam for the run viewer". `plan import` copies each task's `Covers:` into the ledger's `covers`, and the coverage lint flags an unknown id. The run skill wraps `spec-read`, `explore`, `plan`, `contract` and `final` in span calls. The builder derives a `discover` span from `discover.run` and 1 warm-up span per area and step from `warmup.run`, each from its time minus `ms`, so no brownfield function calls `events span`. The reader fills `RunViewInput.briefs` from the brief `plan import` wrote into the plan state, by the keys brownfield's interfaces note records.
- Span seam: reads `discover.run` and `warmup.run`; wraps none of the named functions.
- Tests: a `PLAN.md` with 2 requirements and 2 tasks imports with each task's `covers` (catches a dropped line). A `Covers:` naming an unknown id fails the lint naming it. A captured `warmup.run` from the brownfield fixtures yields 1 span per area and step, nested in the run span. A plan imported by the real `plan import` with Why, Scope, Acceptance and Out of scope lines reads back as each task's brief (catches a key the reader and the importer don't share).

### `kanban-board-shows-tasks`
- Deps: viewer-page-renders-the-report, run-view-builder-derives-spans · Gate: push · Model: opus · estLines: 300 · Bar: trailing · Merge: after `view-serves-live-changes`
- Writes: `V/run-viewer-board.js`, `V/run-viewer-board.css`, `tests/run_viewer_board_test.mjs`
- Does: design §7 (board), decision 15. Registers `board`. A pure `columns(view, now)` puts each task in queued, building, gating, review, merged, or the blocked or halted lane, by the rules in design §7. A card shows the task id, its model as the worker, elapsed time, the last gate verdict chip and its `covers`. Its `apply` re-renders on each poll, so cards move as events arrive. The report shows the final state. Clicking a card, or Enter on it, opens `openTaskDrawer` for its task.
- Span seam: none.
- Tests: `columns` puts an `in-progress` task with an open `verify` span in gating and the same task with an open halt in the halted lane (catches the halt lost behind the stage). A `pending` task with every dep merged stays queued until a span opens. In headless Chrome with a test-built `RunView`, 2 partials move 1 card from building to merged, and the console holds 0 errors.

### `plan-graph-draws-the-deps`
- Deps: viewer-page-renders-the-report, run-view-builder-derives-spans · Gate: push · Model: opus · estLines: 350 · Bar: trailing · Merge: after `view-serves-live-changes`
- Writes: `V/run-viewer-graph.js`, `V/run-viewer-graph.css`, `tests/run_viewer_graph_test.mjs`
- Does: design §7 (plan graph), decision 16. Registers `graph`. A pure `layers(tasks)` gives each task the length of its longest dep chain as its wave, then orders each layer by the mean position of its deps, 1 pass, to cut crossings. The module draws inline SVG: waves left to right, 1 node per task coloured by its board column, 1 edge per dep. A node is focusable with `role="button"`; hover shows the task's title as a tooltip; click or Enter opens `openTaskDrawer`, which lists the write set, spec ids and gate. No graph library. A dep cycle draws no graph and shows 1 damage line naming the tasks.
- Span seam: none.
- Tests: `layers` puts a task after every dep (catches a node left of its dep). A diamond (a → b, a → c, b and c → d) yields 3 layers with b and c in 1. A cycle yields the damage line, not a hang. In headless Chrome, Enter on a focused node opens the task drawer listing its write set, and the SVG has 1 path per dep.

### `docs-describe-the-run-viewer`
- Deps: report-writes-the-html, view-serves-live-changes, span-run-is-captured · Gate: push · Model: opus · estLines: 200
- Writes: `P/docs/telemetry.md` (the `span.start`, `span.end` and `prove.result` rows, and the `report` and `view` commands), `docs/capabilities.md` (the board and the graph if merged), `docs/index.md`, `docs/handoffs/run-viewer-interfaces.md` (final section)
- Does: describe what merged; the design follows the code where they differ.
- Tests: the docs-lint and prose gates pass on the added lines.
