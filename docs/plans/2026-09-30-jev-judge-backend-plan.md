# Jev judge backend: implementation plan

<!-- RESUME
Status: NOT STARTED. The user decided the design's §12 on 2026-09-30. The live tasks need a TypeSafe API key, and the labelling task needs the user's time.
Spec: docs/designs/2026-09-30-jev-judge-backend-design.md (approved 2026-09-30). Decision record: [ADR 0007](../adrs/0007-jev-is-an-opt-in-second-judge-backend.md).
Scope: a working `JevJudge` behind the judge seam; a Jev block only with a passing block calibration per question and pinned model, checked in code; a Claude-written reason on every blocking finding; a person-labelled set of 30 or more cases per blocking question; the commit comment judge and `calibrate design` on either backend; per-backend recordings and a freshness check; `swiftgate judge ask`; a live A/B. Out of scope: moving eval rubrics onto `judge ask` (the evals owners trial 1 rubric first), and the design's §11.2 later candidates.
Resume: read this header, then "Wave map", then your task's section (grep for the task id). Grep the spec by §.
Orchestrator procedure: docs/handoffs/subproject-2-orchestrator-runbook.md, with the changes in "How to work this plan". Interfaces note: docs/handoffs/jev-judge-interfaces.md (the first wave's merge creates it; each wave appends).
Build for correctness (user decision): every task is surface-first, on opus, through the push + prove merge gate, with mutate once on main per wave or per 2 waves.
Progress: git log. Update this header at every wave merge.
-->

## Decisions made while planning

The user decided the design's §12 questions on 2026-09-30; the rows marked "user" record those decisions. The
other rows are the plan's own choices within them. The row marked "user (confirm)" is a choice the design's
decisions leave open; the orchestrator asks the user before `jev-blocks-carry-a-claude-reason` starts.

| Decision | Evidence | Choice | Needs |
|---|---|---|---|
| Blocking (§12 decision 1) | §7 | Jev may block `ready` on its own for a question, only when `JudgeBlockCalibration` passes for that question id and the pinned model. Otherwise the finding is minor with a note. A new pin makes it stale | user |
| Reasons (§12 decision 3) | §6 | Template reason on advisory findings; a Claude-written reason on every blocking finding, a calibrated Jev block included | user |
| Eval runner (§12 decision 2) | §8 | `judge-ask-answers-any-question-set` builds `ask`. The evals owners trial it on 1 rubric split into 1 Noul per clause; no task here edits `evals/runner/` | user |
| Egress opt-in (§12 decision 4) | §5 | `send_to = "api.typesafe.ai"` required with `backend = "jev"`; the key from `TYPESAFE_API_KEY` | user |
| Tier criteria (§12 decision 5) | §4.1 | `test-quality@1` unchanged for the A/B | user |
| Where the block calibration lives | the user asked for "a calibration record … for that question id and Jev version"; a separate summary file could drift from, or be edited apart from, the recording it summarises | The record is the committed `J/recording-jev.json` scored against `J/labels.json`. Pure domain code computes pass or fail at every ready run; no summary file | — |
| The bar's numbers | evals design: 30 or more labelled cases, rates reported against a person's labels, and Jev kept only if its rates match Claude's; `J/baseline.json` sets 0.8 for every question | 30 person-labelled cases per question, at least 10 on each side; true-positive and true-negative rates of at least 0.8 and at least Claude's on the same cases, at the repository's `block_threshold`. Constants in the domain type, 1 test per number | — |
| Who labels | the sub-project 2 review: the tuning agent labelled today's 22 cases | A `labeller` field, `person` or `agent`, on each case; only `person` counts. A missing field reads as `agent` | — |
| Blind labelling | today's case directory names give the intent away (`existence-only`, `own-double`) | The labelling sheet shows neutral numbers, the test and the diff only. New case directories get neutral names | — |
| Claude can't write the reason | §6: no `claude` on `PATH`, a timeout, an error | The block stands with the template reason, and `failureScenario` names why Claude's reason is missing. The alternative is to downgrade the finding to advisory | user (confirm) |
| Where the placeholder goes | `JevJudge` in `A/Judge.swift` throws `notConfigured`; `JudgeBackend.jev` already parses; `JudgeFactory.make` already switches on it | `jev-judge-answers-over-http` replaces the placeholder in place. No new backend case, no new config key for the backend | — |
| HTTP transport | the gate has no HTTP client; `curl` through `ProcessRunner` would put the key in an argument list | `HTTPTransport` protocol in `A/HTTP/`, a live type on `URLSession(configuration: .ephemeral)`, a replaying fake in `S/` | — |
| The pinned model | TypeSafe's models page (2026-09-30): `jev-latest` and `jev-preview` both resolve to `jev-1.13.0`; pinning a version is their advice for tuned thresholds | Default `jev-1.13.0`; an alias fails config. The capture task records the served id for `jev-latest` | — |
| The price | $0.042 per million input tokens for `jev-1.13.0`, output free (models page, 2026-09-30) | A constant beside the pin in `A/Judge/JevPin.swift`, with a test that fails when the captured served model differs from the pin, so a pin bump forces a look at the price | — |
| Usage without a protocol break | `FakeJudge`, `RecordedJudge`, `CachingJudge`, `DesignCalibrationRunner` and many tests call `answer` | `measuredAnswer` with a default in a protocol extension (design §4.5); only `ClaudeCLIJudge`, `JevJudge` and `CachingJudge` override it | — |
| A/B spend | 30 or more cases on each backend, plus the design seeds' judged labels on stored replies | The orchestrator reports the estimated cost before `judge-backends-ab-on-labelled-sets` runs; the user approves it | user |

## How to work this plan

The runbook applies as written, with these changes:

- **Model.** Every worker on `opus`.
- **Surface first.** Each worker commits its new API as a behaviour-free surface commit, then tests and
  behaviour, and proves at it (worker brief pitfall 10), and runs `swiftgate surface-check <surface sha>` on it.
- **Merge gate.** Push + `prove --base main` on 1 integration worktree. With more than 1 surfaced branch in a wave,
  merge every surface commit first and prove at that merge. Mutate runs once on `main` after each wave, or once per
  2 waves when the first of the pair adds only doc text.
- **Id policy.** Task ids and wave numbers never appear in code, comments, test names or commit messages.
- **Labelling.** The user attends `blocking-questions-reach-thirty-person-labels`: the user labels, and no agent
  writes or suggests a label. The orchestrator hands the user the sheet and commits the answers as given.
- **Network.** Only the 2 tasks marked `Needs: user (key)` call `api.typesafe.ai`, in the foreground, with the
  user's `TYPESAFE_API_KEY` in the environment. No test calls the network. No task writes the key to a file, a
  commit or a log.
- **Generic harness.** No task names an app shape, practice prompt or preset value beyond the template's.
- **Evals.** The evals session owns `evals/runner/` and `evals/sessions/`. Tasks here write only a new results
  directory under `evals/results/`. Tell that session before `judge-ask-answers-any-question-set` merges.
- **Paths.** `D/` = `plugin/gate/Sources/SwiftGateDomain/`, `A/` = `plugin/gate/Sources/SwiftGateAdapters/`,
  `C/` = `plugin/gate/Sources/SwiftGateCLI/`, `S/` = `plugin/gate/Sources/SwiftGateTestSupport/`,
  `TD/` `TA/` `TC/` = `plugin/gate/Tests/SwiftGate{Domain,Adapters,CLI}Tests/`, `F/` =
  `plugin/gate/Tests/Fixtures/`, `J/` = `plugin/gate/Fixtures/judge/`, `P/` = `plugin/`.

### Merge points (hot files)

| File | Edited only by |
|---|---|
| `A/Judge.swift` | `judges-report-usage`, then `jev-judge-answers-over-http` (different waves) |
| `D/Config/Config.swift`, `D/Config/ConfigSchema.swift`, `D/Config/ConfigIssue.swift` | `jev-blocks-only-when-calibrated` (`JudgeBackend` only), then `config-pins-jev-and-names-its-host` |
| `C/Commands/JudgeCommands.swift` | `jev-blocks-only-when-calibrated`, then `commit-comment-judge-runs-on-jev`, then `self-test-scores-each-backend-recording`, then `jev-blocks-carry-a-claude-reason`, then `judge-ask-answers-any-question-set` (1 per wave) |
| `A/Calibration/DesignCalibrationRunner.swift`, `C/Commands/CalibrateCommand.swift` | `calibrate-design-keeps-agent-replies`, then `calibrate-design-judges-through-any-backend` |
| `F/README.md` | `jev-replies-are-captured` only |
| `J/labels.json`, `J/cases/` | `blocking-questions-reach-thirty-person-labels` only |
| `J/recording*.json`, `J/baseline*.json` | `judge-backends-ab-on-labelled-sets` only (recordings and baselines come from its live run) |
| `plugin/docs/standards.md` rule id index | `self-test-scores-each-backend-recording` ("Harness and environment", 1 new id), then `calibrate-design-judges-through-any-backend` (the `calibration-freshness.wrong-model` row's text) |
| `plugin/docs/testing-playbook.md` §5.4 | `playbook-documents-the-jev-backend` only. The hook-name fix tracked outside this plan edits the same section: whichever merges second rebases |

### Rule id index rows

1 new id: `swiftgate.self-test.judge-stale`, added to the `swiftgate.self-test` row under "Harness and
environment" by the task that adds the check. The `calibration-freshness.wrong-model` row gains the judge case
in the task that extends it. `judge.*` ids don't change: a Jev finding reuses them, blocking or downgraded, and a
Jev failure is `judge.not-run`. A new `ConfigIssue` reports under `swiftgate.config`, which the index already lists. Each task's
tests include the existing index test, which fails when an id the registries report has no row.

### Risks

- **Access.** TypeSafe's API sits behind an early-access list. Without a key, waves 1 and 7's live tasks wait;
  the other tasks run on captured fixtures once wave 1 lands them.
- **Rate limits.** TypeSafe says its limits change without notice. The adapter retries 429 and 529 inside its
  timeout; the A/B runs with `JudgeBatch`'s 4 concurrent requests, well under 40 per second.
- **Prompt injection.** Jev doesn't treat state as hostile by default, and a test's comments can argue for their
  own verdict. The A/B reports the cases where the backends disagree, so a person can read them.
- **Labelling time.** 30 person labels per blocking question, 10 on each side, means relabelling the 22 cases
  and adding at least 8 more. Until that task merges, every Jev finding stays advisory, which the code already
  handles; only the A/B waits on it.
- **Standards index churn.** 2 tasks edit rows in different waves.

## Wave map

| Wave | Tasks | Why |
|---|---|---|
| 1 | `jev-replies-are-captured`, `judges-report-usage`, `jev-blocks-only-when-calibrated` | independent foundations: real replies, usage on the protocol, and the block guard before any Jev answer exists |
| 2 | `jev-judge-answers-over-http`, `config-pins-jev-and-names-its-host`, `calibrate-design-keeps-agent-replies`, `blocking-questions-reach-thirty-person-labels` | the adapter needs the captures and usage; config waits for `JudgeBackend`'s wave-1 edit; the labels need the `labeller` field; stored replies have no deps |
| 3 | `commit-comment-judge-runs-on-jev`, `calibrate-design-judges-through-any-backend` | both call the adapter; disjoint files |
| 4 | `self-test-scores-each-backend-recording` | needs the adapter and usage; takes `JudgeCommands.swift` this wave |
| 5 | `jev-blocks-carry-a-claude-reason` | needs the block guard and the adapter; takes `JudgeCommands.swift` this wave |
| 6 | `judge-ask-answers-any-question-set` | takes `JudgeCommands.swift` last, since `judge` becomes a group |
| 7 | `judge-backends-ab-on-labelled-sets`, `playbook-documents-the-jev-backend` | the live run needs every path above and the person labels; the docs state its results |

### `jev-replies-are-captured`
- Deps: none · Gate: push · Model: opus · estLines: 120 · Needs: user (key)
- Writes: `F/Judge/jev-request-test-quality.json`, `F/Judge/jev-request-comments.json`, `F/Judge/jev-request-invalid.json`, `F/Judge/jev-request-alias.json` (request inputs), `F/Judge/jev-*.reply.json` and `F/Judge/jev-*.status` (captured), `F/README.md` (a "Jev" section)
- Does: design §13 first bullet. Build each request from a real subject: the `counter-increment` and `own-double` cases in `J/cases/` for `test-quality@1` (all 3 Jev types), and 1 staged comment from this repo's history for `comments@1`. Send each with `curl -sS -o <name>.reply.json -w '%{http_code}\n' -H @<(printf 'Authorization: Bearer %s\n' "$TYPESAFE_API_KEY") -H 'Content-Type: application/json' --data-binary @<request> https://api.typesafe.ai/v1/systemone > <name>.status`. Capture a 401 with the key replaced by `invalid`, a 422 from a Choice question with no `criteria`, and `jev-latest` for the served id. Record each command, the date, and the served model for every reply. The README section also notes: question keys with hyphens round-trip, the Score `legend` and `probabilities` key shape, and that no reply carries a reason.
- Tests: none of its own (fixture task). The next wave's tests consume every file; a file no test reads fails that wave's review.

### `judges-report-usage`
- Deps: none · Gate: push · Model: opus · estLines: 220
- Writes: `D/Judge/JudgeUsage.swift`, `A/Judge.swift` (`measuredAnswer` on `Judge` with a default; `ClaudeCLIJudge` and `CachingJudge` overrides; `ClaudeJudgeReply` reads `total_cost_usd` and `duration_ms`), `TA/JudgeAdaptersTests.swift`
- Does: design §4.5. `JudgeReply {answers, usage: JudgeUsage?}`; `JudgeUsage {inputTokens?, outputTokens?, costUSD?, durationMilliseconds, servedModel?, cached}`. The default `measuredAnswer` wraps `answer` with no usage. `CachingJudge` returns a hit with `cached: true` and 0 cost, and passes a miss's usage through.
- Tests: the captured `Judge/claude-result.json` yields its `total_cost_usd` and `duration_ms` (catches usage read from the wrong keys). A cache hit reports `cached` and 0 cost, and a miss reports the inner judge's usage (catches a cache that bills twice or hides a live call). `FakeJudge`'s default usage is `nil`, and existing judge tests pass unchanged.

### `jev-blocks-only-when-calibrated`
- Deps: none · Gate: push · Model: opus · estLines: 420
- Writes: `D/Judge/JudgeBlockCalibration.swift`, `D/Judge/JudgeCalibration.swift` (`labeller` on each case), `D/Judge/Judge.swift` (`JudgePolicy` takes a block decision per question), `D/Config/Config.swift` (`JudgeBackend.needsBlockCalibration`), `A/Judge/JudgeCalibrationFiles.swift` (reads `labels.json` and the per-backend recordings under the harness root; names `recording-<backend>.json`), `C/Commands/JudgeCommands.swift` (`TestJudgeCheck` wiring), `TD/JudgeBlockCalibrationTests.swift`, `TD/JudgeTests.swift`, `TC/CheckJudgeStepTests.swift`
- Does: design §7.1-7.3. `JudgeBlockCalibration.evaluate(question:model:blockThreshold:set:jev:claude:)` is pure and returns `.passes(rates)` or `.fails(reason)`. It checks, in order: a Jev recording exists; it answers the check's question set version; its model equals the pin. Then: at least 30 `person` labels for the question, at least 10 on each side. Last: true-positive and true-negative rates at `blockThreshold` of at least 0.8 and at least Claude's on the same cases. `JudgeBackend.needsBlockCalibration` is `false` for `claude` and `true` for `jev`. For a Jev identity, `TestJudgeCheck` loads the files from `SWIFTGATE_HARNESS_ROOT` and passes each question's decision to `JudgePolicy`. A failed decision keeps the finding minor with `advisory: jev has no passing block calibration for <question> on <model>: <reason>`. A missing root or file is a failed decision, never a crash and never a block. The labels file decodes today's cases, which have no `labeller`, as `agent`.
- Tests, each written to fail before the code exists: a Jev answer at p=0.99 on `fails-if-broken` at `ready` with no recording is minor and names `no recording` (catches a Jev block with no calibration). A recording from `jev-1.12.0` with a `jev-1.13.0` pin is minor and names both models (catches a stale calibration that still blocks). 29 `person` labels is minor naming `29 of 30`; 30 labels with 9 on 1 side is minor. 30 `agent` labels is minor (catches the tuning agent's labels counting). A true-negative rate of 0.79 is minor; rates of 0.8 below Claude's are minor. A passing calibration for `asserts-implementation` leaves `fails-if-broken` minor (catches a calibration read per backend, not per question). A passing calibration for `fails-if-broken` at `jev-1.13.0` makes it major and `ready` RED. Raising `block_threshold` from 0.8 to 0.95 on the same recording can turn a pass into a fail (catches rates computed at a fixed 0.5). The same answer from a `claude` identity is major with no calibration files at all (catches a change to today's Claude behaviour).

### `jev-judge-answers-over-http`
- Deps: jev-replies-are-captured, judges-report-usage · Gate: push · Model: opus · estLines: 480
- Writes: `A/HTTP/HTTPTransport.swift` (protocol, `URLSessionTransport`), `A/Judge/JevPin.swift`, `A/Judge.swift` (`JevJudge`, `JudgeFactory`), `S/FakeHTTPTransport.swift`, `TA/JevJudgeTests.swift`
- Does: design §4.1-4.4, §9. Replace the placeholder. Build the request (state object, 1 question per id, the type and `criteria` mapping), send it with the key from `TYPESAFE_API_KEY` read through an injected environment, decode the reply to distributions, run `JudgeAnswers.validate`, and return `rationale: nil`. Check the served model equals the requested one and each Score `legend` matches the options. Errors, retries and the timeout as in §4.3; a state over 30K estimated tokens fails before sending. `measuredAnswer` reports input tokens and cost at `JevPin.pricePerMillionInputTokens`. `JudgeFactory` builds it with the live transport and the process environment.
- Tests: each captured reply decodes, and a Score reply with its levels reordered fails naming the question (catches a level-to-option swap). The built request for the captured subject equals the captured request byte for byte after key sorting (catches a drift between what the tests assume and what went over the wire). The captured 401 and 422 map to `backend` errors naming the variable and the body. A missing key is `notConfigured` naming `TYPESAFE_API_KEY` and sends nothing. A fake 429 then 200 succeeds once, and 429 until the timeout fails. A sentinel key appears in no error, cache file or usage value (catches a key leak). A 31K-token state fails without a request. A served model that isn't the pin is `malformedReply`. The pin test compares `JevPin.model` with the captured served id.

### `config-pins-jev-and-names-its-host`
- Deps: jev-blocks-only-when-calibrated · Gate: push · Model: opus · estLines: 200
- Writes: `D/Config/Config.swift`, `D/Config/ConfigSchema.swift`, `D/Config/ConfigIssue.swift`, `A/Config/ConfigDecoding.swift` if it lists keys, their tests
- Does: design §4.4, §5. `[judge]` allows `send_to`. With `backend = "jev"`: `send_to` must equal `api.typesafe.ai`, and `model`, when set, must be a versioned id, never `jev-latest` or `jev-preview`. Each failure is a `ConfigIssue` naming the key and the allowed value. `send_to` with `backend = "claude"` is an issue too, so the key never means nothing.
- Tests: `backend = "jev"` without `send_to` fails naming `judge.send_to` (catches silent egress). `model = "jev-latest"` fails naming the alias and the default pin. A valid `jev` table decodes to `.enabled(.jev, …, model: nil)` and the factory's identity is `jev/jev-1.13.0`. `api_key` in `[judge]` fails as an unknown key (catches a key in config).

### `calibrate-design-keeps-agent-replies`
- Deps: none · Gate: push · Model: opus · estLines: 200
- Writes: `A/Calibration/DesignCalibrationRunner.swift`, `C/Commands/CalibrateCommand.swift`, `TA/DesignCalibrationTests.swift`, `TC/CalibrateDesignCommandTests.swift`
- Does: design §10.1 step 2. Each agent reply goes to `.harness/runs/<run id>/calibrate-design/<agent>/<seed>.txt`, unmodified. `calibrate design --replay <run id>` skips the agents, reads the stored replies, and judges them. A replay never writes `last-pass.json`: it proves nothing about the agents.
- Tests: a run with a fake agent stores each reply byte for byte. `--replay` on that run calls no agent and gives the same answers as the live run with the same fake judge (catches a replay that re-runs agents). A replay with a missing reply exits BLOCKED naming the seed. A passing replay leaves `last-pass.json` unchanged.

### `blocking-questions-reach-thirty-person-labels`
- Deps: jev-blocks-only-when-calibrated · Gate: push · Model: opus · estLines: 200 · Needs: user (labelling)
- Writes: `J/cases/<neutral id>/` (new cases: `Test.swift.txt`, `Change.diff`), `J/labels.json`, `J/labelling-sheet.md` (the sheet the user filled in, kept as the record), `TD/JudgeLabelSetTests.swift`
- Does: design §7.4. A worker drafts at least 12 new candidate cases: real test functions and their production diffs from `examples/SampleApp` and this repo's history, and hollow variants of some. It writes no label and no intent anywhere the user sees. The orchestrator gives the user the sheet: every case, the existing 22 included, under a neutral number, with only the test and the diff. The user answers `fails-if-broken` (yes or no) and `asserts-implementation` (yes or no) for each, and may answer the other 2 questions. The worker records each answer as given, with `labeller: person`, and keeps a case the user skips out of the set. If a question has fewer than 10 on either side, the worker drafts more cases of the short kind, and the user labels those too.
- Tests: a test over the committed `J/labels.json` requires at least 30 `person` labels for each of `fails-if-broken` and `asserts-implementation`, with at least 10 on each side. It fails on today's file, which has 0. Every case directory named in `labels.json` exists, and every directory in `J/cases/` is in `labels.json` (catches an unlabelled case left behind). No new case directory name contains a word from the question text or a label value (catches a name that gives the intent away).

### `commit-comment-judge-runs-on-jev`
- Deps: jev-judge-answers-over-http · Gate: push · Model: opus · estLines: 120
- Writes: `C/Commands/JudgeCommands.swift` (`ConfiguredCommitCommentJudge.live`), `TC/HookCommandTests.swift` or `TC/JudgeCommandsTests.swift`
- Does: design §11.1 row 2. `live` builds `JevJudge` with the hook's 15 s timeout when the backend is `jev`, as it does for Claude, wrapped in the cache. The advisory text is unchanged.
- Tests: with a `jev` config and a fake transport replaying the captured `comments@1` reply, a staged comment gets the advisory text with `jev/jev-1.13.0` in it. A transport that stalls past 15 s returns `Comment judge not run` and the hook still answers (catches the hook waiting on the default 30 s timeout).

### `calibrate-design-judges-through-any-backend`
- Deps: calibrate-design-keeps-agent-replies, jev-judge-answers-over-http · Gate: push · Model: opus · estLines: 260
- Writes: `A/Calibration/DesignCalibrationRunner.swift` (`any Judge`), `A/Calibration/CalibrationRecord.swift` (`judge` identity, schema 3), `C/Commands/CalibrateCommand.swift` (`--judge-backend`, `--judge-model`), the freshness check's source and tests, `plugin/docs/standards.md` (`calibration-freshness.wrong-model` row)
- Does: design §10.3 second bullet. The runner takes `any Judge`; the default stays `ClaudeCLIJudge` on `JudgeFactory.defaultModel`. `last-pass.json` records `judge: {backend, model}`; a schema-2 record decodes with the default judge. `calibration-freshness.wrong-model` also fires on a record whose judge isn't the default, naming both.
- Tests: `--judge-backend jev --replay` with the fake transport answers every judged label (catches a runner still bound to Claude). A record judged by `jev` fails the push-tier freshness check naming the judge (catches a Jev pass standing in for the shipped one). A schema-2 record still passes. The index test passes with the edited row.

### `self-test-scores-each-backend-recording`
- Deps: jev-judge-answers-over-http, judges-report-usage · Gate: push · Model: opus · estLines: 320
- Writes: `C/Commands/JudgeCommands.swift` (`JudgeSelfTest`), `C/Commands/SelfTestCommand.swift` (`--judge-backend jev`), `D/Judge/JudgeCalibration.swift` (true-negative rate, threshold sweep, latency and cost summary), `TD/JudgeTests.swift`, `TC/JudgeCommandsTests.swift`, `plugin/docs/standards.md` (the `swiftgate.self-test` row)
- Does: design §10.1 metrics, §10.2, §10.3 first bullet. `self-test --judge` scores `recording.json` against `baseline.json` and, when present, `recording-<backend>.json` against `baseline-<backend>.json`. `--judge-backend <b> --record` writes the recording for `b`, with each subject's usage. The metrics note adds the true-negative rate, latency p50 and p95, cost per subject, and the lowest block threshold from 0.5 to 0.95 that keeps precision at the baseline. A recording whose model isn't its backend's default pin is `swiftgate.self-test.judge-stale` (major).
- Tests: a recording from `jev/jev-1.12.0` fails `judge-stale` naming both ids (catches a pin bump with an old recording). With only Claude's recording present, the output matches today's plus the new columns. The true-negative rate on a 2-case set with 1 false positive is 0.5 (catches TNR computed as recall). The sweep picks the lowest threshold meeting the baseline on a crafted distribution. The new id is in the index.

### `jev-blocks-carry-a-claude-reason`
- Deps: jev-blocks-only-when-calibrated, jev-judge-answers-over-http, self-test-scores-each-backend-recording · Gate: push · Model: opus · estLines: 240 · Needs: user (confirm the Claude-failure row in Decisions)
- Writes: `C/Commands/JudgeCommands.swift` (`TestJudgeCheck`), `C/JudgeBlockReason.swift`, `TC/CheckJudgeStepTests.swift`
- Does: design §6 point 2. After `JudgePolicy` returns, each major finding from a Jev identity triggers 1 `ClaudeCLIJudge` call with a question set holding only that question, for that subject, through the cache. Claude's rationale becomes `failureScenario`, and the message adds `claude p=<p>` beside Jev's. The finding stays major whatever Claude answers. If Claude can't answer, the finding stays major, and `failureScenario` says Claude's reason is missing and why (Decisions). Minor Jev findings call nothing.
- Tests: a calibrated Jev block with a fake Claude judge carries that judge's rationale and both probabilities (catches a block with no reason). A fake Claude answer that disagrees leaves the finding major (catches Claude overruling Jev). A minor Jev finding makes 0 Claude calls (catches a Claude call on every flag). A failing Claude judge leaves the finding major with the missing-reason text. A Claude-backend block makes no second call.

### `judge-ask-answers-any-question-set`
- Deps: jev-blocks-carry-a-claude-reason, config-pins-jev-and-names-its-host · Gate: push · Model: opus · estLines: 380
- Writes: `C/Commands/JudgeCommands.swift` (`judge` becomes a group, `tests` its default), `C/Commands/JudgeAskCommand.swift`, `D/Judge/JudgeAskInput.swift`, `TC/JudgeAskCommandTests.swift`, `TC/NewSubcommandRegistrationTests.swift`
- Does: design §8. Decode the input: a closed `kind` enum, unique ids, non-empty options, at most 10 Score levels and 255 Choice options. Build the backend from `[judge]` or `--backend` and `--model`, and apply §5's opt-in to `--backend jev`. Answer each subject through `JudgeBatch` with the cache unless `--no-cache`, and print the versioned JSON. No policy. Exit 0, 2 for bad input naming the field, 3 when the backend can't answer.
- Tests: `swiftgate judge --ready` still runs the test-quality check (catches a group that breaks the old spelling). An input with a duplicate question id exits 2 naming it. `--backend jev` in a repo without `send_to` exits 2 naming the key. A 2-subject input with a fake judge prints both subjects' distributions and usage under `schemaVersion` 1. A backend failure exits 3, never 0.

### `judge-backends-ab-on-labelled-sets`
- Deps: every task above except `playbook-documents-the-jev-backend` · Gate: push · Model: opus · estLines: 150 · Needs: user (key, spend)
- Writes: `J/recording-jev.json`, `J/baseline-jev.json`, `J/recording.json` (re-recorded with usage), `evals/results/<date>-judge-backend-ab/summary.md`, `evals/results/<date>-judge-backend-ab/summary.json`
- Does: design §10.1. Live, once per backend: `swiftgate self-test --judge --judge-backend claude --record`, then `--judge-backend jev --record`. Then `calibrate design` on shipped models to store replies, and `calibrate design --judge-backend jev --replay <run id>`. The summary reports, per backend and question, precision, recall, true-negative rate, latency p50 and p95, cost per subject, the threshold sweep, and every case where the backends disagree, with both probabilities. `baseline-jev.json` sets each minimum to what Jev reached, never above Claude's baseline, and the summary says which questions fall short of 0.8. It reports, per blocking question, whether `JudgeBlockCalibration` passes on the new recording at the template's `block_threshold`, and the reason when it doesn't. The recording it commits is what lets Jev block, so the orchestrator shows the user that table before merging.
- Tests: `self-test --judge` passes offline on both recordings. The summary's numbers equal what `self-test --judge --json` prints for each recording (catches a hand-edited summary).

### `playbook-documents-the-jev-backend`
- Deps: judge-ask-answers-any-question-set · Gate: push · Model: opus · estLines: 80
- Writes: `plugin/docs/testing-playbook.md` (§5.4)
- Does: replace the sentence saying `backend = "jev"` reports BLOCKED. Document `send_to`, `TYPESAFE_API_KEY`, the pin, when a Jev finding may block and the note it carries when it may not, the Claude reason on a block, `judge ask`, and the per-backend recordings. Thresholds for Jev point at the A/B summary once it exists; until then, the page says to run it first.
- Tests: `swiftgate prose` and `docs-lint` pass on the file. The file stays under its word budget in `.swiftgate.toml`.

## Later, not planned here

The design's §11.2 candidates wait for the A/B and for labelled sets of their own. They are the shared comment
audit question set, eval rubrics as 1 Noul per clause beyond the evals owners' first trial, and a Jev first pass for the design claim checker. So are
`design-lint.perf-missing-dimension` as 7 Nouls, and Noul filters on noisy minor rules.

## Tracked outside this plan

The sweep that fed this design found these bugs. Each has its own GitHub issue and a fix on its own branch, and no
task here touches them.

- `plugin/workflows/build-task.js`: `blocking` filters on severity alone and ignores `verified`, and it runs the
  verifier as a discovery reviewer, against the verifier's "Don't add new findings".
- `evals/runner/session.mjs` never reads the `focus:` field every `llm` rubric sets.
- `plugin/workflows/design-review.js` `reconcile` pairs verifications by position, while `plugin/workflows/review.js`
  `matchVerifications` pairs them by keys.
- `evals/components.md` (3 places) points at `gate/Fixtures/judge`, which lives at `plugin/gate/Fixtures/judge`.
- `plugin/docs/hooks.md`'s PreToolUse (Bash) row omits the commit comment judge, and
  `plugin/docs/testing-playbook.md` §5.4 calls it a pre-commit hook, though it runs in PreToolUse on `git commit`.
