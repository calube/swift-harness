# Harness telemetry: implementation plan

<!-- RESUME
Status (2026-09-30): the user approved the design and asked to build now. Tasks with no deps start first; none
that touches the event store starts before the `judge-emits-judgement-events` branch (the shared `HarnessEvent` envelope, its writer and
`.harness/events/`) merges to main.
Spec: docs/designs/2026-09-30-harness-telemetry-design.md. Read its RESUME header, §3, §5 and §14.
Scope: the payload guard, rotation, sealed LZFSE segments, indexes and rollups on the envelope's store; the
`[telemetry]` opt-out; `gate.run`, `gate.step`, `test.result` (every result), `hook.decision`, `cache.lookup`,
`build.halt`, `build.resume` and `agent.usage`; `swiftgate events list|summary|ingest`; `build halt|resume`;
copy-up on `worktree remove` and `gc --events`; summary sections for cost, gate time, wrong gates, flaky and slow
tests, hooks, caches, halts and the judge; the build and ship skills calling ingest, halt, resume and summary.
Out of scope: any network path, a dashboard, edits to `evals/runner/`, and folding today's stores into the envelope.
Resume: read this header, then "Wave map", then your task's section (grep for the task id). Grep the spec by §.
Orchestrator procedure: docs/handoffs/subproject-2-orchestrator-runbook.md, with the changes in "How to work this plan".
Progress: git log. Update this header at every wave merge.
-->

## Decisions made while planning

Rows marked "user, 2026-09-30" record the user's decisions (design §14). The other rows are the plan's own choices
within them.

| Decision | Evidence | Choice | Needs |
|---|---|---|---|
| On by default | design §4.3 | `[telemetry] enabled` defaults to `true` in every repo with `.swiftgate.toml`; `enabled = false` opts out. Local only, never over the network | user, 2026-09-30 |
| Transcripts | design §5.7 | `events ingest` reads token counts offline from the session record's `transcriptPath` and from worker transcript directories the build skill passes. No transcript text, tool input or path is stored | user, 2026-09-30 |
| Every test result | design §8 | `test.result` for every case of every gate run, no sample. Rotation at 16 MB, sealed LZFSE segments, per-segment index and rollup; nothing deleted automatically | user, 2026-09-30 |
| Location | design §9 | Per worktree; `worktree remove` copies `.harness/events/` to main's `.harness/events/imported/<storeID>/` beside `keepRuns`. Existing stores keep their formats; the reader joins them | user, 2026-09-30 |
| Ignored | the judge audit-log branch adds `.harness/events/` to `.gitignore` | This plan adds it to `plugin/templates/gitignore` only | orchestrator, 2026-09-30 |
| Envelope | the `judge-emits-judgement-events` branch | `HarnessEvent`, its writer protocol and file store are used as merged. Where this plan names "the envelope's file store", the task uses that branch's type name | — |
| Opt-out reach | design §14 row 6 | The opt-out lives in the writer factory and covers every kind except the judge's, which stays on as an audit trail | user, 2026-09-30 |
| Worker transcripts | design §14 row 7 | The build skill passes the Workflow transcript directory to `events ingest` at each completion; the path is never stored | the user to confirm |
| Summary sections | 6 tasks add sections | `events-list-and-summary-read-every-store` declares every section with an empty implementation that prints "no events yet"; each later task fills only its own section file, so the registry isn't a hot file | — |
| Compression | Foundation's `NSData.compressed(using: .lzfse)` | No new dependency. The gate runs on macOS only | — |
| No new rule id | telemetry gates nothing | No task adds a rule id or a rule-index row. Config issues report under `swiftgate.config`, which the index lists. Reader damage is printed by the reader, not reported as a finding | — |

## How to work this plan

The runbook applies as written, with these changes:

- **Model.** Every worker on `opus`.
- **Surface first.** Each worker commits its new API as a behaviour-free surface commit, then tests and
  behaviour (worker brief pitfall 10), and runs `swiftgate surface-check <surface sha>` on it.
- **Merge gate.** Push + `prove --base main` on 1 integration worktree. Mutate runs once on `main` after each wave.
- **Id policy.** Task ids and wave numbers never appear in code, comments, test names or commit messages.
- **Telemetry never gates.** A failed event write prints 1 line and never changes a verdict, an exit code or a
  report. Every emit task tests that.
- **Tests never touch shared state.** Every test writes events under a temp directory; none resolves this
  checkout's `.harness/` or git common dir.
- **Evals.** The evals session owns `evals/runner/` and `evals/sessions/`; no task edits them.
- **Generic harness.** No task names an app, practice prompt or preset value beyond the template's.
- **Paths.** `D/` = `plugin/gate/Sources/SwiftGateDomain/`, `A/` = `plugin/gate/Sources/SwiftGateAdapters/`,
  `C/` = `plugin/gate/Sources/SwiftGateCLI/`, `S/` = `plugin/gate/Sources/SwiftGateTestSupport/`,
  `TD/` `TA/` `TC/` = `plugin/gate/Tests/SwiftGate{Domain,Adapters,CLI}Tests/`, `F/` =
  `plugin/gate/Tests/Fixtures/`, `P/` = `plugin/`.

### Merge points (hot files)

| File | Edited only by |
|---|---|
| the envelope's file store (judge branch) | `event-store-guards-rotates-and-seals` |
| `A/Events/EventSegmentStore.swift` | `event-store-guards-rotates-and-seals`, then `summary-reports-flaky-and-slow-tests` (the rollup at seal) |
| `A/RunStore.swift`, `C/GateRun.swift` | `gate-runs-record-tree-and-steps`, then `gate-runs-record-every-test-result` |
| `C/HostTestCheck.swift`, `C/SimulatorTestCheck.swift` | `gate-runs-record-tree-and-steps` (step timing), then `gate-runs-record-every-test-result` |
| `C/Commands/EventsCommands.swift` | `events-list-and-summary-read-every-store`, then `agent-usage-is-ingested` |
| `C/SwiftGate.swift` | `events-list-and-summary-read-every-store` |
| `D/Events/EventSummary.swift` | `events-list-and-summary-read-every-store` only |
| `D/Events/Summary/<Section>.swift` | created empty by `events-list-and-summary-read-every-store`, then filled by its own section task |
| `D/Events/Summary/WrongGatesSection.swift` | `events-list-and-summary-read-every-store` (empty), then `summary-reports-gate-time-and-flips`, then `summary-finds-missed-reds` |
| `A/Events/BuildJoinReader.swift` | `summary-finds-missed-reds`, then `summary-reports-halts-and-the-judge` (read only after) |
| `P/skills/build/SKILL.md`, `P/skills/build/references/event-loop.md` | `build-halts-and-resumes-are-timed`, then `skills-ingest-and-print-the-summary` |
| `P/skills/ship/SKILL.md` | `build-halts-and-resumes-are-timed`, then `skills-ingest-and-print-the-summary` |
| `D/Config/Config.swift`, `D/Config/ConfigSchema.swift` | `telemetry-is-on-unless-opted-out` |
| `P/templates/gitignore` | `telemetry-is-on-unless-opted-out`. If the judge branch already added the line, the task's edit is empty and its test still runs |
| `F/README.md` | `throwaway-session-usage-is-captured`, then `gate-runs-record-tree-and-steps` |
| `README.md`, `docs/capabilities.md`, `docs/index.md` | `docs-describe-harness-telemetry` |

### Risks

- **Envelope drift.** The judge branch may rename a field or the writer before it merges. Wave 1 starts from the
  merged names; a task that finds a mismatch with the design reports it as a deviation and uses the merged name.
- **Transcript format.** Claude Code's transcript format isn't a published contract. Ingest reads 4 keys, fails
  loudly on a line where they're malformed, and the capture task records the Claude Code version.
- **Store growth.** All test results grow without bound by decision. The summary's store section shows the size;
  `gc --events` is the explicit release valve.
- **Gate overhead.** `test.result` adds 1 batched write of about 0.8 MB per run in this repo. The gate task logs
  `RunStore.record`'s time in the step list, so a slowdown shows up in the summary it feeds.

## Wave map

| Wave | Tasks | Why |
|---|---|---|
| 1 | `event-store-guards-rotates-and-seals`, `telemetry-is-on-unless-opted-out`, `xunit-and-xcresult-carry-durations`, `throwaway-session-usage-is-captured` | independent foundations: the store, the config, the parsers and a real transcript |
| 2 | `events-list-and-summary-read-every-store`, `gate-runs-record-tree-and-steps`, `worktree-remove-copies-events-up`, `hook-decisions-are-recorded`, `cache-lookups-are-recorded` | each needs the store and the factory; disjoint files |
| 3 | `gate-runs-record-every-test-result`, `agent-usage-is-ingested`, `build-halts-and-resumes-are-timed`, `summary-reports-gate-time-and-flips` | test results need the gate task's `RunStore` change; ingest takes the `events` group; the gate-time section needs `gate.run` and `gate.step` |
| 4 | `summary-reports-flaky-and-slow-tests`, `summary-finds-missed-reds`, `summary-reports-cost`, `summary-reports-hooks-and-caches` | each fills its own section file; the flaky section adds the rollup to the store |
| 5 | `summary-reports-halts-and-the-judge`, `skills-ingest-and-print-the-summary` | halts reuse the build join reader; the skills call commands that exist by now |
| 6 | `docs-describe-harness-telemetry` | the docs state what merged |

### `event-store-guards-rotates-and-seals`
- Deps: the envelope branch merged · Gate: push · Model: opus · estLines: 420
- Writes: `D/Events/EventPayloadGuard.swift`, `D/Events/EventSegmentIndex.swift`, `D/Events/EventStoreIdentity.swift`, `A/Events/EventSegmentStore.swift`, `A/Events/EventWriterFactory.swift`, the envelope's file store, `TD/EventPayloadGuardTests.swift`, `TA/EventSegmentStoreTests.swift`
- Does: design §4.2, §8.2, the index half of §8.3, §10. The guard walks every string in an encoded payload and rejects a value of 512 bytes or more, one starting with `/` or `~`, or one holding a newline; a rejected event is counted in `dropped.json` by kind and reason. `store.json` holds `storeID` and a 32-byte `salt`, created once under a lock. Rotation renames the active file under the write lock at 16 MB for `test.result` and 4 MB otherwise; sealing compresses with LZFSE, writes `<seq>.index.json` and removes the plain file. `EventWriterFactory.make(root:enabled:)` returns the file writer, or a no-op writer when `enabled` is false. A batch is 1 write. Report the measured compression ratio of a real `test.result`-shaped batch in NOTES FOR NEXT WAVES.
- Tests: 8 concurrent writers, each with its own file descriptor (`flock` locks per open file, so threads contend as processes do), append 500 events each and the file holds 4,000 decodable lines (catches a write outside the lock). An absolute path, a `~` path, a 512-byte string and a newline are each dropped and counted by reason (catches a guard that checks only top-level fields: 1 case nests the path 2 levels down). A write that crosses the threshold seals the file and the next write starts a new active file; a 3 MB batch written at 15 MB stays whole in 1 segment (catches a batch split across segments). A sealed plain file with no `.lzfse` reads back (catches a killed sealer losing lines). The index names exactly the run ids in its segment. The disabled factory creates no directory.

### `telemetry-is-on-unless-opted-out`
- Deps: none · Gate: push · Model: opus · estLines: 160
- Writes: `D/Config/Config.swift` (`TelemetryConfig`), `D/Config/ConfigSchema.swift` (`readTelemetry`), `P/templates/gitignore`, `TD/ConfigTelemetryTests.swift`
- Does: design §4.3. `[telemetry]` with 1 key, `enabled`, default `true`. Unknown keys fail as in every table. Add `**/.harness/events/` to the bootstrap ignore template.
- Tests: no table decodes as enabled (catches an opt-in default). `enabled = false` decodes as disabled. `enabled = "no"` fails naming `telemetry.enabled`. `endpoint = "…"` fails as an unknown key (catches a key that would imply sending events anywhere). The ignore template bootstrap writes contains `**/.harness/events/`.

### `xunit-and-xcresult-carry-durations`
- Deps: none · Gate: push · Model: opus · estLines: 140
- Writes: `D/Testing/XUnitReport.swift`, `D/Testing/XcresultReport.swift`, `TD/XUnitReportTests.swift`, `TD/XcresultReportTests.swift`
- Does: design §5.3. `XUnitTestCase.milliseconds: Int?` from the `time` attribute; `XcresultTestCase.milliseconds: Int?` from `durationInSeconds`. Rounded to the nearest ms. Absent stays `nil`.
- Tests: each case in `F/SwiftTest/pass.xml` and `pass-swift-testing.xml` carries its `time` in ms (catches a duration read from the suite's total). Each case in a captured xcresult fixture carries its `durationInSeconds` (catches the string `duration` parsed instead). A captured report with the `time` attribute removed in the test gives `nil`, never 0.

### `throwaway-session-usage-is-captured`
- Deps: none · Gate: push · Model: opus · estLines: 60 · Needs: a logged-in `claude` CLI (a few cents of spend)
- Writes: `F/Transcripts/` (captured), `F/README.md` (a "Transcripts" section)
- Does: design §13 first bullet. In a fresh temporary directory, run `claude -p 'Reply with the single word ok.' --output-format json` and a second session whose prompt asks it to use 1 subagent that replies `ok`. Keep each envelope JSON (with `total_cost_usd` and `session_id`), and each transcript and subagent transcript filtered by a recorded `jq` program to `type`, `timestamp`, `isSidechain`, `message.id`, `message.model`, `message.usage` and `message.content` (the throwaway prompt and reply are harmless, and a later test needs text to prove it isn't stored). Record the Claude Code version, the commands, the filter, where the subagent transcripts were found, and that the files hold no machine path.
- Tests: none of its own (fixture task). `agent-usage-is-ingested` consumes every file.

### `events-list-and-summary-read-every-store`
- Deps: event-store-guards-rotates-and-seals · Gate: push · Model: opus · estLines: 460
- Writes: `D/Events/EventQuery.swift`, `D/Events/EventSummary.swift`, `D/Events/Summary/*.swift` (every section of design §6.2 as an empty implementation, plus the real Store section), `A/Events/EventStoreReader.swift`, `C/Commands/EventsCommands.swift`, `C/SwiftGate.swift`, `TD/EventQueryTests.swift`, `TA/EventStoreReaderTests.swift`, `TC/EventsCommandTests.swift`
- Does: design §6.1, §6.2, §9 (reading). The reader yields events from active files, sealed segments and `imported/*/`, oldest first, deduplicated by `eventID`, using indexes to skip segments for `--since` and `--run`. Damage is a value in the result, never dropped. `events list` prints JSON lines. `events summary` runs every registered section; an empty section prints "no events yet", never zeros. Text and `--json` output; exit 0 even with damage.
- Tests: a torn last line in an active file is skipped and listed as damage with file and line (catches a silent drop). The same event in a worktree store and an imported copy prints once. `--run` opens only segments whose index names the run, counted through an injected file reader (catches a reader that decompresses everything). `--since 1d` excludes an older event. The Store section reports bytes per kind and the dropped count from `dropped.json`.

### `gate-runs-record-tree-and-steps`
- Deps: event-store-guards-rotates-and-seals, telemetry-is-on-unless-opted-out · Gate: push · Model: opus · estLines: 420
- Writes: `D/Events/GateEvents.swift` (payloads, `GateStep`), `A/RunStore.swift`, `C/GateRun.swift`, `C/StaticCheckRun.swift`, `C/GateStepCollector.swift`, the step call sites in `C/Commands/CheckCommand.swift`, `C/ChangedTestChecks.swift`, `C/HostTestCheck.swift`, `C/SimulatorTestCheck.swift`, `C/MutateCheck.swift`, `F/GateRun/` (captured), `F/README.md`, `TA/RunStoreEventsTests.swift`, `TC/GateRunEventsTests.swift`
- Does: design §5.1, §5.2. Clean tree: `treeHash` = `HEAD^{tree}`; dirty: absent, `dirty: true`. A run-scoped collector takes `(step, tier, ms, verdict, derivedData)` from each step's timing; `RunStore.record` gains `treeHash`, `dirty` and `steps` parameters and writes `gate.run`, then each `gate.step` with `parentID`. Capture `report.json` from a real `swiftgate check --tier push` on `examples/SampleApp` and record the command.
- Tests: the captured report gives a `gate.run` with its verdict, rule counts and finding paths, and no finding message text appears in the event file (catches messages copied into telemetry). A dirty temp repo gives no `treeHash` (catches a dirty tree treated as the same tree). Each `gate.step` points at its `gate.run`. With telemetry disabled, `history.jsonl` and `report.json` are written and no event file is (catches telemetry coupled to the gate's record). A writer that throws leaves the verdict and exit code unchanged.

### `worktree-remove-copies-events-up`
- Deps: event-store-guards-rotates-and-seals · Gate: push · Model: opus · estLines: 300
- Writes: `A/Events/EventCopyUp.swift`, `C/Commands/WorktreeCommand.swift`, `C/Commands/GCCommand.swift`, `TA/EventCopyUpTests.swift`, `TC/WorktreeRemoveEventsTests.swift`, `TC/GCEventsTests.swift`
- Does: design §9 (copy), §8.5. Beside `keepRuns`, `remove` copies `.harness/events/` to main's `.harness/events/imported/<storeID>/`: kept when present with as many bytes, replaced by 1 rename from a temp directory when the source holds more. A failure is named in the remove report and the message; removal goes ahead. `gc --events --older-than <days>` removes sealed segments, indexes and rollups whose last time is older; never an active file, never without `--events`.
- Tests, against temp repos only: a removed worktree's events appear under `imported/<storeID>/` and nowhere else (catches a copy into main's own active files). A second copy with more bytes replaces; one with equal bytes doesn't rewrite. A copy that fails is named and the worktree is still removed. `gc` with no `--events` leaves every event file. `gc --events --older-than 30` removes a 40-day segment, keeps a 10-day one and the active file (catches a gc that deletes by file mtime instead of the index's last time: the test sets mtimes opposite to the index times).

### `hook-decisions-are-recorded`
- Deps: event-store-guards-rotates-and-seals, telemetry-is-on-unless-opted-out · Gate: push · Model: opus · estLines: 220
- Writes: `D/Events/HookEvents.swift`, `C/Hooks/HookRunner.swift`, `TC/HookRunnerEventsTests.swift`
- Does: design §5.4. 1 `hook.decision` per hook call with event, tool, decision, rule ids, ms, session id and the salted input hash.
- Tests: a captured `PreToolUse` payload from `F/Hooks/` gives 1 event with the tool, the decision and a latency (catches an event written before the hook runs). The payload's command string appears nowhere in the event file. 2 identical inputs give 1 hash, and the same input under another store's salt gives another (catches an unsalted hash). Outside a project, and with telemetry disabled, nothing is written. A tool name with a space is absent from the event.

### `cache-lookups-are-recorded`
- Deps: event-store-guards-rotates-and-seals, telemetry-is-on-unless-opted-out · Gate: push · Model: opus · estLines: 220
- Writes: `D/Events/CacheEvents.swift`, `A/ManifestAnswerCache.swift`, `A/Evidence/EvidenceCacheStore.swift`, `TA/CacheEventsTests.swift`
- Does: design §5.5. Each cache takes an optional event writer; `answer` writes `hit` or `miss`, `store` writes `store`, the evidence store's reuse and tombstone methods write `hit` and `tombstone` with the reason.
- Tests: miss, store, hit gives 3 events with 1 `keyHash`, equal to the cache's own key (catches a hash of the raw command). A test target added under an unchanged manifest gives a `hit` with the old `answerHash` (the stale case the summary can't see alone). A tombstone carries its reason. No command or package path text is in the file.

### `gate-runs-record-every-test-result`
- Deps: gate-runs-record-tree-and-steps, xunit-and-xcresult-carry-durations · Gate: push · Model: opus · estLines: 280
- Writes: `D/Events/TestResultEvents.swift`, `A/RunStore.swift`, `C/GateRun.swift`, `C/HostTestCheck.swift`, `C/SimulatorTestCheck.swift`, `TD/TestResultEventsTests.swift`, `TA/RunStoreTestResultsTests.swift`
- Does: design §5.3. The checks hand parsed cases up beside the report; `RunStore.record` writes 1 `test.result` per case in 1 batch, each pointing at the `gate.run`. Ids normalize to `<target>.<suite>/<name>`; an id of 512 bytes or more becomes `sha256:<hex>` with `testHashed`.
- Tests: the captured xunit and xcresult fixtures give 1 event per case with outcome and ms (catches a skipped case dropped). The same test from both sources gets the same id. A Swift Testing failure's message text appears nowhere in the file. All of a run's results land in 1 segment. `report.json` is byte-identical with and without the case list (catches the list leaking into the report).

### `agent-usage-is-ingested`
- Deps: event-store-guards-rotates-and-seals, throwaway-session-usage-is-captured, events-list-and-summary-read-every-store · Gate: push · Model: opus · estLines: 380
- Writes: `D/Events/TranscriptUsage.swift`, `D/Events/ModelPrices.swift`, `A/Events/TranscriptReader.swift`, `C/Commands/EventsCommands.swift` (`ingest`), `TD/TranscriptUsageTests.swift`, `TC/EventsIngestCommandTests.swift`
- Does: design §5.7. Parse assistant lines, deduplicate by `message.id`, skip ids already stored for the session, price by model id from a table with its source and date. Flags `--session`, `--workflow-transcripts`, `--role`, `--task`, `--build-run`. A malformed usage line fails naming the line number, not the text. Disabled telemetry refuses naming `telemetry.enabled`.
- Tests: the captured transcript's token sums equal its usage deduplicated by message id, and the derived cost is within 1% of the envelope's `total_cost_usd` (catches a per-block double count and a wrong price key). Ingesting twice adds nothing. The subagent transcript's lines are `agent: subagent`. A model missing from the table gives no `costUSD` and names the model (catches a 0 cost). No word of the captured `message.content` appears in the store, nor either transcript path.

### `build-halts-and-resumes-are-timed`
- Deps: event-store-guards-rotates-and-seals · Gate: push · Model: opus · estLines: 260
- Writes: `D/Events/BuildHaltEvents.swift`, `C/Commands/BuildHaltCommand.swift`, `C/Commands/BuildCommand.swift` (subcommands), `P/skills/build/SKILL.md`, `P/skills/build/references/event-loop.md`, `P/skills/ship/SKILL.md`, `TC/BuildHaltCommandTests.swift`
- Does: design §5.6. `build halt` and `build resume` with closed `--reason` and `--answer`, writing to the main checkout's store. The skills call `halt` where they halt today (a stall watch firing, a question to the user, a RED gate, a merge conflict, an amend, the time budget) and `resume` with the answer.
- Tests: halt then resume gives `waitMs` from the 2 times on an injected clock and `parentID` = the halt (catches wait measured from the run start). Resume with no open halt exits non-zero and writes nothing. 2 concurrent resumes close 1 halt once (catches a race outside the lock). `--reason lunch` fails naming the allowed values. A halt for task A isn't closed by a resume for task B (catches a resume scoped to the run, not the task).

### `summary-reports-gate-time-and-flips`
- Deps: events-list-and-summary-read-every-store, gate-runs-record-tree-and-steps · Gate: push · Model: opus · estLines: 300
- Writes: `D/Events/Summary/GateTimeSection.swift`, `D/Events/Summary/WrongGatesSection.swift`, `TD/GateTimeSectionTests.swift`, `TD/WrongGatesSectionTests.swift`
- Does: design §6.2 Gate time, §6.3 flips and overturned findings. p50, p95, standard deviation and n per command, tier and step, split by `derivedData`.
- Tests, on small inputs worked by hand: p95 and standard deviation for a known list; n beside each. A same-tree RED then GREEN is 1 flip and marks its rules overturned; the pair with 1 dirty run isn't a flip (catches dirty runs compared). A RED for R on P, then a run with `allowanceCounts[R]` up by 1 and P gone, overturns R; up by 1 with P still named doesn't.

### `summary-reports-flaky-and-slow-tests`
- Deps: gate-runs-record-every-test-result, events-list-and-summary-read-every-store · Gate: push · Model: opus · estLines: 380
- Writes: `D/Events/TestRollup.swift`, `D/Events/Summary/TestsSection.swift`, `A/Events/EventSegmentStore.swift` (the rollup at seal), `TD/TestRollupTests.swift`, `TA/TestRollupStoreTests.swift`
- Does: design §8.3 rollup, §8.4. Sealing a `test.result` segment writes `<seq>.rollup.json`; the section reads rollups plus the active file. A missing rollup is rebuilt and listed as damage. Report the summary's wall time over a year-sized synthetic store built from the captured runs, in NOTES.
- Tests: pass and fail on 1 clean tree is flaky; the same outcomes on 2 trees isn't; a run where the test didn't run doesn't count (catches "not selected" read as pass). With rollups present, the section opens no sealed segment (counted through the injected reader). A rollup rebuilt from its segment equals the one written at seal. The slowest list ranks by p95 with n.

### `summary-finds-missed-reds`
- Deps: summary-reports-gate-time-and-flips · Gate: push · Model: opus · estLines: 300
- Writes: `D/Events/Summary/MissDetection.swift`, `D/Events/Summary/WrongGatesSection.swift`, `A/Events/BuildJoinReader.swift`, `TD/MissDetectionTests.swift`, `TA/BuildJoinReaderTests.swift`
- Does: design §6.3 misses. Read task returns, the ledger's write sets (read only) and build run events from a temp repo's git common dir. A miss names the task, the rule and both run ids.
- Tests: a GREEN task gate, then a RED on main naming a file in the task's write set, is 1 miss; a RED outside it is none (catches a miss on any later RED). A task whose gate was RED is never a miss. A missing ledger is listed as damage, not an empty result.

### `summary-reports-cost`
- Deps: agent-usage-is-ingested, events-list-and-summary-read-every-store · Gate: push · Model: opus · estLines: 260
- Writes: `D/Events/Summary/CostSection.swift`, `A/Events/PhaseWindowReader.swift`, `TD/CostSectionTests.swift`
- Does: design §6.2 Cost. Sum `agent.usage` and `judge.call` by role, agent, model, task and build run; join `messageTime` into `phases.jsonl` windows for design and plan phases. Unpriced usage is shown apart, with its token counts.
- Tests: 2 priced and 1 unpriced message give a total of the 2 and a separate unpriced line (catches unpriced cost counted as 0). A message on a phase boundary lands in exactly 1 phase. A cached `judge.call` adds 0 cost and 1 call.

### `summary-reports-hooks-and-caches`
- Deps: hook-decisions-are-recorded, cache-lookups-are-recorded, events-list-and-summary-read-every-store · Gate: push · Model: opus · estLines: 240
- Writes: `D/Events/Summary/HooksSection.swift`, `D/Events/Summary/CachesSection.swift`, `TD/HooksSectionTests.swift`, `TD/CachesSectionTests.swift`
- Does: design §6.2 Hooks and Caches, §5.4 bypass, §5.5 stale keys.
- Tests: a block then a same-hash `PostToolUse` 5 minutes later in the same session is 1 bypass; 11 minutes later, or another session, isn't. 1 key with 2 answer hashes is 1 stale key, and the section prints the invisible-stale note. Hit rate carries n.

### `summary-reports-halts-and-the-judge`
- Deps: build-halts-and-resumes-are-timed, summary-finds-missed-reds · Gate: push · Model: opus · estLines: 280
- Writes: `D/Events/Summary/HaltsSection.swift`, `D/Events/Summary/JudgeSection.swift`, `D/Events/Summary/SlotReplay.swift`, `TD/HaltsSectionTests.swift`, `TD/JudgeSectionTests.swift`
- Does: design §5.6, §6.2 Halts and Judge. Wait per reason; idle slot-minutes by replaying build transitions against the preset's `maxParallel`; retries per task; judge agreement and escalation share from `judge.decision`.
- Tests: a replay with 3 slots and 1 task in progress for 10 minutes gives 20 idle slot-minutes (catches idle counted per task). An open halt is listed as open, not as 0 wait. Escalation share carries n.

### `skills-ingest-and-print-the-summary`
- Deps: agent-usage-is-ingested, summary-reports-cost, summary-reports-halts-and-the-judge · Gate: push · Model: opus · estLines: 120
- Writes: `P/skills/build/SKILL.md`, `P/skills/build/references/event-loop.md`, `P/skills/ship/SKILL.md`, `TC/SkillCommandReferencesTests.swift` if the repo has no check that skill command lines parse
- Does: design §11.1. The build skill runs `events ingest --workflow-transcripts <dir> --role build-worker --task <task> --build-run <run>` at each completion; ship's finish step runs `events ingest --session <session> --role orchestrator` and prints `events summary --build-run <run>`.
- Tests: every `swiftgate` command line in the 3 files parses with the real argument parser (catches a flag the CLI doesn't have).

### `docs-describe-harness-telemetry`
- Deps: every task above · Gate: push · Model: opus · estLines: 160
- Writes: `README.md`, `docs/capabilities.md`, `docs/index.md`, `P/docs/testing-playbook.md` (a short section, within its budget)
- Does: describe telemetry as merged: on by default, the opt-out, what is and isn't collected, `events list|summary|ingest`, `build halt|resume`, `gc --events`, and where events live.
- Tests: none of its own; docs lint in the push gate.
