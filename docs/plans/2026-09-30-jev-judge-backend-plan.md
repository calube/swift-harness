# Jev judge backend: implementation plan

<!-- RESUME
Status: waves 1 and 2 merged 2026-09-30, except blocking-questions-reach-thirty-person-labels, which waits for the user's labels. Design §13 (the Jev-native question set and the cascade) and its 5 tasks were added 2026-09-30 from the question design study; the user hasn't approved §13 yet. Next: wave 3 (commit-comment-judge-runs-on-jev, calibrate-design-judges-through-any-backend, judge-benchmark-datasets; and, once the user approves §13, jev-native-replies-are-captured, judge-parses-test-names-and-assertions, judge-cascade-decides-per-question). The key is in the login Keychain as TYPESAFE_API_KEY. Person labelling waits for the user.
Spec: docs/designs/2026-09-30-jev-judge-backend-design.md (approved 2026-09-30). Decision record: [ADR 0007](../adrs/0007-jev-is-an-opt-in-second-judge-backend.md).
Scope: a working `JevJudge` behind the judge seam; a Jev block only with a passing block calibration per question and pinned model, checked in code; a Claude-written reason on every blocking finding; a person-labelled set of 30 or more cases per blocking question; the commit comment judge and `calibrate design` on either backend; per-backend recordings and a freshness check; `swiftgate judge ask`; `swiftgate judge bench` and `bench-render`; a Jev-native `test-quality@2-jev` rendering and a cascade that sends Jev's uncertain or uncalibrated blocking answers to Claude (design §13); a benchmark of pinned Sonnet 5.5 against pinned Jev on `@1`, Jev on `@2-jev` and the cascade, with committed results; a person-labelled comment set. Out of scope: moving eval rubrics onto `judge ask` (the evals owners trial 1 rubric first), and the design's §11.2 later candidates.
Resume: read this header, then "Wave map", then your task's section (grep for the task id). Grep the spec by §.
Orchestrator procedure: docs/handoffs/subproject-2-orchestrator-runbook.md, with the changes in "How to work this plan". Interfaces note: docs/handoffs/jev-judge-interfaces.md (the first wave's merge creates it; each wave appends).
Build for correctness (user decision): every task is surface-first, on opus, through the push + prove merge gate, with mutate once on main per wave or per 2 waves.
Progress: git log. Update this header at every wave merge.
-->

## Decisions made while planning

The user decided the design's §12 questions on 2026-09-30; the rows marked "user" record those decisions, and
the 2 rows marked "user, 2026-09-30" record choices the user confirmed later that day. The other rows are the
plan's own choices within them.

| Decision | Evidence | Choice | Needs |
|---|---|---|---|
| Blocking (§12 decision 1) | §7 | Jev may block `ready` on its own for a question, only when `JudgeBlockCalibration` passes for that question id and the pinned model. Otherwise the finding is minor with a note. A new pin makes it stale | user |
| Reasons (§12 decision 3) | §6 | Template reason on advisory findings; a Claude-written reason on every blocking finding, a calibrated Jev block included | user |
| Eval runner (§12 decision 2) | §8 | `judge-ask-answers-any-question-set` builds `ask`. The evals owners trial it on 1 rubric split into 1 Noul per clause; no task here edits `evals/runner/` | user |
| Egress opt-in (§12 decision 4) | §5 | `send_to = "api.typesafe.ai"` required with `backend = "jev"`; the key from `TYPESAFE_API_KEY` | user |
| Tier criteria (§12 decision 5) | §4.1 | `test-quality@1` unchanged for the benchmark | user |
| Benchmark backends | user, 2026-09-30: compare Sonnet 5.5 at `claude-sonnet-5-5`, not the `sonnet` alias, with a pinned Jev | `--backend claude:claude-sonnet-5-5 --backend jev:jev-1.13.0`. The recordings in `J/` use the same pins. The gate's default `sonnet` doesn't change | user |
| The 22-case set can't rank | a live baseline on 2026-09-30: Sonnet 5.5 scored 1.00 on all 4 questions in 2 of 3 runs, and 7/8 on `name-specificity` in the third; positives per question are 5, 2, 8 and 3 | It stays as a smoke set. The labelling task builds a harder set: near misses, ambiguous tiers, at least 10 positives and 10 negatives per question in the report split | — |
| Tune and report splits | user: don't tune thresholds on the cases the benchmark reports | A case is in the tune split when the SHA-256 of its id starts below `0x55`, about 1 in 3; the rest report. Sweeps read tune only; headline metrics and the block calibration read report only. The labelled set grows to about 45 cases so the report split holds 30 per blocking question | user, 2026-09-30 |
| Intervals | user: show confidence intervals; n beside every number | Wilson 95% for proportions; a paired bootstrap over cases, 2,000 resamples, fixed seed, for Brier, calibration error, κ and differences | — |
| Benchmark requests | latency under queueing measures the queue | 1 request at a time by default; `--concurrency` exists but the committed run uses 1. The cache is off for every benchmark call | — |
| Where the block calibration lives | the user asked for "a calibration record … for that question id and Jev version"; a separate summary file could drift from, or be edited apart from, the recording it summarises | The record is the committed `J/recording-jev.json` scored against `J/labels.json`. Pure domain code computes pass or fail at every ready run; no summary file | — |
| The bar's numbers | evals design: 30 or more labelled cases, rates reported against a person's labels, and Jev kept only if its rates match Claude's; `J/baseline.json` sets 0.8 for every question | 30 person-labelled cases per question, at least 10 on each side; true-positive and true-negative rates of at least 0.8 and at least Claude's on the same cases, at the repository's `block_threshold`. Constants in the domain type, 1 test per number | — |
| Who labels | the sub-project 2 review: the tuning agent labelled today's 22 cases | A `labeller` field, `person` or `agent`, on each case; only `person` counts. A missing field reads as `agent` | — |
| Blind labelling | today's case directory names give the intent away (`existence-only`, `own-double`) | The labelling sheet shows neutral numbers, the test and the diff only. New case directories get neutral names | — |
| Claude can't write the reason | §6: no `claude` on `PATH`, a timeout, an error | The block stands with the template reason, and `failureScenario` names why Claude's reason is missing. | user, 2026-09-30 |
| Where the placeholder goes | `JevJudge` in `A/Judge.swift` throws `notConfigured`; `JudgeBackend.jev` already parses; `JudgeFactory.make` already switches on it | `jev-judge-answers-over-http` replaces the placeholder in place. No new backend case, no new config key for the backend | — |
| HTTP transport | the gate has no HTTP client; `curl` through `ProcessRunner` would put the key in an argument list | `HTTPTransport` protocol in `A/HTTP/`, a live type on `URLSession(configuration: .ephemeral)`, a replaying fake in `S/` | — |
| The pinned model | TypeSafe's models page (2026-09-30): `jev-latest` and `jev-preview` both resolve to `jev-1.13.0`; pinning a version is their advice for tuned thresholds | Default `jev-1.13.0`; an alias fails config. The capture task records the served id for `jev-latest` | — |
| The price | $0.042 per million input tokens for `jev-1.13.0`, output free (models page, 2026-09-30) | A constant beside the pin in `A/Judge/JevPin.swift`, with a test that fails when the captured served model differs from the pin, so a pin bump forces a look at the price | — |
| Usage without a protocol break | `FakeJudge`, `RecordedJudge`, `CachingJudge`, `DesignCalibrationRunner` and many tests call `answer` | `measuredAnswer` with a default in a protocol extension (design §4.5); only `ClaudeCLIJudge`, `JevJudge` and `CachingJudge` override it | — |
| Jev-native questions | design §13; the question design study (`evals/results/2026-09-30-jev-question-design/`): on its agent-labelled dev set, Jev `@2-jev` matched Claude on `fails-if-broken` and beat it on the other 2 | A Jev-only `test-quality@2-jev` with `basedOn: test-quality@1`, so labels and Claude's recording carry over. Claude keeps asking `@1` | user (approve §13) |
| The cascade | design §13.5 | Escalate a blocking question to Claude when Jev's combined p lies in the band, or when Jev's answer would block without a passing calibration. The escalated answer is Claude's. Band from the tune split | user (approve §13) |
| Score levels in `@1` | the study: bare level names in Score `criteria` give `name-specificity` recall 0.00 (0/12) | Send each level with its description; `@1` keeps its version, and the Jev cache key hashes the rendered questions. It needs a new capture, since the request bytes change | — |
| Benchmark spend | about 45 test-quality cases, up to 80 comments and the design seeds' judged labels, times 2 backends, times 3 repeats | The orchestrator reports the estimated cost before `judge-benchmark-sonnet-vs-jev` runs; the user approves it | user |

## How to work this plan

The runbook applies as written, with these changes:

- **Model.** Every worker on `opus`.
- **Surface first.** Each worker commits its new API as a behaviour-free surface commit, then tests and
  behaviour, and proves at it (worker brief pitfall 10), and runs `swiftgate surface-check <surface sha>` on it.
- **Merge gate.** Push + `prove --base main` on 1 integration worktree. With more than 1 surfaced branch in a wave,
  merge every surface commit first and prove at that merge. Mutate runs once on `main` after each wave, or once per
  2 waves when the first of the pair adds only doc text.
- **Id policy.** Task ids and wave numbers never appear in code, comments, test names or commit messages.
- **Labelling.** The user attends `blocking-questions-reach-thirty-person-labels` and `comment-judge-gains-a-labelled-set`: the user labels, and no agent
  writes or suggests a label. The orchestrator hands the user the sheet and commits the answers as given.
- **Network.** Only the 3 tasks marked `Needs: user (key)` call `api.typesafe.ai`, in the foreground, with the
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
| `A/Judge.swift` | `judges-report-usage`, then `jev-judge-answers-over-http`, then `jev-asks-the-native-test-quality-set` (wave 4). No wave 3 to 7 task lists it; one that needs it rebases on wave 4 |
| `D/Judge/Judge.swift` | `jev-blocks-only-when-calibrated`, then `jev-asks-the-native-test-quality-set` (`rendering`, `basedOn`, level descriptions, the cache key) |
| `D/Judge/JudgeBlockCalibration.swift` | `jev-blocks-only-when-calibrated`, then `jev-asks-the-native-test-quality-set` (`basedOn`) |
| `D/Judge/JudgeCascade.swift` | `judge-cascade-decides-per-question`, then `judge-benchmark-sonnet-vs-jev` (the band constants only) |
| `TA/JevJudgeTests.swift` | `jev-judge-answers-over-http`, then `jev-asks-the-native-test-quality-set` |
| `D/Config/Config.swift`, `D/Config/ConfigSchema.swift`, `D/Config/ConfigIssue.swift` | `jev-blocks-only-when-calibrated` (`JudgeBackend` only), then `config-pins-jev-and-names-its-host` |
| `C/Commands/JudgeCommands.swift` | `jev-blocks-only-when-calibrated`, then `commit-comment-judge-runs-on-jev`, then `self-test-scores-each-backend-recording`, then `jev-blocks-carry-a-claude-reason`, then `judge-ask-answers-any-question-set`, then `judge-bench-measures-backends`, then `ready-check-cascades-jev-to-claude` (1 per wave) |
| `C/Commands/JudgeBenchCommand.swift`, `D/Judge/Benchmark/JudgeBenchmarkReport.swift` | `judge-bench-measures-backends`, then `ready-check-cascades-jev-to-claude` |
| `D/Judge/JudgeCalibration.swift` | `jev-blocks-only-when-calibrated` (`labeller`), then `self-test-scores-each-backend-recording` |
| `plugin/gate/Fixtures/judge-comments/` | `comment-judge-gains-a-labelled-set` only |
| `A/Calibration/DesignCalibrationRunner.swift`, `C/Commands/CalibrateCommand.swift` | `calibrate-design-keeps-agent-replies`, then `calibrate-design-judges-through-any-backend` |
| `F/README.md` | `jev-replies-are-captured`, then `jev-native-replies-are-captured` |
| `C/JudgeBlockReason.swift`, `TC/CheckJudgeStepTests.swift` | `jev-blocks-only-when-calibrated` (the test file), then `jev-blocks-carry-a-claude-reason`, then `ready-check-cascades-jev-to-claude` (1 per wave) |
| `J/labels.json`, `J/cases/` | `blocking-questions-reach-thirty-person-labels` only |
| `J/recording*.json`, `J/baseline*.json`, `evals/results/<date>-judge-benchmark/` | `judge-benchmark-sonnet-vs-jev` only (recordings, baselines and results come from its live run) |
| `plugin/docs/standards.md` rule id index | `self-test-scores-each-backend-recording` ("Harness and environment", 1 new id), then `calibrate-design-judges-through-any-backend` (the `calibration-freshness.wrong-model` row's text) |
| `plugin/docs/testing-playbook.md` §5.4 | `playbook-documents-the-jev-backend` only. The hook-name fix tracked outside this plan edits the same section: whichever merges second rebases |

### Rule id index rows

1 new id: `swiftgate.self-test.judge-stale`, added to the `swiftgate.self-test` row under "Harness and
environment" by the task that adds the check. The `calibration-freshness.wrong-model` row gains the judge case
in the task that extends it. `judge.*` ids don't change: a Jev finding reuses them, blocking or downgraded, and a
Jev failure is `judge.not-run`. A new `ConfigIssue` reports under `swiftgate.config`, which the index already lists. Each task's
tests include the existing index test, which fails when an id the registries report has no row.

### Risks

- **Access.** TypeSafe's API sits behind an early-access list. Without a key, the live tasks in waves 1, 3 and 9 wait;
  the other tasks run on captured fixtures once wave 1 lands them.
- **Rate limits.** TypeSafe says its limits change without notice. The adapter retries 429 and 529 inside its
  timeout; the benchmark sends 1 request at a time, well under 40 per second.
- **Prompt injection.** Jev doesn't treat state as hostile by default, and a test's comments can argue for their
  own verdict. The benchmark page lists every case where the backends disagree, so a person can read them.
- **Labelling time.** 30 person labels per blocking question, 10 on each side, means relabelling the 22 cases
  and adding at least 8 more. Until that task merges, every Jev finding stays advisory, which the code already
  handles; only the benchmark waits on it.
- **Standards index churn.** 2 tasks edit rows in different waves.

## Wave map

| Wave | Tasks | Why |
|---|---|---|
| 1 | `jev-replies-are-captured`, `judges-report-usage`, `jev-blocks-only-when-calibrated` | independent foundations: real replies, usage on the protocol, and the block guard before any Jev answer exists |
| 2 | `jev-judge-answers-over-http`, `config-pins-jev-and-names-its-host`, `calibrate-design-keeps-agent-replies`, `blocking-questions-reach-thirty-person-labels`, `judge-benchmark-metrics` | the adapter needs the captures and usage; config waits for `JudgeBackend`'s wave-1 edit; the labels need `labeller` and the split; metrics need `JudgeUsage` |
| 3 | `commit-comment-judge-runs-on-jev`, `calibrate-design-judges-through-any-backend`, `judge-benchmark-datasets`, `jev-native-replies-are-captured`, `judge-parses-test-names-and-assertions`, `judge-cascade-decides-per-question` | the first 2 call the adapter; datasets need stored replies and the split; the last 3 need only merged work and write new files (the capture also appends to `F/README.md`); disjoint files |
| 4 | `self-test-scores-each-backend-recording`, `comment-judge-gains-a-labelled-set`, `jev-asks-the-native-test-quality-set` | self-test reuses the benchmark metrics and takes `JudgeCommands.swift`; the comment set uses the dataset format; the `@2-jev` rendering needs the parser and the captures, and takes `A/Judge.swift` and `D/Judge/Judge.swift`, which no other wave 4 task writes |
| 5 | `jev-blocks-carry-a-claude-reason` | needs the block guard and the adapter; takes `JudgeCommands.swift` this wave |
| 6 | `judge-ask-answers-any-question-set` | makes `judge` a group |
| 7 | `judge-bench-measures-backends` | adds `bench` and `bench-render` to the group |
| 8 | `ready-check-cascades-jev-to-claude` | needs the `@2-jev` rendering, the cascade policy, the Claude reason and the bench command; takes `JudgeCommands.swift` and `JudgeBenchCommand.swift` this wave |
| 9 | `judge-benchmark-sonnet-vs-jev`, `playbook-documents-the-jev-backend` | the live run needs every path above, the cascade arm and the person labels; the docs state its results |

### `jev-replies-are-captured`
- Deps: none · Gate: push · Model: opus · estLines: 120 · Needs: user (key)
- Writes: `F/Judge/jev-request-test-quality.json`, `F/Judge/jev-request-comments.json`, `F/Judge/jev-request-invalid.json`, `F/Judge/jev-request-alias.json` (request inputs), `F/Judge/jev-*.reply.json` and `F/Judge/jev-*.status` (captured), `F/README.md` (a "Jev" section)
- Does: design §14 first bullet. Build each request from a real subject: the `counter-increment` and `own-double` cases in `J/cases/` for `test-quality@1` (all 3 Jev types), and 1 staged comment from this repo's history for `comments@1`. Send each with `curl -sS -o <name>.reply.json -w '%{http_code}\n' -H @<(printf 'Authorization: Bearer %s\n' "$TYPESAFE_API_KEY") -H 'Content-Type: application/json' --data-binary @<request> https://api.typesafe.ai/v1/systemone > <name>.status`. Capture a 401 with the key replaced by `invalid`, a 422 from a Choice question with no `criteria`, and `jev-latest` for the served id. Record each command, the date, and the served model for every reply. The README section also notes: question keys with hyphens round-trip, the Score `legend` and `probabilities` key shape, and that no reply carries a reason.
- Tests: none of its own (fixture task). The next wave's tests consume every file; a file no test reads fails that wave's review.

### `judges-report-usage`
- Deps: none · Gate: push · Model: opus · estLines: 240
- Writes: `D/Judge/JudgeUsage.swift`, `A/Judge.swift` (`measuredAnswer` on `Judge` with a default; `ClaudeCLIJudge` and `CachingJudge` overrides; `ClaudeJudgeReply` reads the envelope's usage keys), `TA/JudgeAdaptersTests.swift`
- Does: design §4.5. `JudgeReply {answers, usage: JudgeUsage?}`; `JudgeUsage {inputTokens?, outputTokens?, costUSD?, wallMilliseconds, backendMilliseconds?, servedModel?, cached}`. Claude fills them from `total_cost_usd`, `duration_ms`, `duration_api_ms`, `usage` and the single key of `modelUsage`. The default `measuredAnswer` wraps `answer` with no usage and measures wall time. `CachingJudge` returns a hit with `cached: true` and 0 cost, and passes a miss's usage through.
- Tests: the captured `Judge/claude-result.json` yields its cost, both durations, its token counts and its served model (catches usage read from the wrong keys). An envelope whose `modelUsage` has 2 keys fails naming both, since 1 answer can't come from 2 models. A cache hit reports `cached` and 0 cost, and a miss reports the inner judge's usage (catches a cache that bills twice or hides a live call). `FakeJudge`'s default usage has no tokens or cost, and existing judge tests pass unchanged.

### `jev-blocks-only-when-calibrated`
- Deps: none · Gate: push · Model: opus · estLines: 420
- Writes: `D/Judge/JudgeBlockCalibration.swift`, `D/Judge/JudgeCalibration.swift` (`labeller` on each case), `D/Judge/Judge.swift` (`JudgePolicy` takes a block decision per question), `D/Config/Config.swift` (`JudgeBackend.needsBlockCalibration`), `A/Judge/JudgeCalibrationFiles.swift` (reads `labels.json` and the per-backend recordings under the harness root; names `recording-<backend>.json`), `C/Commands/JudgeCommands.swift` (`TestJudgeCheck` wiring), `TD/JudgeBlockCalibrationTests.swift`, `TD/JudgeTests.swift`, `TC/CheckJudgeStepTests.swift`
- Does: design §7.1-7.3, §10.5 (the split). `JudgeCaseSplit.of(caseID)` is pure: tune when the SHA-256 of the id starts below `0x55`, else report. `JudgeBlockCalibration.evaluate(question:model:blockThreshold:set:jev:claude:)` is pure and returns `.passes(rates)` or `.fails(reason)`. It checks, in order: a Jev recording exists; it answers the check's question set version; its model equals the pin. Then: at least 30 `person` labels for the question in the report split, at least 10 on each side. Tune-split cases never count. Last: true-positive and true-negative rates at `blockThreshold` of at least 0.8 and at least Claude's on the same cases. `JudgeBackend.needsBlockCalibration` is `false` for `claude` and `true` for `jev`. For a Jev identity, `TestJudgeCheck` loads the files from `SWIFTGATE_HARNESS_ROOT` and passes each question's decision to `JudgePolicy`. A failed decision keeps the finding minor with `advisory: jev has no passing block calibration for <question> on <model>: <reason>`. A missing root or file is a failed decision, never a crash and never a block. The labels file decodes today's cases, which have no `labeller`, as `agent`.
- Tests, each written to fail before the code exists: a Jev answer at p=0.99 on `fails-if-broken` at `ready` with no recording is minor and names `no recording` (catches a Jev block with no calibration). A recording from `jev-1.12.0` with a `jev-1.13.0` pin is minor and names both models (catches a stale calibration that still blocks). 29 `person` labels is minor naming `29 of 30`; 30 labels with 9 on 1 side is minor. 30 `agent` labels is minor (catches the tuning agent's labels counting). 30 passing `person` labels where 1 sits in the tune split is minor naming `29 of 30` (catches a calibration read from cases someone tuned a threshold on). A true-negative rate of 0.79 is minor; rates of 0.8 below Claude's are minor. A passing calibration for `asserts-implementation` leaves `fails-if-broken` minor (catches a calibration read per backend, not per question). A passing calibration for `fails-if-broken` at `jev-1.13.0` makes it major and `ready` RED. Raising `block_threshold` from 0.8 to 0.95 on the same recording can turn a pass into a fail (catches rates computed at a fixed 0.5). The same answer from a `claude` identity is major with no calibration files at all (catches a change to today's Claude behaviour).

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
- Does: design §10.2 row 3. Each agent reply goes to `.harness/runs/<run id>/calibrate-design/<agent>/<seed>.txt`, unmodified. `calibrate design --replay <run id>` skips the agents, reads the stored replies, and judges them. A replay never writes `last-pass.json`: it proves nothing about the agents.
- Tests: a run with a fake agent stores each reply byte for byte. `--replay` on that run calls no agent and gives the same answers as the live run with the same fake judge (catches a replay that re-runs agents). A replay with a missing reply exits BLOCKED naming the seed. A passing replay leaves `last-pass.json` unchanged.

### `blocking-questions-reach-thirty-person-labels`
- Deps: jev-blocks-only-when-calibrated · Gate: push · Model: opus · estLines: 260 · Needs: user (labelling)
- Writes: `J/cases/<neutral id>/` (new cases: `Test.swift.txt`, `Change.diff`), `J/labels.json`, `J/labelling-sheet.md` (the sheet the user filled in, kept as the record), `TD/JudgeLabelSetTests.swift`
- Does: design §7.4 and §10.3. A worker drafts at least 25 new candidate cases for the harder set. They are real test functions and their production diffs from `examples/SampleApp` and this repo's history, and near misses: a true assertion that misses the named behaviour, 1 mock too many, an assertion on a value the test built. Some sit on the host-logic and rendering boundary, for `tier`. Some assert a spy's record that is the feature's output: a saved draft, a scheduled notification, a sent request (design §13.6, the open false-positive pattern). It writes no label and no intent anywhere the user sees. The orchestrator gives the user the sheet: every case, the existing 22 included, under a neutral number, with only the test and the diff. The user answers all 4 questions for each case and may skip any. The worker records each answer as given, with `labeller: person`. If a question has fewer than 10 on either side in the report split, the worker drafts more cases of the short kind, and the user labels those too.
- Tests: a test over the committed `J/labels.json` requires, in the report split, at least 30 `person` labels for each of `fails-if-broken` and `asserts-implementation`, and at least 10 on each side for every question. It fails on today's file, which has 0. Every case directory named in `labels.json` exists, and every directory in `J/cases/` is in `labels.json` (catches an unlabelled case left behind). No new case directory name contains a word from the question text or a label value (catches a name that gives the intent away).

### `judge-benchmark-metrics`
- Deps: judges-report-usage · Gate: push · Model: opus · estLines: 420
- Writes: `D/Judge/Benchmark/JudgeBenchmarkMetrics.swift`, `D/Judge/Benchmark/JudgeIntervals.swift`, `TD/JudgeBenchmarkMetricsTests.swift`
- Does: design §10.4-10.5, pure domain. Inputs: labels, per-repeat distributions and usage. Per question and backend it computes counts, precision, recall, true-negative rate, accuracy, Brier score, 10 reliability bins and the expected calibration error. It also computes the flip share and mean standard deviation over repeats, Cohen's κ between 2 backends, latency p50 and p95 per request and per case, and tokens and cost per case and per 1,000 judgments. Wilson 95% intervals; a paired bootstrap with a seeded generator, 2,000 resamples. Every value carries its n. A threshold sweep takes tune-split cases only, by type: it can't receive report cases.
- Tests, on small inputs worked by hand: Brier for 2 cases with known distributions, and Wilson for 10/11 at 0.62 to 0.98. Also κ for 2 known decision lists, a flip share of 1/3 over 3 repeats, and a bin table where an empty bin reports n 0, not a rate. The same seed gives the same bootstrap interval twice, and another seed a different one (catches an unseeded bootstrap). A rate with n 0 is `nil`, never 0 or 1.

### `judge-benchmark-datasets`
- Deps: calibrate-design-keeps-agent-replies, jev-blocks-only-when-calibrated · Gate: push · Model: opus · estLines: 320
- Writes: `D/Judge/Benchmark/JudgeDataset.swift`, `A/Judge/JudgeDatasetLoader.swift`, `TD/JudgeDatasetTests.swift`, `TA/JudgeDatasetLoaderTests.swift`
- Does: design §10.2. 1 dataset shape: a question set (inline, or the versioned id of a built-in set), and cases with `id`, `source`, `context`, optional `declaredTier`, per-question `labels` and `labeller`. The hash is SHA-256 over the canonical JSON, labels included. Loaders: the built-in test-quality directory `J/`; a directory in the same layout, such as `plugin/gate/Fixtures/judge-comments/`; a `calibrate design` run's stored replies, labelled by each seed's expected option with `labeller: seed`; and a plain dataset JSON file, for the evals owners' rubric. Each case gets its split from `JudgeCaseSplit`.
- Tests: `J/` loads 22 cases with today's labels and `labeller: agent`. Changing 1 label changes the hash (catches a hash over sources only). A stored-replies run with a missing reply fails naming the seed. A dataset JSON with an option its question lacks fails naming both. The split of each case matches `JudgeCaseSplit`.

### `commit-comment-judge-runs-on-jev`
- Deps: jev-judge-answers-over-http · Gate: push · Model: opus · estLines: 120
- Writes: `C/Commands/JudgeCommands.swift` (`ConfiguredCommitCommentJudge.live`), `TC/HookCommandTests.swift` or `TC/JudgeCommandsTests.swift`
- Does: design §11.1 row 2. `live` builds `JevJudge` with the hook's 15 s timeout when the backend is `jev`, as it does for Claude, wrapped in the cache. The advisory text is unchanged.
- Tests: with a `jev` config and a fake transport replaying the captured `comments@1` reply, a staged comment gets the advisory text with `jev/jev-1.13.0` in it. A transport that stalls past 15 s returns `Comment judge not run` and the hook still answers (catches the hook waiting on the default 30 s timeout).

### `calibrate-design-judges-through-any-backend`
- Deps: calibrate-design-keeps-agent-replies, jev-judge-answers-over-http · Gate: push · Model: opus · estLines: 260
- Writes: `A/Calibration/DesignCalibrationRunner.swift` (`any Judge`), `A/Calibration/CalibrationRecord.swift` (`judge` identity, schema 3), `C/Commands/CalibrateCommand.swift` (`--judge-backend`, `--judge-model`), the freshness check's source and tests, `plugin/docs/standards.md` (`calibration-freshness.wrong-model` row)
- Does: design §10.8 second bullet. The runner takes `any Judge`; the default stays `ClaudeCLIJudge` on `JudgeFactory.defaultModel`. `last-pass.json` records `judge: {backend, model}`; a schema-2 record decodes with the default judge. `calibration-freshness.wrong-model` also fires on a record whose judge isn't the default, naming both.
- Tests: `--judge-backend jev --replay` with the fake transport answers every judged label (catches a runner still bound to Claude). A record judged by `jev` fails the push-tier freshness check naming the judge (catches a Jev pass standing in for the shipped one). A schema-2 record still passes. The index test passes with the edited row.

### `jev-native-replies-are-captured`
- Deps: none · Gate: push · Model: opus · estLines: 120 · Needs: user (key)
- Writes: `F/Judge/jev-request-test-quality-2-jev-good.json`, `F/Judge/jev-request-test-quality-2-jev-useless.json`, `F/Judge/jev-request-test-quality-levels.json` (request inputs), their `.reply.json` and `.status` (captured), `F/README.md` (the "Jev" section gains the new captures)
- Does: design §13.2 to §13.4. Build 2 `test-quality@2-jev` requests, from the `counter-increment` and `own-double` cases in `J/cases/`, so each combination rule sees a test that should pass and one that should fail. Each holds the §13.2 state, with `test_name` and `assertions` derived by the §13.2 rules, and the §13.3 sub-questions verbatim, keyed `<question id>.<sub-question id>`, plus `tier` as in `@1`. Build 1 `test-quality@1` request for `counter-increment` whose `name-specificity` Score sends each level with its description (§13.4). Send each with the `curl` command `jev-replies-are-captured` recorded, and record the command, the date and the served model for every reply. The README notes whether a Score `legend` echoes the described levels, and that dotted question keys round-trip.
- Tests: none of its own (fixture task). `jev-asks-the-native-test-quality-set` consumes every file; a file no test reads fails that wave's review.

### `judge-parses-test-names-and-assertions`
- Deps: none · Gate: push · Model: opus · estLines: 220
- Writes: `D/Judge/JudgeTestSubjectParts.swift`, `TD/JudgeTestSubjectPartsTests.swift`
- Does: design §13.2, pure domain, no Foundation IO and no SwiftSyntax. `JudgeTestName.parse(source:)` returns `{full, behavior, catches?}`: `full` is the first `@Test("…")` display string, unescaped, else the first `func` name. `behavior` is the text before ` — catches `, ` – catches ` or ` - catches `, else `full`. `catches` is `catches ` plus the text after it, else `nil`. `JudgeAssertions.extract(source:)` returns, in source order, each `#expect`, `#require`, `XCTAssert*` and `XCTUnwrap` statement, with `try` kept, and each `await store.send` or `await store.receive` call. A call whose trailing closure spans lines becomes 1 line, its lines trimmed and joined by a space, up to the brace that balances it.
- Tests, each written to fail before the code exists: `"total is $5 — catches shoppers billed twice"` gives behavior `total is $5` and catches `catches shoppers billed twice`, and the same holds with an en dash and a hyphen (catches a split on 1 dash only). A name with no `catches` part gives `catches` `nil` and `behavior` equal to `full`. A test with no display string gives the func name. A display string holding `\"` unescapes it. A `store.receive` whose closure spans 3 lines and holds a nested `{ }` becomes 1 entry ending at the balancing brace (catches a join that stops at the first `}`). `try #require(x)` keeps `try`. A source with no assertion gives `[]`. Every `Test.swift.txt` in `J/cases/` parses to a non-empty `full` (catches a parser that only handles the hand-written inputs).

### `judge-cascade-decides-per-question`
- Deps: jev-blocks-only-when-calibrated · Gate: push · Model: opus · estLines: 300
- Writes: `D/Judge/JudgeCascade.swift`, `TD/JudgeCascadeTests.swift`
- Does: design §13.5, pure domain. `JudgeCascade.Band {lower, upper}` is open at both ends; the bands for `test-quality@2-jev` are constants keyed by versioned set and question id: 0.2 to 0.8 for `fails-if-broken` and `asserts-implementation`, none for the advisory questions. `JudgeCascade.plan(jev:questions:blockDecisions:thresholds:atReadyTier:)` returns per question `.keep` or `.escalate(.uncertain | .uncalibratedBlock)`. `JudgeCascade.findings(plan:jev:claude:jevIdentity:claudeIdentity:…)` runs `JudgePolicy` once over the kept Jev answers with their block decisions, and once over the escalated Claude answers with `.standing` authority. An escalated question with no Claude answer keeps Jev's, minor, with a note naming why.
- Tests, each written to fail before the code exists: a Jev p of 0.5 on `fails-if-broken` escalates as uncertain; 0.2 and 0.8 keep (catches a closed band). 0.5 on `name-specificity` keeps (catches escalating advisory questions). 0.95 with `block_threshold` 0.9 and a failing block decision escalates as `uncalibratedBlock`; with a passing decision it keeps and is major. An escalated Claude answer of 0.95 is major under Claude's identity with no block decisions at all (catches an escalated answer judged under Jev's calibration). An escalated Claude answer of 0.1 gives no finding though Jev said 0.7 (catches Jev's answer surviving escalation). A missing Claude answer for an `uncalibratedBlock` question at 0.95 is minor with the §7.2 note and the escalation note, never major.

### `self-test-scores-each-backend-recording`
- Deps: jev-judge-answers-over-http, judges-report-usage, judge-benchmark-metrics · Gate: push · Model: opus · estLines: 320
- Writes: `C/Commands/JudgeCommands.swift` (`JudgeSelfTest`), `C/Commands/SelfTestCommand.swift` (`--judge-backend jev`), `D/Judge/JudgeCalibration.swift` (calls the benchmark metrics for the true-negative rate, the sweep, latency and cost), `TD/JudgeTests.swift`, `TC/JudgeCommandsTests.swift`, `plugin/docs/standards.md` (the `swiftgate.self-test` row)
- Does: design §10.7, §10.8 first bullet. The metrics come from `JudgeBenchmarkMetrics`, so self-test and the benchmark share 1 definition. `--model` defaults to the chosen backend's default (`sonnet` for Claude, the pin for Jev), not to Claude's for every backend. `self-test --judge` scores `recording.json` against `baseline.json` and, when present, `recording-<backend>.json` against `baseline-<backend>.json`. `--judge-backend <b> --record` writes the recording for `b`, with each subject's usage. The metrics note adds the true-negative rate, latency p50 and p95, cost per subject, and the lowest block threshold from 0.5 to 0.95 that keeps precision at the baseline, on the tune split only. A recording whose model isn't its backend's default pin is `swiftgate.self-test.judge-stale` (major).
- Tests: a recording from `jev/jev-1.12.0` fails `judge-stale` naming both ids (catches a pin bump with an old recording). With only Claude's recording present, the output matches today's plus the new columns. The true-negative rate on a 2-case set with 1 false positive is 0.5 (catches TNR computed as recall). `--judge-backend jev` with no `--model` asks for `jev-1.13.0`, never `sonnet`. The sweep picks the lowest threshold meeting the baseline on a crafted distribution. The new id is in the index.

### `comment-judge-gains-a-labelled-set`
- Deps: judge-benchmark-datasets · Gate: push · Model: opus · estLines: 160 · Needs: user (labelling)
- Writes: `plugin/gate/Fixtures/judge-comments/` (cases, `labels.json`, `labelling-sheet.md`), `TD/JudgeCommentSetTests.swift`
- Does: design §10.2 row 2. A worker collects comments that commits added to Swift files, from this repo's history and `examples/SampleApp`, with the 6 lines after each: up to 80, half on lines a `comments.*` rule flags and half on lines none flags. The worker records each case's commit and path in the sheet's source column only. The user labels `loses-fact` and `right-size` blind, under neutral numbers. The worker records the answers as given, with `labeller: person`.
- Tests: the dataset loads through the loader, and each question has at least 30 `person` labels in the report split with at least 10 on each side; it fails before the labels exist. Every case's text appears in its named commit (catches an edited or made-up comment).

### `jev-asks-the-native-test-quality-set`
- Deps: judge-parses-test-names-and-assertions, jev-native-replies-are-captured, jev-judge-answers-over-http · Gate: push · Model: opus · estLines: 460
- Writes: `D/Judge/Judge.swift` (the set's `rendering` and `basedOn`, level descriptions, the cache key), `D/Judge/JevRendering.swift` (sub-questions and combination rules as data), `D/Judge/JudgeBlockCalibration.swift` (`basedOn`), `A/Judge.swift` (`JevRequest`, `JevJudge`), `TD/JevRenderingTests.swift`, `TD/JudgeBlockCalibrationTests.swift`, `TA/JevJudgeTests.swift`
- Does: design §13.1 to §13.4. `test-quality@2-jev` holds `@1`'s 4 questions unchanged, `rendering: jev` and `basedOn: test-quality@1`. `JevRendering` holds §13.3's sub-questions verbatim and 1 combination rule per question. `JevRequest` builds the §13.2 state through the domain parser and asks every sub-question in 1 request. `JevJudge` decodes each sub-answer and applies the rule, so callers see the 4 questions' distributions only. The `@1` `name-specificity` question gains level descriptions taken from its text, and the adapter sends them as Score `criteria` and checks `legend` against them. `JudgeBlockCalibration` accepts labels and a Claude recording for a set's `basedOn` version. The Jev cache key adds a hash of the rendered questions. The test-quality check doesn't switch sets here; `ready-check-cascades-jev-to-claude` does.
- Tests, each written to fail before the code exists: each built request for a captured case equals the captured request byte for byte after key sorting (catches drift between the parser, the rendering and the wire). The captured `@2-jev` replies decode, and `fails-if-broken` equals the rule applied to the captured sub-answers. `runs-changed-code` 0.9 with `checks-named-result` 0.1 gives `p_no` 0.9 (catches an AND for an OR). A Choice answer of `symptom` maps to `specific` (catches a level swap). Every `@2-jev` question equals its `@1` twin field by field (catches a changed question hiding behind `basedOn`). A Jev recording of `@2-jev` with `@1` labels and Claude's `@1` recording can pass, and a Jev recording of `@1` fails a `@2-jev` calibration naming both ids. The captured levels request equals the built `@1` request, and Claude's `@1` prompt is byte for byte unchanged (catches descriptions leaking into Claude's prompt). 2 renderings of the same version give different cache keys (catches stale answers after a rendering change).

### `jev-blocks-carry-a-claude-reason`
- Deps: jev-blocks-only-when-calibrated, jev-judge-answers-over-http, self-test-scores-each-backend-recording · Gate: push · Model: opus · estLines: 240
- Writes: `C/Commands/JudgeCommands.swift` (`TestJudgeCheck`), `C/JudgeBlockReason.swift`, `TC/CheckJudgeStepTests.swift`
- Does: design §6 point 2. After `JudgePolicy` returns, each major finding from a Jev identity triggers 1 `ClaudeCLIJudge` call with a question set holding only that question, for that subject, through the cache. Claude's rationale becomes `failureScenario`, and the message adds `claude p=<p>` beside Jev's. The finding stays major whatever Claude answers. If Claude can't answer, the finding stays major, and `failureScenario` says Claude's reason is missing and why (Decisions). Minor Jev findings call nothing.
- Tests: a calibrated Jev block with a fake Claude judge carries that judge's rationale and both probabilities (catches a block with no reason). A fake Claude answer that disagrees leaves the finding major (catches Claude overruling Jev). A minor Jev finding makes 0 Claude calls (catches a Claude call on every flag). A failing Claude judge leaves the finding major with the missing-reason text. A Claude-backend block makes no second call.

### `judge-ask-answers-any-question-set`
- Deps: jev-blocks-carry-a-claude-reason, config-pins-jev-and-names-its-host · Gate: push · Model: opus · estLines: 380
- Writes: `C/Commands/JudgeCommands.swift` (`judge` becomes a group, `tests` its default), `C/Commands/JudgeAskCommand.swift`, `D/Judge/JudgeAskInput.swift`, `TC/JudgeAskCommandTests.swift`, `TC/NewSubcommandRegistrationTests.swift`
- Does: design §8. Decode the input: a closed `kind` enum, unique ids, non-empty options, at most 10 Score levels and 255 Choice options. Build the backend from `[judge]` or `--backend` and `--model`, and apply §5's opt-in to `--backend jev`. Answer each subject through `JudgeBatch` with the cache unless `--no-cache`, and print the versioned JSON. No policy. Exit 0, 2 for bad input naming the field, 3 when the backend can't answer.
- Tests: `swiftgate judge --ready` still runs the test-quality check (catches a group that breaks the old spelling). An input with a duplicate question id exits 2 naming it. `--backend jev` in a repo without `send_to` exits 2 naming the key. A 2-subject input with a fake judge prints both subjects' distributions and usage under `schemaVersion` 1. A backend failure exits 3, never 0.

### `judge-bench-measures-backends`
- Deps: judge-ask-answers-any-question-set, judge-benchmark-metrics, judge-benchmark-datasets · Gate: push · Model: opus · estLines: 440
- Writes: `C/Commands/JudgeCommands.swift` (registers `bench` and `bench-render` in the group), `C/Commands/JudgeBenchCommand.swift`, `D/Judge/Benchmark/JudgeBenchmarkReport.swift` (the versioned JSON and the markdown renderer), `TC/JudgeBenchCommandTests.swift`, `TD/JudgeBenchmarkReportTests.swift`, `TC/NewSubcommandRegistrationTests.swift`
- Does: design §10.6. `judge bench --dataset <path|id> --backend <backend:model> ... [--repeats 3] [--concurrency 1] --out <file>` loads the dataset and builds each backend at its pinned model with no cache. It answers every case k times through `measuredAnswer` and writes the JSON. The JSON holds `schemaVersion`, the `swiftgate` version, start time, dataset id, hash, split counts and labeller mix. Per backend it holds the identity with requested and served model, the raw answers and usage per repeat and per case, and the metrics. A served model that changes mid-run fails the run, exit 3. `--repeats` below 3 exits 2. `judge bench-render <file>` recomputes the metrics and exits 1 when they differ from the stored ones. It prints the page: per question, both backends side by side, each number with its n and interval, and the reliability bins. It adds the sentence §10.5 asks for when a difference's interval crosses 0, and every disagreement with both probabilities.
- Tests: with 2 fake judges and a 4-case dataset, the JSON holds 3 repeats × 4 cases × 2 backends of raw answers and decodes with an unknown key rejected. No cache file appears (catches repeats served from the cache). A fake whose served model changes on repeat 2 exits 3. Editing 1 stored metric makes `bench-render` exit 1 (catches a hand-edited result). The rendered page shows `(n=…)` beside every rate. `--repeats 2` exits 2.

### `ready-check-cascades-jev-to-claude`
- Deps: jev-asks-the-native-test-quality-set, judge-cascade-decides-per-question, jev-blocks-carry-a-claude-reason, self-test-scores-each-backend-recording, judge-bench-measures-backends · Gate: push · Model: opus · estLines: 420
- Writes: `A/Judge/CascadingJudge.swift`, `C/Commands/JudgeCommands.swift` (`TestJudgeCheck`, `JudgeSelfTest`), `C/JudgeBlockReason.swift`, `C/Commands/JudgeBenchCommand.swift` (set per backend, cascade backend), `D/Judge/Benchmark/JudgeBenchmarkReport.swift` (escalation share, summed usage), `TA/CascadingJudgeTests.swift`, `TC/CheckJudgeStepTests.swift`, `TC/JudgeBenchCommandTests.swift`
- Does: design §13.5 wiring. `CascadingJudge` takes a `JevJudge` and a `ClaudeCLIJudge`, each behind `CachingJudge`, asks Jev, asks Claude once per subject for every escalated question with the `@1` text, and returns the merged answers with the identity that decided each. With `[judge] backend = "jev"`, `TestJudgeCheck` asks `@2-jev` through it and reports each finding under the identity that decided it. An escalated block keeps Claude's rationale and makes no §6 call. `self-test --judge-backend jev --record` records `@2-jev`. `judge bench` gains `--backend jev:<model>#<set version>` and `--backend cascade:<jev model>,<claude model>`. A `@2-jev` or cascade arm scores against `@1` labels through `basedOn`. The cascade arm records per case which questions escalated, and its usage sums both backends.
- Tests, each written to fail before the code exists: take a `jev` config, a fake Jev at `p_no` 0.5 and a fake Claude at 0.95. `ready` is RED under `claude/<model>` with Claude's rationale, after 1 Claude call and no more (catches a second reason call). A fake Jev at 0.1 makes 0 Claude calls (catches escalating everything). A fake Jev at 0.95 with no calibration and a fake Claude at 0.1 gives no finding. With a passing calibration it is major, with 1 Claude call for the reason. A failing Claude leaves every Jev answer minor and `ready` not RED. `name-specificity` at 0.5 makes 0 Claude calls. A cascade arm's cost per case sums Jev's and Claude's (catches cost counted on 1 backend). An unknown set version after `#` exits 2 naming it.

### `judge-benchmark-sonnet-vs-jev`
- Deps: every task above except `playbook-documents-the-jev-backend` · Gate: push · Model: opus · estLines: 180 · Needs: user (key, spend)
- Writes: `J/recording.json` (at `claude-sonnet-5-5`, with usage), `J/recording-jev.json` (`test-quality@2-jev`), `J/baseline-jev.json`, `D/Judge/JudgeCascade.swift` (the band constants only), `evals/results/<date>-judge-benchmark/` (1 benchmark JSON per dataset and the rendered `summary.md`)
- Does: design §10 and §13. Live, with the user's approval of the spend. On dataset 1 (the 22-case smoke set and the harder person-labelled set), run 4 arms with `--repeats 3`: Claude on `@1` (`claude:claude-sonnet-5-5`), Jev on `@1` with the level descriptions (`jev:jev-1.13.0`), Jev on `@2-jev` (`jev:jev-1.13.0#test-quality@2-jev`) and the cascade (`cascade:jev-1.13.0,claude-sonnet-5-5`). Run Claude and Jev `@1` on dataset 2 (comments) and dataset 3 (a `calibrate design` run on shipped models, then its stored replies). Dataset 4 waits for the evals owners' trial, which runs the same command. Set each blocking question's cascade band from a sweep of the `@2-jev` arm on the tune split only, write it into the band constants, and state it in the summary. Then `self-test --judge --judge-backend claude --model claude-sonnet-5-5 --record` and `--judge-backend jev --model jev-1.13.0 --record`, which records `@2-jev`. `baseline-jev.json` takes its minimums from the tune split only. `summary.md` is `bench-render`'s output with a short preface. The preface names the datasets and n, and the cascade's escalation share and cost per case beside Claude's. It lists the report-split `asserts-implementation` cases of the spy-record shape with each arm's answer. It ends with the table of `JudgeBlockCalibration` per blocking question on the new recording, with the reason when it fails. The recording it commits is what lets Jev block, so the orchestrator shows the user that table and the bands before merging.
- Tests: `bench-render` on each committed JSON reproduces the committed page (catches a hand-edited summary). `self-test --judge` passes offline on both recordings. Each benchmark JSON's dataset hash equals the hash of the committed dataset. A band test fails when a constant differs from the band the summary states (catches a band set by hand after the sweep).

### `playbook-documents-the-jev-backend`
- Deps: judge-bench-measures-backends, ready-check-cascades-jev-to-claude · Gate: push · Model: opus · estLines: 100
- Writes: `plugin/docs/testing-playbook.md` (§5.4)
- Does: replace the sentence saying `backend = "jev"` reports BLOCKED. Document `send_to`, `TYPESAFE_API_KEY`, the pin, when a Jev finding may block and the note it carries when it may not, the Claude reason on a block, `test-quality@2-jev` and the cascade to Claude, `judge ask`, and the per-backend recordings. Thresholds for Jev point at the benchmark summary once it exists; until then, the page says to run it first.
- Tests: `swiftgate prose` and `docs-lint` pass on the file. The file stays under its word budget in `.swiftgate.toml`.

## Later, not planned here

The design's §11.2 candidates wait for the benchmark and for labelled sets of their own. They are the shared comment
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
