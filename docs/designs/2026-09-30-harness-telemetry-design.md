# swift-harness: harness telemetry

<!-- RESUME
Status: APPROVED 2026-09-30 by the user, with the 4 questions in §14 and the judge-log question decided.
Why: the user asked for telemetry "to self improve" the harness. Today time, cost, wrong gates, flakes, stuck
workers and halts are measured by hand after a run, and token cost isn't measured at all.
Builds on: the shared event envelope from the `judge-emits-judgement-events` branch (`HarnessEvent`, the append-only
writer, `.harness/events/<kind>.jsonl`, `judge.decision` and `judge.call`). Nothing here starts before that merges.
Plan: [`../plans/2026-09-30-harness-telemetry-plan.md`](../plans/2026-09-30-harness-telemetry-plan.md).
Read first: this header, §3, §5 and §14.
-->

## 1. Purpose

Record what happens in real harness runs as typed events on the machine that ran them. A person or a session can
then ask what was slow or expensive, which gate was wrong, which test flaked, where a worker stuck and how long a
halt waited, and answer from data instead of a hand-kept log.

Input: a research sweep of every store the gate writes today (2026-09-30), and the log and feedback notes of the
last end-to-end build of a sample app. In that build a person rebuilt cost, the timeline, the minutes lost per
stuck point, slot use and an overnight halt by hand, and 1 attempt's cost was "not measured".

### Goals

- 1 event per thing that happened, at 1 choke point per kind, in the envelope the judge work defines.
- Token and cost counts per session, agent, role and task, read offline from Claude Code transcripts.
- Every per-test result of every gate run, kept, with a reader that stays fast as the store grows.
- Worktree events that outlive the worktree, joined on main with the stores that exist today.
- A reader, `swiftgate events summary|list`, that answers the questions in §12 with 1 command each.

### Non-goals

- Anything over the network. No upload, no remote collector, no opt-in to one.
- A second envelope, or folding today's stores into the envelope. `history.jsonl`, `phases.jsonl`, the build
  run's `events.jsonl`, `review-log.jsonl` and task returns keep their formats; the reader joins them.
- A dashboard or a live view. The summary is text and JSON; a page can come later on top of `--json`.
- Gating on telemetry. No event decides a verdict, and no telemetry failure turns a gate RED.
- Per-tool-call traces of workers. The transcript already holds them, and §11 keeps them out.

## 2. What exists today

| Store | Writer | Holds | Gap |
|---|---|---|---|
| `.harness/runs/<id>/report.json`, `.harness/runs/history.jsonl` | `RunStore.record` (`plugin/gate/Sources/SwiftGateAdapters/RunStore.swift`), called by `GateRun.execute` and `StaticCheckRun` in `SwiftGateCLI`; 1 `O_APPEND` write under `flock` | verdict, per-tier ms, test counts, findings, allowance counts, `headCommit` (`RunHistory.swift`) | no per-step time, no per-test result, no tree hash. `keepRuns` copies a worktree's run directories but not its history, so worker gates never reach main's `stats` |
| `swiftgate stats` | `StatsCommand.swift` | p50 and p95 per command and tier; `--design` and `--build` views | no variance, no flakes, no cost |
| `<design run>/phases.jsonl` | `design-telemetry` (`DesignTelemetryCommand.swift`, `PhaseRecord` in `Design/DesignMetrics.swift`) | wall ms per design and plan phase | tokens and cost are `null` with a reason: the Workflow API reports no usage |
| `<ev>/review-log.jsonl` | the design skill | review finding dispositions | nothing like it for gate findings |
| build run `events.jsonl` (plan state, git common dir) | `Build/BuildRun.swift` | transitions, merges, undos, gate verdicts | no worker cost, no halt timing |
| `.harness/build/<run>/<task>.json` | `Build/TaskReturn.swift` | outcome, gate run id, tests added, notes | stuck points live only in prose |
| `.harness/hook-state/sessions/<id>.json` | `SessionRecordStore.swift` | `transcriptPath` (`Hooks/SessionRecord.swift`) | the transcript is the only real token source, and nothing reads it |
| hook traffic | `HookRecorder.swift` | payload and outcome | opt-in only, through `SWIFTGATE_HOOK_RECORD_DIR`, and it keeps payload text |
| caches | `ManifestAnswerCache.swift`, the judge cache, `Evidence/EvidenceCacheStore.swift` | answers | hit, miss and stale rates aren't counted |
| judge | the envelope branch: `judge.decision`, `judge.call` | each judgement and each backend call with tokens, cost and wall time | covered there; this design reads it |

## 3. Decision map

| Decision | Choice | Section |
|---|---|---|
| Envelope | the judge branch's `HarnessEvent`, unchanged; this design adds kinds and payloads only | §4 |
| Default | on in every repo with a `.swiftgate.toml`; `[telemetry] enabled = false` opts out (user, 2026-09-30) | §4.3 |
| Network | none, ever (user, 2026-09-30) | §7 |
| Cost source | Claude Code transcripts, read offline for counts only; no transcript text is stored (user, 2026-09-30) | §5.7 |
| Per-test results | every result of every gate run, kept (user, 2026-09-30) | §8 |
| Location | per worktree, copied up to main when the worktree is removed after its merge; existing stores stay (user, 2026-09-30) | §9 |
| Git | `.harness/events/` is ignored, in this repo and in the consumer ignore that bootstrap writes (orchestrator) | §4.3 |
| Emit point | 1 choke point per kind; a kind derived from others is computed by the reader, never emitted | §5 |
| Tree identity | the clean `HEAD` tree hash; a dirty tree has none and never counts as the same tree | §5.1 |
| Reader | `swiftgate events list` for raw lines, `swiftgate events summary` for answers; `stats` stays the budget view | §6 |

## 4. The envelope and the store

### 4.1 What this design takes as given

The `judge-emits-judgement-events` branch defines, and this design uses unchanged:

- `HarnessEvent {schemaVersion, eventID, parentID?, kind, time, runID?, head?, source: {route, tier?, hook?}, payload}`.
- A generic append-only writer protocol, and its file store writing `.harness/events/<kind>.jsonl`.
- The kinds `judge.decision` and `judge.call`, and `swiftgate judge events`.

Every kind below fills `source.route` with the command that emitted it (`check`, `hook`, `build`,
`events-ingest`), adding cases to the route type where it is closed. `parentID` links an event to the one that
caused it: a `gate.step` and each `test.result` point at their `gate.run`; a `build.resume` points at its
`build.halt`.

### 4.2 What this design adds to the store

- **A payload guard** in the writer's single write path. Every string value in a payload must be under 512 bytes, must
  not start with `/` or `~`, and must not contain a newline. The writer drops a rejected event and counts it in
  `.harness/events/dropped.json` by kind and reason; the emitting command prints 1 line naming the kind.
- **Closed payload types.** Each kind's payload is its own `Codable` struct in `SwiftGateDomain`. Strings are ids
  of known shapes (rule id, test id, model id, hash, repo-relative path), or raw values of closed enums. No
  payload has a free-text field, a `[String: String]` map, or an environment value.
- **Segments.** Each kind's active file rotates at a size threshold into a sealed segment (§8.2). Sealing never
  deletes.
- **A store identity.** `.harness/events/store.json` holds a random `storeID` and a random 32-byte `salt`,
  created on first write. Copy-up (§9) names an imported store by its `storeID`; hook input hashes (§5.4) use
  the salt.

### 4.3 On by default, off by config

`[telemetry]` is a new config table with 1 key, `enabled`, a boolean that defaults to `true`. Any other key in the
table fails config as an unknown key under `swiftgate.config`, as every table does. With `enabled = false` the
writer factory hands every emitter except the judge's a no-op writer. The judge kinds are an audit trail of decisions
that can block a merge, so the judge writes them whenever `[judge]` names a backend. `events ingest`
refuses with a message naming the key; `events list` and `summary` still read whatever exists. Outside a
project with `.swiftgate.toml`, no command writes events, as hooks already do nothing there.

`.harness/events/` goes into this repo's `.gitignore` (the judge branch adds it) and into `plugin/templates/gitignore`,
which bootstrap writes into a consumer repo.

## 5. Event kinds

Each row's emit point is the 1 place that writes that kind. Other code may gather timing or data and pass it in,
but only the named place calls the writer.

| Kind | Emit point | Payload |
|---|---|---|
| `gate.run` | `RunStore.record`, after the history append | `command`, `verdict`, `ms`, `treeHash?`, `dirty`, `base?`, `tiers`, `ruleCounts {ruleID: n}`, `findingPaths` (repo-relative, at most 200, plus `findingPathsTruncated`), `allowanceCounts`, `testCounts?` |
| `gate.step` | `RunStore.record`, 1 per step, after the `gate.run` | `tier?`, `step` (closed enum), `ms`, `verdict`, `derivedData` (`warm`, `cold`, `none`) |
| `test.result` | `RunStore.record`, 1 per test case, in 1 batched write | `test` (normalized id), `target`, `tier`, `outcome` (`passed`, `failed`, `skipped`, `expectedFailure`), `ms?` |
| `hook.decision` | `HookRunner.run`, around the event's hook | `event`, `tool?`, `decision` (`allow`, `block`, `ask`, `context`, `none`), `ruleIDs`, `ms`, `sessionID?`, `inputHash?` |
| `cache.lookup` | `ManifestAnswerCache.answer` and `store`; `EvidenceCacheStore`'s record, reuse and tombstone methods | `cache` (`manifest`, `evidence-claim`, `evidence-verdict`), `outcome` (`hit`, `miss`, `store`, `tombstone`), `keyHash`, `answerHash?`, `tombstoneReason?` |
| `build.halt` | new `swiftgate build halt` | `buildRun`, `task?`, `reason` (closed enum) |
| `build.resume` | new `swiftgate build resume` | `buildRun`, `task?`, `answer` (closed enum), `waitMs`; `parentID` is the halt |
| `agent.usage` | new `swiftgate events ingest` | `sessionID`, `agent` (`main`, `subagent`), `agentID?`, `role?`, `task?`, `buildRun?`, `model`, `messageID`, `messageTime`, `inputTokens`, `outputTokens`, `cacheCreationTokens`, `cacheReadTokens`, `costUSD?`, `priceTable` |

The reader derives `finding.outcome` (§6.3) and the flake, flip and idle-slot answers; no command writes them.

### 5.1 `gate.run` and the tree hash

`GateRun.execute` and `StaticCheckRun` already read `HEAD` for `headCommit`. They also read `git status
--porcelain`: on a clean tree, `treeHash` is `HEAD^{tree}` and `dirty` is `false`; on a dirty tree, `treeHash` is
absent and `dirty` is `true`. A dirty tree never matches another run, because untracked and modified files can
change a verdict without changing `HEAD`. Both values go to `RunStore.record` as new parameters; `report.json`
and `history.jsonl` don't change.

The event never copies finding messages: they can quote source. Rule ids, counts and paths are enough to
join a RED to the files it named.

### 5.2 `gate.step`

A step is 1 timed unit inside a tier: `resolve`, `build`, `test`, `coverage`, `lint`, `format`, `arch`, `docs`,
`judge`, `prove`, `mutate`, `simulator`, and the rest of what `check` runs today. The step type is a closed enum
that the task builds from the call sites that time a step. The places that already call `GateRun.timed` for a step hand their
`(step, tier, ms, verdict)` to a run-scoped collector, and `GateRun.execute` passes the collected list to
`RunStore.record`. `derivedData` is `warm` when the worktree's DerivedData directory existed before the step's
build, `cold` when it didn't, and `none` for a step that builds nothing.

### 5.3 `test.result`

`XUnitReport.parse` and `XcresultTestResults.parse` gain each case's duration: the `time` attribute of a
`<testcase>` and the `durationInSeconds` of an xcresult test node, both already in the captured fixtures. A case
with no duration has `ms` absent, never 0. `HostTestCheck` and `SimulatorTestCheck` hand the parsed cases up to
`GateRun.execute` beside the report, and `RunStore.record` writes them. The case list never enters `report.json`.

The test id is `<target>.<suite>/<name>` for both sources, so a host run and a simulator run of the same test
join. An id over 512 bytes becomes `sha256:<hex>` with `testHashed: true`. The event never holds a failure
message: it quotes source and values.

### 5.4 `hook.decision`

`HookRunner.run` measures the hook it dispatches and writes 1 event per hook call with the decision the hook
returned. `tool` is the payload's tool name when it matches `[A-Za-z0-9_]{1,128}`, and absent otherwise.
`inputHash` is the HMAC-SHA-256 of the tool input under the store's salt, so 2 calls with the same input match
inside 1 store, and nobody can recover a short command by hashing guesses. The event never holds command text, file paths
or prompt text. `HookRecorder` stays as it is: an opt-in debugging aid that keeps payloads,
unrelated to telemetry.

The reader derives a bypassed block: a `block` on a `PreToolUse` followed, in the same session within 10 minutes, by a
`PostToolUse` for a call with the same `inputHash`.

### 5.5 `cache.lookup`

`keyHash` is the SHA-256 the cache already computes for its key. `answerHash` is the SHA-256 of the stored answer
on `store` and `hit`. A stale answer shows up when 1 `keyHash` has stored 2 different `answerHash` values over
time: the key missed an input. A stale hit that no later `store` replaces stays invisible; the summary says so beside
the count. The judge cache is not a `cache.lookup` source: `judge.call` already carries `cached`, and counting it
twice would double the rate.

### 5.6 `build.halt` and `build.resume`

`swiftgate build halt --run <build run> [--task <task>] --reason <reason>` and `swiftgate build resume --run
<build run> [--task <task>] --answer <answer>` write to the main checkout's store, where the orchestrator runs.
Reasons: `question`, `stall`, `gate-red`, `merge-conflict`, `amend`, `budget`, `permission`. Answers: `retry`,
`wait`, `abandon`, `amend`, `continue`. `resume` finds the newest open halt for the same run and task, sets
`parentID` to it and computes `waitMs`; with no open halt it exits non-zero and writes nothing. The build and
ship skills call both where they halt and resume today.

Idle slots and retries need no new event: the reader replays the build run's `events.jsonl` transitions
against `maxParallel` from the run's preset.

### 5.7 `agent.usage` and transcript ingest

`swiftgate events ingest --session <id> [--workflow-transcripts <dir>] [--role <role>] [--task <task>] [--build-run <id>]`
reads usage counts, offline, from:

- the session's own transcript, at the `transcriptPath` the session record already keeps;
- with `--workflow-transcripts`, every `agent-*.jsonl` in the transcript directory the Workflow tool printed
  for a worker, which the build skill passes at each completion.

From each assistant line it reads only `message.id`, `message.model`, `message.usage` (input, output, cache
creation and cache read tokens) and `timestamp`. Claude Code writes 1 line per content block with the same
usage, so ingest deduplicates lines by `message.id`. Ingest is idempotent: it skips any `messageID` already in the
store for that session. Ingest stores no transcript text, tool input, path or prompt, and writes neither path
anywhere.

`costUSD` comes from a price table in `SwiftGateDomain`, keyed by model id, with its source and date. A model
missing from the table gives `costUSD` absent and a line in the ingest output naming the model, never 0.
`priceTable` records the table's version so a later price change can't rewrite old totals unnoticed.

`role` is a closed enum: `orchestrator`, `design`, `plan`, `build-worker`, `review`, `qa`. Design and plan phase
cost comes from joining `messageTime` into the phase windows of `phases.jsonl`.

## 6. Readers

### 6.1 `swiftgate events list`

`events list --kind <kind> [--since <duration|date>] [--run <id>] [--session <id>] [--json]` prints matching
events as JSON lines, oldest first, from the active files, sealed segments and imported stores (§9). It's the raw
access every query in §12 that `summary` doesn't cover builds on.

### 6.2 `swiftgate events summary`

`events summary [--since 7d] [--run <id>] [--build-run <id>] [--json]` prints sections:

| Section | From |
|---|---|
| Cost | `agent.usage` and `judge.call`, by role, agent, model, task and design phase |
| Gate time | `gate.run` and `gate.step`: p50, p95, standard deviation and n per command, tier and step, warm vs cold |
| Wrong gates | flips (§6.3), overturned findings and misses |
| Flaky tests | §8.4 |
| Hooks | latency p50 and p95 per event, blocks per rule, bypassed blocks |
| Caches | hit rate and stale keys per cache, with the invisible-stale note |
| Halts | wait per reason, idle slot-minutes, retries per task |
| Judge | agreement and escalation share, from the judge kinds |
| Store | size per kind, sealed segments, dropped events, damaged lines |

Every number carries its n, and a section with no events says so rather than printing zeros. The reader lists damage (a torn last
line, an undecodable line, an unreadable segment) by file and line in a `damage` section and never drops it
unannounced; the command still exits 0, since nothing here gates.

### 6.3 Derived: flips, overturned findings, misses

- **Flip.** 2 `gate.run` events with the same `command`, tiers and `treeHash`, both clean, and different
  verdicts. A RED then GREEN flip marks every rule in the RED's `ruleCounts` as overturned for that tree.
- **Overturned by an allow.** A RED for rule R naming path P, then a later run where `allowanceCounts[R]` rose
  and P is no longer named.
- **Miss.** A task's gate run (from its task return) was GREEN, and a later `gate.run` on main is RED with a
  finding path inside that task's write set (from the ledger, read only). The reader reports the task, the rule
  and both run ids.

### 6.4 How `stats` relates

`stats` stays the budget view over `history.jsonl`: p50 and p95 per command and tier against the configured
budgets, plus `--design` and `--build`. It doesn't read events. `events summary` is the diagnosis view: variance,
steps, flakes, cost and wrong gates. Worker gate runs reach main through copied-up `gate.run` events, so the
summary covers them while `stats` keeps counting only the checkout's own history, as it does today.

## 7. Privacy

Allowed in a payload: ids, counts, milliseconds, model ids, rule ids, test ids, hashes, closed enum values and
repo-relative paths. Never collected: source text, finding or failure messages, diffs, prompts, transcript text,
tool inputs, shell commands, environment values, API keys (Jev's included) and any absolute path.

The guard in §4.2 enforces the shape; the closed payload types enforce the content. Nothing in this design opens
a socket: there is no endpoint, flag or config key that sends events anywhere. Ingest reads transcripts where Claude
Code wrote them, and only counts leave the read.

## 8. Volume and retention for every test result

### 8.1 Size

This repo's push gate runs about 2,500 tests. A `test.result` line, envelope included, is about 330 bytes, so 1
run writes about 0.8 MB. A heavy build day of 40 gate runs that test writes about 33 MB of raw lines. Repetitive
JSON compresses well; the first store task measures the real ratio on a real gate run's lines and records it in
the plan. App repos run far fewer tests per gate.

### 8.2 Rotation and sealing

Each kind has an active file, `.harness/events/<kind>.jsonl`. After a write, under the same lock, the writer checks
the file's size: past 16 MB for `test.result` or 4 MB for any other kind, it renames the file to
`.harness/events/sealed/<kind>/<seq>.jsonl`, where `seq` is the next number in that directory. The writer then
releases the lock, and the sealer compresses the segment with LZFSE to `<seq>.jsonl.lzfse`, writes `<seq>.index.json`,
and removes the uncompressed file. A reader treats an uncompressed sealed file as readable, so a sealer killed
halfway loses nothing.

A batch (1 run's test results) is 1 write, and rotation happens only between writes, so a run's results never
span 2 segments.

### 8.3 Index and rollup

`<seq>.index.json` holds the segment's first and last time, line count, byte counts, SHA-256 of the
uncompressed lines, and the run ids it holds. `--since` and `--run` read only the indexes to choose segments.

For `test.result`, sealing also writes `<seq>.rollup.json`. It holds a test id dictionary and, per run, its
`treeHash`, `dirty`, the indexes of tests that ran and those that failed or skipped. Per test, it holds n, ms sum,
ms max and a fixed 32-bucket duration histogram. The flaky and slow-test sections read rollups plus the active file and never
decompress a sealed segment. The reader rebuilds a missing or unreadable rollup from its segment on the
next read and lists it under damage.

### 8.4 Flake detection

A test is flaky on a tree when, across clean runs with that `treeHash`, it ran in at least 2 runs and both passed
and failed. Runs on different trees, dirty runs and runs where the test didn't run never count. The section lists
each flaky test with its pass and fail counts and the run ids, and the share of clean trees on which each flaked.

### 8.5 Retention

No command deletes events on its own: the user decided to keep every result. `swiftgate gc` touches events only with
`--events --older-than <days>`, which removes sealed segments, their indexes and rollups whose last time is
older, and never an active file. The summary's store section prints the size per kind, so growth is visible.

## 9. Location and merge copy-up

Events live in the worktree that produced them, under its `.harness/events/`. When `swiftgate worktree remove`
deletes a merged task worktree, it already copies the worktree's run directories into the main checkout
(`keepRuns`). Beside that, it copies the worktree's whole `.harness/events/` to the main checkout's
`.harness/events/imported/<storeID>/`. If that directory exists and the source holds more bytes, the copy goes to
a temporary directory and replaces it with 1 rename; otherwise `remove` keeps it. The remove report names a failed copy, and removal still goes ahead, as it does for runs.

The reader reads `.harness/events/` and every `imported/<storeID>/` below it, and deduplicates by `eventID`. The
other stores stay where they are: `history.jsonl` per checkout, `phases.jsonl` per design run, build `events.jsonl`
and the ledger in the git common dir, task returns under `.harness/build/`. The reader joins them by run id,
build run, task and time.

## 10. Concurrency

Writers append under an exclusive `flock` on the kind's active file, in 1 `O_APPEND` write per event or batch,
as `RunStore.append` does today. Rotation's rename happens under that lock; compression and the index happen
after, on a file nobody writes. Several sessions, hooks and gates can share a worktree; their lines never
interleave. Readers take no lock. The reader skips a torn last line in an active file and counts it as damage, as
`BuildEventLog.Damage` does for build events. `build halt` and `resume` serialize on the halt kind's lock, so 2
resumes can't both close 1 halt.

## 11. Consumers, and what not to collect

### 11.1 Consumers

- **The ship finish step** runs `events ingest` for the session and `events summary --build-run <id>`, and prints
  the summary, so a build's cost, timeline, stuck points and slot use come from data.
- **The build skill** runs `events ingest --workflow-transcripts <dir> --role build-worker --task <task>` at
  each worker's completion, and `build halt`/`resume` where it halts.
- **The orchestrator's status table** cites `events summary --since <window> --json`.
- **The evals runner** can read a case repo's `events summary --json` and `events list --kind agent.usage`
  before the runner deletes the case repo. The evals session owns `evals/runner/`; no task here edits it.
- **A session improving the harness** reads `events summary --since 30d` and turns its worst numbers into
  issues: the slowest steps by p95, the flakiest tests, the rules most often overturned, the halts that waited
  longest.

### 11.2 What not to collect

- Per-tool-call traces of workers; the transcript already has them.
- Diffs, file contents, finding messages, failure messages or any text from the consumer app beyond ids.
- Shell commands, prompts, environment values, keys or absolute paths.
- Anything sent anywhere, or anything a person types beyond the closed halt and resume enums.

## 12. Questions it answers

| Question | Query |
|---|---|
| What did a build cost, by role, agent, model and task? | `swiftgate events summary --build-run <id>` (Cost) |
| What did each design and plan phase cost? | `swiftgate events summary --since 7d --json`, `.cost.byPhase` |
| Which gate verdicts flipped on an identical tree? | `swiftgate events summary --since 30d` (Wrong gates: flips) |
| Which rules are most often overturned? | `swiftgate events summary --since 30d --json`, `.wrongGates.overturnedByRule` |
| Which GREEN task gates missed a RED that landed later? | `swiftgate events summary --since 30d` (Wrong gates: misses) |
| Which step is slow, and how much does it vary? | `swiftgate events summary --since 14d` (Gate time) |
| Does a cold DerivedData explain a slow merge gate? | `swiftgate events summary --since 14d --json`, `.gateTime.byStep[] \| select(.step=="build")`, warm vs cold |
| Which tests flake, and how often? | `swiftgate events summary --since 30d` (Flaky tests) |
| Which tests are slowest? | `swiftgate events summary --since 7d --json`, `.tests.slowest` |
| How long did halts wait, and why? | `swiftgate events summary --build-run <id>` (Halts) |
| How many worker slots sat idle? | `swiftgate events summary --build-run <id> --json`, `.halts.idleSlotMinutes` |
| Where did workers get stuck? | `swiftgate events list --kind build.halt --since 7d --json \| jq 'select(.payload.reason=="stall")'` |
| How slow are hooks, and which rules block most? | `swiftgate events summary --since 7d` (Hooks) |
| Which blocks were bypassed? | `swiftgate events summary --since 7d --json`, `.hooks.bypassed` |
| Do the caches hit, and are any stale? | `swiftgate events summary --since 7d` (Caches) |
| How often does the judge escalate, and does it agree? | `swiftgate events summary --since 30d` (Judge), or `swiftgate judge events` |
| Did 1 gate run's tests all pass, and how long did each take? | `swiftgate events list --kind test.result --run <run id> --json` |

## 13. Testing the harness

- **Fixtures from real runs only.** A capture task runs 2 throwaway Claude Code sessions in a temporary
  directory, 1 with a subagent, with `--output-format json`. It keeps each transcript filtered to the keys
  ingest reads, with the `jq` filter and the command in `plugin/gate/Tests/Fixtures/README.md`, and keeps the
  envelope's `total_cost_usd` beside it. The test results come from the xunit and xcresult fixtures that exist; the
  `gate.run` fixture is a `report.json` from a real `check` run.
- **Exact sums.** Ingesting the captured transcript gives token sums equal to its usage lines deduplicated by
  message id, and a cost within 1% of the envelope's `total_cost_usd` (catches a per-content-block double count
  and a wrong price key).
- **Concurrency.** 8 processes append 500 events each to 1 kind; the file holds 4,000 decodable lines (catches a
  write outside the lock).
- **Rotation.** A write past the threshold seals the file; a batch never splits; a killed sealer leaves a
  readable uncompressed segment.
- **Privacy.** A sentinel key in the environment, a finding message and a tool input appears in no event file
  after a gate run and a hook call; the writer drops and counts an absolute path in a payload.
- **Wrong gates.** A seeded same-tree RED then GREEN is a flip; the same pair with 1 dirty run isn't. A seeded
  GREEN task gate followed by a RED in its write set is a miss; a RED outside it isn't.
- **Flakes.** The section flags mixed outcomes on 1 clean tree, and not the same outcomes on 2 trees.
- **Reader speed.** With rollups present, the flaky section opens no sealed segment (counted through the
  injected file reader).

## 14. Decisions

| # | Question | Decision | By |
|---|---|---|---|
| 1 | On by default in consumer repos? | Yes. `[telemetry] enabled = false` opts out. Local only, never over the network | user, 2026-09-30 |
| 2 | Read Claude Code transcripts for cost? | Yes, for token and cost counts only, offline, from the transcript paths the harness already has. No transcript text is stored | user, 2026-09-30 |
| 3 | How many per-test results? | All of them, for every gate run, not a sample. The store is built for that volume: rotation, compressed sealed segments, indexes and rollups (§8) | user, 2026-09-30 |
| 4 | Where do events live? | Per worktree, copied up to main on merge the way `keepRuns` copies run directories. Existing stores stay as they are, and the reader joins them | user, 2026-09-30 |
| 5 | Is `.harness/events/` committed? | No: git-ignored, added by the judge audit-log branch | orchestrator, 2026-09-30 |
| 6 | Does `enabled = false` silence the judge kinds too? | No: the judge log is an audit trail of decisions that can block a merge, so it is written whenever a judge is configured. The opt-out covers every other kind | user, 2026-09-30 |
| 7 | Where do worker transcripts come from? | The session record keeps the main session's path; the Workflow tool prints each worker's directory, which the build skill passes to `events ingest` at completion. The directory is read, never stored | design; the user to confirm |
