# Run viewer: interfaces

The API [the run viewer plan](../plans/2026-10-03-run-viewer-plan.md) left on `main`, in 1 place, for whoever
builds on it next. User-facing behaviour lives in [`plugin/docs/run-viewer.md`](../../plugin/docs/run-viewer.md)
and the event rows in [`plugin/docs/telemetry.md`](../../plugin/docs/telemetry.md); this note doesn't repeat
them. The brownfield side of the seam (the state root, `plan import`, `discover.run`, `warmup.run`) is in
[`brownfield-interfaces.md`](brownfield-interfaces.md). Paths use the plan's abbreviations (`D/`, `A/`, `C/`,
`R/` = `D/RunView/`, `V/` = `plugin/viewer/`, `F/`).

## Final state

**Events** (`D/Events/`).
- `SpanStartEvent { spanID, parentSpan?, phase: SpanPhase, buildRun, task?, role: AgentRole? }` and
  `SpanEndEvent { spanID, outcome: SpanOutcome, ms }`, in stream `span`. `SpanStartEvent.isValidID(_:)` is
  exactly 16 lowercase hex characters; decoding rejects anything else.
- `SpanPhase` is closed: `spec-read`, `discover`, `explore`, `plan`, `contract`, `worker`, `review`, `verify`,
  `fix`, `final`, `ship`. `SpanOutcome`: `ok`, `red`, `halted`, `abandoned`.
- `ProveResultEvent { test, testHashed, target, outcome: ProveResultOutcome, proofBase?, assertion:
  ProveAssertion? }` in stream `test`, `parentID` its `gate.run`. Owned repositories write it through
  `RunStore.record`; brownfield prove writes its own.
- `AgentToolsEvent` with the closed `ToolKind` and `ToolCallCount`, in stream `usage`.
- `GateStepEvent.startMs: Int?`, the step's offset from its gate run's start.
- `BuildReturnCheckedEvent { buildRun, task, fix, verdict, rules: [TaskReturnFinding.Rule], findings:
  [{rule, message, truncated}], moreFindings, message }`, kind `build.return-checked` in stream `build`,
  which `build check-return` writes for every verdict through `BuildReturnCheckedEvent.scrubbed(…)`.

**Writers** (`A/`, `C/`).
- `SpanLog(root:)` with `start(phase:buildRun:task:role:parentSpan:)` and `end(spanID:outcome:)`, which throw
  `SpanLogError`: `.noStart` and `.alreadyEnded` (CLI exit 1), `.unreadable` and `.unwritten` (exit 2). It
  writes to the store `BuildHaltRun.store` resolves, the main checkout's.
- `events ingest --agent-id <id>` reads 1 subagent of the session by the id the Agent tool printed, and needs
  `--role`. Tool paths are made relative to the innermost of the line's `cwd` top level and every worktree
  root git's pointer files name.

**Run view** (`R/`, pure).
- `RunView` encodes `schemaVersion` 1 and the design §6 keys, plus `run.stallMin` and the span phases the
  builder derives (`run`, `task`, `merge`, `gate`, `tier`, `step`, `warmup`). Times are ISO-8601 with
  milliseconds; `RunViewJSON.encode(_:)` is the 1 encoder.
- A blocked task's `blocked.cause` is `return-rejected` when its newest `build.return-checked` wasn't
  GREEN, and `blocked.rejection` then holds that event's verdict, rules, findings and message.
- `RunViewBuilder.build(_ input: RunViewInput) -> RunView`. `RunViewInput` carries `events`, `join`,
  `ledger`, `requirements`, `damage`, `briefs`, `workerGateRuns` (a worker's or fixer's own gate runs by
  task) and `launchedAt` (a brownfield launch).
- `RunViewSpans.brownfieldSpans(events:parent:)` derives `discover` and approximate `warmup` spans.
- `SpanToolAttribution.attribute(windows:spans:)` gives each window to the innermost span of its agent's task
  open at the window's start.
- `RunViewGuard.rejection(of:) -> Rejection?` runs `EventPayloadGuard` over every string and names the field.
- `RunViewSnapshot.cursor`, `RunViewChanges.between(_:_:)` and `RunViewCursorBook.answer(after:snapshot:build:)`
  (holds 8 answered views; an unknown cursor gets `.full`).

**Adapters** (`A/RunView/`).
- `RunViewReader(commonDirectory:stateRoot:profile:)`, behind `RunViewReading`: `read(buildRun:)`,
  `snapshot(buildRun:)` and `newestBuildRun()`. The plan's first build run also keeps spans whose `buildRun`
  is the plan slug, and `discover.run` and `warmup.run` from the launch until the next plan launches.
- `ViewerTemplate.load(pluginRoot:)` and `render(viewJSON:)`; empty data serves the live page.
- `LocalHTTPServer`, behind `LocalHTTPServing`: `start(port:handler:)` binds `127.0.0.1` and answers 403 to a
  foreign `Host`. `LocalHTTPRequest` and `LocalHTTPResponse` are the handler's types.

**CLI** (`C/Commands/`). `ReportRun.run(buildRun:format:out:root:commonDirectory:pluginRoot:)` and
`ViewRun.respond(to:)` hold the logic; both commands find `viewer/` through `SWIFTGATE_HARNESS_ROOT`, which
`plugin/bin/swiftgate` sets.

**Page** (`V/`).
- `window.runViewer = { register(name, {render(view, mount), apply(view)}), addTab(id, spec),
  openPopover(anchor, rows, title), openTaskPopover(taskID, anchor), openTaskDrawer(taskID), apply }`. A module
  throwing lands in the footer's damage and hides its mount.
- Tabs (the user's 2026-10-04 layout): `overview`, `timeline`, `board`, `graph`, `spec`, `gates`, `tokens`, each
  a `.tab-panel[data-tab=<id>]` with `role="tabpanel"` and a `[role=tab][data-tab=<id>]` button. The id is the
  tab's bare `#<id>` in the URL; an unknown or hidden one shows `overview`. `board` and `graph` show only once
  their module's `[data-module]` mount draws.
- The tab seam: `runViewer.addTab(id, { label, badges(view) -> [{key, kind, n, text, title}], available() ->
  Bool, shown() })` appends a tab after the core's and returns its panel element to draw into; `kind` is `bad`,
  `warn`, `info` or `plain`. A throwing `badges` lands in damage once. A Validation module adds its tab this way;
  pair it with `register(name, …)` on a `[data-module]` mount inside the panel to get the module's damage rule.
- `openTaskPopover` anchors a task's details (status, column, deps, latest gate, commits, covers, why it failed
  or stopped, Open task) to a card, node or `.task-link`; a poll reopens it on the same task.
- `ViewerTemplate` inlines every `run-viewer-*.js` and `run-viewer-*.css`, in name order. Modules today:
  `RunViewBoard.columns(view, now)` and `RunViewGraph.layers(tasks)`. The core draws on `DOMContentLoaded`,
  after every module script ran; in live mode modules draw on the first fetched view.
- `RunViewModel` (`run-view-model.js`) holds the pure functions: `apply`, `stalls`, `workers`, `lanes`,
  `scale`, `labelFits`, `latestGate(view, taskID)`, `tabBadges(view, {now, stallMin})` (keyed by tab id; `now`
  null for a report) and the formats.

**Callers.**
- `build-task.js` requires `buildRun` and `pluginRoot`. Each stage agent's prompt carries its own 2 span lines
  through `<pluginRoot>/bin/swiftgate` and returns `"span"`, the id or `null`, which the next stage takes as
  `--parent`. The workflow spawns no agent for a span.
- `guard.reviewer-bash` holds `architecture`, `test-quality` and `verifier` agents to those span lines; see
  [`hooks.md`](../../plugin/docs/hooks.md) and the rule index in
  [`standards.md`](../../plugin/docs/standards.md).
- The run skill's `PLAN.md` shape (`## Requirements`, `- Covers:`) is in
  [`plan-shape.md`](../../plugin/skills/run/references/plan-shape.md).

**Fixtures** (`F/RunView/`): `build-run-1` and `build-run-2` from real headless builds, plus `span-sequence`,
`prove-gate` and `brownfield-prebuild`, each with its capture command in `F/README.md`.

**Open.**
- `build-run-2` holds no task's `prove.result`: its worker gates ran a stale `swiftgate` from `PATH`, which
  `pluginRoot` now prevents. A recapture would let the per-task proof test run.
- `plugin/agents/build-worker.md` and `build-fixer.md` still name a bare `swiftgate`; changing them needs a
  calibrate run.
