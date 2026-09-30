# Jev judge backend: interfaces

What each merged wave of [the Jev judge plan](../plans/2026-09-30-jev-judge-backend-plan.md) exposes to later waves: types, formats, flags, exit codes and constraints. Each wave appends a section when it merges.

## Wave 1

### `jev-replies-are-captured`

Commits and gate: 333cba6, 1a6290e; gate 20260930T144538Z-852d72fa.
- Fixtures are in plugin/gate/Tests/Fixtures/Judge/:
  - replies: jev-{test-quality,comments,alias,invalid,bad-key,oversize}.reply.json
  - status: .status holds a code and "\n"
  - requests: jev-request-*.json
  - The repository leaves out the 157KB oversize request; the README has its build command.
- Status codes:
  - 200 for test-quality, comments and alias (jev-latest serves "jev-1.13.0")
  - 422 {"detail":[{type,loc,msg,input}]}
  - 401 {"detail":{"error_type":"authentication_error","message"}}
  - 400 {"detail":{"error_type":"max_tokens_exceeded"}}
- SPEC GAP: design §4.3 doesn't list 400 max_tokens_exceeded, so today the adapter maps it to `malformedReply`. The `jev-judge-answers-over-http` task must map it to its own error (too large).
- Noul answers have no confidence. Jev keys the Score legend and probabilities by "0","1","2". The server may reorder probabilities. Score confidence can be 0.
- usage is {input_tokens, output_tokens}.

### `judges-report-usage`

Commits and gate: surface d5a98cc, behaviour c75dc6f; gate 20260930T145845Z-745c3ea6, prove at the surface commit.
- `JudgeUsage` fields: inputTokens, outputTokens, costUSD, wallMilliseconds, backendMilliseconds, servedModel, cached. Also `JudgeUsage.milliseconds(Duration)`.
- `JudgeReply` holds {answers, usage}. `Judge.measuredAnswer(_:questions:) async throws(JudgeError) -> JudgeReply`. `ClaudeJudgeReply.parseReply`.
- From a Claude reply: wall = duration_ms, backend = duration_api_ms. inputTokens includes cache reads and writes. The parser rejects a reply with no `duration_ms` or with two `modelUsage` keys as `malformedReply`.
- A cache hit is `cached` with 0 cost. `FakeJudge` has no usage by default.
- Deviation: the task added `TD/JudgeUsageTests.swift` outside its write set, because the untested-change rule requires it.
- OPEN (#6): each call's usage records `servedModel`, and nothing else does yet. Recordings, baselines and last-pass.json still store the alias. Candidate: fold into self-test-scores-each-backend-recording (wave 4), or a separate small task.

### `jev-blocks-only-when-calibrated`

Commits and gate: surface d6c6866, behaviour aec6bf7; gate 20260930T151142Z-55fc03d6; 30/30 tests proved.
- `JudgeBlockCalibration.evaluate(question:in:model:blockThreshold:set:jev:claude:)` returns .passes(Rates) or .fails(reason:).
- `JudgeRecording{questionSet,identity,answers}` has the same JSON as RecordedJudge.Recording.
- `JudgeCaseSplit.of(id)` returns .tune or .report. `Case.labeller` is person or agent; missing reads as agent, unknown fails decoding.
- `JudgePolicy.findings(…, blockAuthority: .standing | .perQuestion([id: Decision]))`. Jev on .standing never blocks.
- `JudgeCalibrationFiles.blockDecisions(harnessRoot:questions:model:blockThreshold:)` reads recording.json (Claude) and recording-jev.json. `TestJudgeCheck.Dependencies(harnessRoot:)` takes its value from `SWIFTGATE_HARNESS_ROOT`.
- Deviation: the task added `TA/JudgeCalibrationFilesTests.swift`, because the untested-change rule requires it.
- A 19-of-24 rate on each side pins the 0.8 floor (a399bcc).

## Wave 2

### `config-pins-jev-and-names-its-host`

Commits and gate: surface f3d0ae9, behaviour 16c7d9b; gate 20260930T154833Z-36eab45f; 9/9 tests proved.
- `JudgeBackend.jev` has `egressHost` "api.typesafe.ai", `pinnedModel` "jev-1.13.0", `keyVariable` "TYPESAFE_API_KEY", and `isPinned(_:)` (true only for jev-<n>.<n>.<n>).
- New `ConfigIssue` cases, all RED under swiftgate.config: `judgeHostNotNamed`, `judgeHostMismatch`, `judgeHostUnused(backend: nil = off)`, `judgeModelNotPinned`, `judgeSecretInConfig` (never echoes the value).
- A valid Jev table decodes with `model: nil`. The factory resolves `model ?? backend.pinnedModel`; the adapter task owns that change and its identity test.
- Also changed: SelfTestCommand switch cases, RuleIDSourceScan.notRuleIDs, CheckJudgeStepTests, the template, and the docs/index.md interfaces link.
- The `playbook-documents-the-jev-backend` task owns testing-playbook §5.4.

### `jev-judge-answers-over-http`

Commits and gate: surface 012af6d, behaviour e9a2cb6; gate 20260930T161326Z-e5a5fa1c; 24/24 tests proved.
- `JevJudge(model:transport:environment:clock:timeout:)`: the timeout defaults to 30 s; pass 15 s for the commit hook. It retries on 429/529.
- `JudgeError.stateTooLarge(estimatedTokens:)`: the estimate is ceil(state UTF-8 bytes / 3), with a limit of `JevJudge.maxStateTokens` = 30_000. HTTP 400 max_tokens_exceeded also maps to it. The task updated spec §4.3 and §9.
- `JudgeFactory.make(_:runner:cacheDirectory:transport:environment:)` builds jev/jev-1.13.0.
- Cost = input tokens × `JevPin.pricePerMillionInputTokens` (0.042, from TypeSafe's models page); nil for any other model. The adapter refuses a reply whose servedModel differs from the pin.
- Test support: `HTTPTransport`, `URLSessionTransport(configuration:)`, `RetryClock`, `FakeHTTPTransport.captured(name)`, `FakeRetryClock`, `StubURLProtocol`.
- `JevPin` reads `JudgeBackend.jev` fields with `!` (static constants).

### `judge-benchmark-metrics`

Commits and gate: surface 5c23a60, behaviour 7c56d42; gate 20260930T162220Z-e9d666fc; 31/31 tests proved.
- Inputs: `JudgeBenchmarkCase{id, declaredTier?, expected}` and `JudgeBenchmarkRun{identity, repeats: [[caseID: [JudgeReply]]]}`.
- `JudgeReportCases` and `JudgeTuneCases` filter by `JudgeCaseSplit`; a sweep accepts only `JudgeTuneCases`.
- `JudgeBenchmarkMetrics.question/compare/usage/sweep/kappa/reliability` return JudgeQuestionBenchmark, JudgeBackendComparison, JudgeUsageBenchmark and [JudgeThresholdPoint]. Counts reuse JudgeQuestionMetrics.
- `JudgeProportion{count,n}`; `JudgeEstimate{value?, undefined?, n, interval?}`. `JudgeUndefined` is .noCases or .chanceAgreementIsCertain.
- Counts, κ and rates use each case's majority decision over repeats (a tie goes to the mean probability). Brier, accuracy and reliability use the mean distribution.
- `JudgeBootstrap`: 2000 resamples, seed 20260930, SplitMix64, nearest-rank percentiles.
- Deviation: surface-check was RED on 3 struct-returning stubs, which no allowed stub form covers. The prove at the surface still worked.

## Wave 2 (continued) and wave 3

### `calibrate-design-keeps-agent-replies`

Commits and gate: surface 2d33463, behaviour 6d1c888; gate 20260930T162945Z-c554ba3a; 8/8 tests proved.
- Layout: `.harness/runs/<run id>/calibrate-design/<agent>/<seed>.txt` holds the raw reply; `<seed>.json` holds {schemaVersion:1, requestedModel, servedModels:[modelUsage keys, sorted]}.
- `swiftgate calibrate design --replay <run id>` judges kept replies and runs no agent. It exits 0/1/2 like a live run, a missing reply exits 2 naming the seed, and it never writes last-pass.json. It refuses `--model` and anything that isn't a run id.
- Types: `DesignCalibrationReplies(root:runID:mode: .keep|.replay)`, `DesignCalibrationRunner(replies:)`, `CaseRun.servedModels` and `CaseRun.replyPath`.
- `StaticCheckRun.execute` gained `runID: String? = nil`.
- OPEN (#6): last-pass.json still stores the alias; freshness doesn't check the served model yet.

### `blocking-questions-reach-thirty-person-labels`

Commits and gate: cases+sheet da69943, gate GREEN 20260930T163647Z; failing labels test 51953a1, held until the user labels.
- 66 cases in total: report split 44 (15 old, 29 new), tune split 22. The new ids are neutral `case-xxxxxx`. The existing 22 cases now carry labeller "agent".
- J/labelling-sheet.md is blind: after each `Answer <question>:` line, write an option or leave it blank.
- After the user labels, two things break. First, recording.json has no answers for the new cases, so `recordedCalibration` fails until the self-test or benchmark task re-records live.
- Second, self-test --judge counts a skipped answer as unscored, which reads as a regression. The wave-4 self-test task must handle it.
- The worker's own estimate: each question has about 13-14 flagged cases in the report split, a thin margin over 10.
- Merged to main: cases + sheet + tool (1f28794). Command: `node tests/judge_labelling_sheet.mjs apply`. The failing labels test waits on branch `labels-test-awaiting-person-labels` (dc1ea03); cherry-pick it after the user labels.

### `commit-comment-judge-runs-on-jev`

Commits and gate: surface f95c271, behaviour 8546e8e, test fix 55ff63e; gate 20260930T164857Z-a51fa607; 5/5 tests proved.
- `ConfiguredCommitCommentJudge.judge(for:root:transport:environment:clock:) -> (any Judge)?`
- `ConfiguredCommitCommentJudge.concurrency(_ backend: JudgeBackend) -> Int`: claude 4, jev 6. `JudgeBatch.answer(_:questions:judge:maxConcurrent:)`.
- Failure text: "Comment judge not run: <JudgeError>". The cap stays at 6, as the design sets; Jev's wait no longer grows with the comment count.
- Live: the real hook took 889 ms wall on Jev, with 3 Jev calls.
