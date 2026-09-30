# swift-harness: Jev as a second judge backend

<!-- RESUME
Status: APPROVED 2026-09-30 by the user, with the 5 decisions in §12. Jev may block `ready` on its own for a
question once the code finds a passing block calibration for it (§7).
Why: the judge seam was built with a second backend in mind (`[judge] backend = "jev"` parses today and reports
BLOCKED), and the repo runs 2 judge stacks that share no code.
Decision record: [ADR 0007](../adrs/0007-jev-is-an-opt-in-second-judge-backend.md), accepted.
Plan: [`../plans/2026-09-30-jev-judge-backend-plan.md`](../plans/2026-09-30-jev-judge-backend-plan.md).
Read first: this header, §3, §7 and §12.
-->

## 1. Purpose

Give `swiftgate` a second judge backend, TypeSafe's Jev, behind the judge seam that already exists. Jev answers
typed questions with probabilities, fast and cheap, and writes no text. The harness uses it where a question is
short, closed and cheap to label, and keeps Claude where a verdict needs a reason or a long read.

Input: a sweep of every model judge and classifier in this repo (2026-09-30), TypeSafe's API, primitives,
confidence, models and jaggedness pages (read 2026-09-30), and the evals design's judge policy
([`../../evals/design.md`](../../evals/design.md), "Judge model candidates").

### Non-goals

- Replacing Claude as the default judge. Claude stays the default backend.
- A Jev block without a passing block calibration for that question and model (§7).
- Jev in review panels, the verifier, the design challenger or any other open-ended critique (§11.3).
- A Swift SDK. TypeSafe ships Python and JS clients only; the adapter speaks the HTTP API.

## 2. What exists today

| Piece | Where | What it does |
|---|---|---|
| Question sets | `JudgeQuestionSet.tests` (`test-quality@1`) and `.comments` (`comments@1`) in `plugin/gate/Sources/SwiftGateDomain/Judge/Judge.swift` | Typed questions: `binary`, `choice`, `score`, each with a flagged option and a `mayBlock` bit |
| Policy | `JudgePolicy` in the same file | `p >= block` on a `mayBlock` question at `ready` is a major finding; `advisory <= p` is minor; below is ignored |
| Protocol and backends | `Judge`, `ClaudeCLIJudge`, `JevJudge`, `CachingJudge`, `RecordedJudge` in `plugin/gate/Sources/SwiftGateAdapters/Judge.swift` | `JevJudge` is a placeholder that throws `notConfigured` |
| Config | `JudgeConfig`, `JudgeBackend { claude, jev }` in `plugin/gate/Sources/SwiftGateDomain/Config/Config.swift`; `readJudge` in `ConfigSchema.swift` | `[judge] backend`, `model`, `advisory_threshold`, `block_threshold`; unknown keys fail |
| Callers | `TestJudgeCheck`, `JudgeCommand`, `ConfiguredCommitCommentJudge`, `JudgeSelfTest` in `plugin/gate/Sources/SwiftGateCLI/Commands/JudgeCommands.swift`; `check --tier ready` | `swiftgate judge [--ready]`, the `ready` tier's judge step, the advisory comment judge on `git commit` in the PreToolUse hook, `self-test --judge` |
| Calibration set | `plugin/gate/Fixtures/judge/` | 22 cases (11 good, 11 useless) that the tuning agent labelled, `baseline.json` (precision and recall at least 0.8 per question), `recording.json` from `claude/sonnet` |
| Design calibration | `DesignCalibrationRunner` in `plugin/gate/Sources/SwiftGateAdapters/Calibration/` | Judged labels are Choice questions to a concrete `ClaudeCLIJudge`; a judged answer passes at p of 0.7 or more (`CalibrationRecord.QuestionResult.passMargin`) |
| Eval judge | `gradeLLM` in `evals/runner/session.mjs` | Free-text PASS/FAIL from `claude -p`, 3 votes, 2 passes win; 10 rubrics use it |

The seam fits Jev: 1 subject and 1 question set become 1 request, which is the batching Jev wants.

## 3. Decision map

| Decision | Choice | Section |
|---|---|---|
| Where Jev lives | `JevJudge` in `SwiftGateAdapters`, behind `Judge`, chosen by `[judge] backend = "jev"` | §4 |
| Transport | an `HTTPTransport` protocol with a `URLSession` live type; tests replay captured replies | §4.3 |
| Model id | a pinned version, `jev-1.13.0` by default; the aliases `jev-latest` and `jev-preview` fail config | §4.4 |
| What leaves the machine | the subject, its context and the question text, to `api.typesafe.ai`, only after an explicit opt-in | §5 |
| Missing reason | a template reason for advisory findings; a Claude-written reason on every blocking finding | §6 |
| Blocking | Jev blocks alone for a question only when the code finds a passing block calibration for that question and the pinned model; otherwise its finding is advisory | §7 |
| A general entry point | `swiftgate judge ask`, question set and subjects as JSON in, answers as JSON out | §8 |
| Context | the caller slices; the adapter refuses an oversized state and never trims it | §9 |
| Benchmark | `swiftgate judge bench` runs pinned Sonnet 5.5 and pinned Jev on the same labelled datasets, k times, and writes a versioned JSON that `bench render` turns into a comparison page | §10 |
| Thresholds | set per backend from the benchmark's tune split, never from the cases it reports | §10.5 |
| Adoption order | test quality, then the commit comment judge, then design calibration | §11 |

## 4. The `JevJudge` adapter

### 4.1 Request

1 subject and 1 question set make 1 `POST https://api.typesafe.ai/v1/systemone`. Every question in the set goes
in the same request, since Jev reads the state once and answers each question in parallel.

```json
{
  "model": "jev-1.13.0",
  "state": {
    "subject_kind": "<questions.subjectDescription>",
    "subject": "<subject.source>",
    "context": "<subject.context>",
    "declared_tier": "<subject.declaredTier, omitted when nil>"
  },
  "questions": {
    "<question.id>": { "type": "noul | choice | score", "instructions": "<question.text>", "criteria": "…" }
  }
}
```

| `JudgeQuestion.Kind` | Jev type | `criteria` |
|---|---|---|
| `.binary` | Noul | none |
| `.choice(options)` | Choice | `{option: null}` for each option |
| `.score(levels)` | Score | the levels in order, worst first, as the question set lists them |

The question text goes to Jev unchanged, so the benchmark compares the same questions on both backends. The tier
question carries its option descriptions in its text today. Moving them into Choice `criteria` would be a new
question set version (`test-quality@2`) and a new calibration pass, so it waits for benchmark data (§12, decision 5).

The subject's file path doesn't go into the state. A question refers to `subject` and `context` by those names.

### 4.2 Reply

| Jev answer | `JudgeAnswer.distribution` |
|---|---|
| Noul `{noul: p}` | `{yes: p, no: 1 - p}` |
| Choice `{choice, probabilities}` | `probabilities` as returned |
| Score `{score, probabilities, legend}` | level index `"i"` maps to the question's option `i`; the adapter checks `legend` against the options and fails on a mismatch |

The adapter then runs `JudgeAnswers.validate`, like every backend. `rationale` is `nil` (§6). A Choice or Score
`confidence` isn't policy input: `JudgePolicy` reads the flagged option's probability. The adapter drops it.

The reply's `model` field must equal the requested model id. A mismatch is `malformedReply`, since the pin is
what the cache key and the recordings trust.

### 4.3 Transport, key and errors

`swiftgate` has no HTTP client today. The adapter gets 1: an `HTTPTransport` protocol in `SwiftGateAdapters`
with a live type on an ephemeral `URLSession`, and a fake in `SwiftGateTestSupport` that replays captured
replies. Shelling out to `curl` through `ProcessRunner` was the other option; it would put the key in a process
argument list and add a tool version to pin, so the design doesn't use it.

- **Key.** Read from `TYPESAFE_API_KEY` in the environment at call time. Config can't hold it:
  `[judge]` rejects unknown keys today. No log, finding, error message, cache file or recording includes the key
  or the request headers. A test proves it with a sentinel key.
- **Timeout.** 30 s per request for `judge` and `check`, and the comment judge's 15 s inside the hook.
- **Errors.** No key is `notConfigured` naming the variable. HTTP 401 is `backend` naming the variable; 422 is
  `backend` with the reply body, since it means the adapter built a bad request. 429 and 529 retry with
  exponential backoff inside the timeout, honouring `retry-after`, then fail as `backend`. HTTP 400 with
  `{"detail":{"error_type":"max_tokens_exceeded"}}` is `stateTooLarge`, the same case the adapter's own size
  check throws (§9), since the caller must slice the state. Any other status, or a body that isn't the reply
  shape, is `malformedReply`.
- **Outcome.** As with Claude, a failed judge is a non-gating `judge.not-run` note, never RED.

### 4.4 Identity, pin and cache

`JudgeIdentity` is `jev` and the pinned model id. Its cache key and every recording already include that
identity, so a new pin re-asks and never reuses stale answers. `[judge] model` for `jev` defaults to
`jev-1.13.0`. An alias fails config: an alias moves to a new model without a change on this side, and TypeSafe's
own docs say to pin the version you tuned a threshold on.

`JudgeFactory` builds `JevJudge` with the live `HTTPTransport` and the process environment, and keeps wrapping it in
`CachingJudge`.

### 4.5 Cost and latency accounting

The benchmark (§10) needs cost, tokens, latency and the served model per call. `Judge` gains a `measuredAnswer`
requirement returning answers plus a `JudgeUsage` (input and output tokens, cost in USD, wall time, the
backend's own reported time when it has one, the served model). A protocol extension
gives every judge a default with no usage, so `FakeJudge` and existing callers don't change. Claude reads
`total_cost_usd`, `duration_ms`, `duration_api_ms`, `usage` and the model key of `modelUsage` from its result
envelope; Jev reads `usage.input_tokens` and prices it at
the pinned model's per-token rate, kept beside the pin. `CachingJudge` reports a cache hit as 0 cost.

## 5. What leaves the machine, and the opt-in

| Caller | Sent to `api.typesafe.ai` |
|---|---|
| `swiftgate judge`, `check --tier ready` | each new or changed host test function, the production diff of its package (up to 12,000 characters), its tier, the question text |
| The comment judge on `git commit` | each staged added comment, up to 6, with the 6 lines after it |
| `calibrate design --judge-backend jev` | the agent's output for a seed and the judged label questions |
| `judge ask` | whatever the caller puts in the JSON |

Claude as a backend already sends the same text to Anthropic, and a repository opts in with `[judge] backend`.
Jev adds a new third party. The user's decision (§12, decision 4): `backend = "jev"` also needs
`send_to = "api.typesafe.ai"` in `[judge]`, and the key comes from `TYPESAFE_API_KEY`. Config fails naming the missing key, so a copied
`backend` line can't start sending code to a new host.

## 6. The missing reason

Claude returns a one-line `rationale`, which becomes the finding's `failureScenario`. Jev returns none. The
evals design wants a reason with every verdict, because error analysis sorts failures by it.

The user's decision (§12, decision 3):

1. **Advisory findings get a template reason.** The message already names the problem, the probability and the
   backend and model, as in `the test would likely still pass if the behavior it names broke (p=0.83,
   jev/jev-1.13.0)`. `failureScenario` stays `nil`, which the report contract allows.
2. **A blocking finding gets a Claude-written reason.** When a Jev finding blocks under §7, the check asks
   `ClaudeCLIJudge` that 1 question about that 1 subject. Claude's rationale becomes `failureScenario`, and
   Claude's probability goes in the message beside Jev's. Jev's answer still decides the finding: Claude writes
   the reason and doesn't overrule it. Claude runs only on blocking findings, so its cost stays small.
3. **Split questions carry their own diagnosis.** A rubric split into 1 Noul per clause (§11.2) names the clause
   that failed, which is most of what a reason gives error analysis.

When Claude can't answer (no `claude` on `PATH`, a timeout, an error), a calibrated Jev block stands with the
template reason and a `failureScenario` naming why Claude's reason is missing. The user decided this on
2026-09-30.

## 7. Jev blocks only once calibrated

The user's decision (§12, decision 1): Jev may block `ready` on its own for a question, but only once it has a
passing calibration for that question. The code enforces it, not the docs. For a Jev answer, `JudgePolicy` treats a
`mayBlock` question as blocking only when the block calibration below passes for that question id and the
pinned Jev model. Otherwise the finding stays minor, with a note that says why.

### 7.1 The block calibration

The calibration record is the committed Jev recording, `recording-jev.json`, scored against the labelled set.
Pure domain code, `JudgeBlockCalibration`, computes it each time the ready policy runs, so no separate summary
file exists to hand-edit or drift. For 1 question id, the pinned model and the repository's `block_threshold`,
it passes when all of these hold:

1. The recording answers the check's question set version (`test-quality@1`), and its identity is `jev` with the
   model id the config pins.
2. At least 30 cases in the report split (§10.5) carry a person's label for that question, with at least 10 where the flag should fire and
   10 where it shouldn't, so both rates rest on real counts. A label from an agent doesn't count.
3. At the repository's `block_threshold`, Jev's true-positive and true-negative rates on those cases are each at
   least 0.8, and at least Claude's rates from `recording.json` on the same cases.

The first 2 conditions are the evals design's bar. The 0.8 floor is the existing test-quality baseline, and the
comparison with Claude is the evals design's condition for keeping Jev. Rates at the configured threshold
matter because a repository that lowers `block_threshold` must meet the bar again at the new value.

The plugin ships the labels and recordings under `gate/Fixtures/judge/`. The ready check reads them from
`SWIFTGATE_HARNESS_ROOT`, as `self-test` does. Without that root, or without a recording, the calibration
doesn't pass.

### 7.2 Policy

`JudgeBackend` gains a pure `needsBlockCalibration`: `false` for `claude`, which keeps today's behaviour, and
`true` for `jev`. For a Jev answer over the block threshold on a `mayBlock` question at `ready`:

| Block calibration | Finding |
|---|---|
| passes | major, and the gate goes RED; the reason comes from Claude (§6) |
| fails | minor, with `advisory: jev has no passing block calibration for <question> on <model>: <why>` |

`<why>` names the first condition that failed: no recording, a recording from another model, another question
set version, `23 of 30` person labels, a rate under 0.8, or a rate under Claude's.

### 7.3 Freshness

A new pin makes the calibration stale the same way calibration freshness works for agents: the recording's
model no longer matches, so every Jev finding falls back to advisory until someone re-records it and the rates
pass again. A new question set version does the same. `self-test --judge` fails with
`swiftgate.self-test.judge-stale` meanwhile (§10.8). A label change takes effect at once, since the policy
computes the calibration each run.

### 7.4 Growing the labelled set

Today's 22 cases carry the tuning agent's labels, a bias the sub-project 2 review names. The set grows to at
least 30 person-labelled cases in the report split for each blocking question, `fails-if-broken` and
`asserts-implementation`, with at least 10 on each side. The tune split (§10.5) takes about 1 case in 3, so the
whole set needs about 45 person-labelled cases. The user confirmed that size and the fixed split on
2026-09-30.

- Each case in `labels.json` gains `labeller`, `person` or `agent`. A case without it reads as `agent`, so the
  existing 22 count only once a person relabels them.
- The person labels blind: a sheet shows each case under a neutral number with only the test and the diff,
  never the drafter's intent or the case's directory name.
- Candidate cases come from real tests in the repo's history and examples, plus hollow variants an agent
  drafts. The drafter writes no label, and the person's label is the only one recorded.

## 8. `swiftgate judge ask`

The eval runner grades 10 rubrics with its own `claude -p` stack: its own prompt, free-text parsing and 3-vote
majority. CLAUDE.md says every check goes through `swiftgate`. A general entry point lets the eval runner, and
later skills, ask the gate's judge.

`swiftgate judge` becomes a command group. `tests` is its default subcommand, so `swiftgate judge --ready` keeps
working. `ask` is new:

```
swiftgate judge ask --input <file|-> [--backend claude|jev] [--model <id>] [--no-cache] [--json]
```

Input:

```json
{
  "questionSet": { "id": "guard-evasion", "version": 1, "subjectDescription": "…",
                   "questions": [ { "id": "…", "text": "…", "kind": "binary|choice|score", "options": ["…"] } ] },
  "subjects": [ { "id": "…", "source": "…", "context": "…" } ]
}
```

Output, versioned like every report: `schemaVersion`, `identity`, and per subject the validated distribution per
question, the rationale when the backend gave one, and `usage`. `ask` applies no policy. The caller picks its own
threshold, since an eval rubric and a gate rule want different ones. It uses the repository's `[judge]` config
when there is one; `--backend` and `--model` override it. The opt-in in §5 applies to `--backend jev` too. Exit 0
answered, 2 for bad input, 3 when the backend can't answer.

The user's decision (§12, decision 2): build `ask` now. The evals owners first trial it on 1 rubric, split into
1 Noul per clause, before any other rubric moves.

## 9. Context and state slicing

Jev's limits: 64K tokens per request, and 32K for the state plus the longest question. Accuracy also falls as
unrelated text grows, so a smaller state is better even inside the limit.

- **The adapter never trims.** It estimates tokens as UTF-8 bytes divided by 3, a conservative bound for code,
  and refuses a state over 30K tokens with `stateTooLarge(estimatedTokens: <n>)` before sending. A silent
  cut could drop the line a question asks about.
- **Callers slice.** `TestJudgeCheck` already caps context at 12,000 characters. The comment judge sends 6 lines.
  Design calibration sends 1 agent output; the benchmark records the largest state of each dataset.
- **Eval rubrics need real slicing.** A digest can reach 60,000 characters, plus 20,000 of final message and
  20,000 of diff. Each clause gets only its slice: the turns after the first deny for an evasion clause, the final
  message for a claims clause. Clauses a regex or the hook log can decide move to code graders.

## 10. Benchmark, calibration and freshness

### 10.1 What the benchmark compares

2 backends, each at a pinned id: Claude at `claude-sonnet-5-5`, never the `sonnet` alias, and Jev at
`jev-1.13.0`. Each run records the backend, the requested model id and the served model version: the reply's
`model` field for Jev, the `modelUsage` key of the result envelope for Claude. A served version that differs
from the one the run started with fails the run, since the answers would mix 2 models. The gate's own default,
`sonnet`, doesn't change here; the benchmark and the committed recordings use the pinned id.

### 10.2 Datasets, in order of readiness

| # | Dataset | Questions | Labels | Ready |
|---|---|---|---|---|
| 1 | `test-quality@1`, `plugin/gate/Fixtures/judge/` | all 4 | 22 cases the tuning agent labelled, then the harder person-labelled set (§10.3) | now as a smoke set; the harder set after the §7.4 labelling pass. The page names the labeller mix |
| 2 | The comment judge, `plugin/gate/Fixtures/judge-comments/` | `loses-fact`, `right-size` | a person's, gathered as below | after a labelling pass |
| 3 | `calibrate design`'s judged labels, from a run's stored replies | each seed's judged questions | the expected option each seed's label file names | once `calibrate design` keeps agent replies |
| 4 | 1 eval rubric, split into 1 Noul per clause | 1 question per clause | a person's, per clause, on transcript slices (§9) | when the evals owners run their trial (§8) |

**Gathering comments.** A worker collects comments that commits added to Swift files, from this repo's history and
`examples/SampleApp`. It samples up to 80, half from lines a `comments.*` rule flags and half from lines no rule
flags, so both answers appear. Each case holds the comment and the 6 lines after it, the same state the hook
judge sends. The person labels them blind, under neutral numbers, on the same kind of sheet as §7.4. The dataset
counts only once each question has at least 30 cases in the report split and 10 on each side.

**Format.** Every dataset reduces to 1 JSON shape: the question set, or its versioned id for a built-in set, and
cases with `id`, `source`, `context`, an optional `declaredTier`, per-question `labels` and a `labeller`. The
dataset hash is SHA-256 over its canonical form, labels included, so a relabel is a new dataset.

### 10.3 The 22-case set has hit its ceiling

A live baseline on 2026-09-30 ran `self-test --judge --judge-backend claude` at `claude-sonnet-5-5` 3 times,
with 4 requests at a time, about 30 s each. Runs 1 and 2 scored 1.00 precision and recall on all 4 questions.
Run 3 missed 1 case on `name-specificity`, a recall of 0.88 (7/8). With Sonnet at the ceiling and so few
positives, the set can't rank 2 backends at the top: both can score 1.00 while differing on cases the set lacks.
The self-test JSON reports only precision, recall and their counts. It has no per-case probability, latency or
cost, so Brier, reliability, latency and cost need `measuredAnswer` (§4.5) and the benchmark's per-case raw
answers first.

The benchmark therefore adds a harder, person-labelled test-quality set, built with the §7.4 labelling pass:

- **Near misses.** Tests that assert something true but miss the behaviour their name claims; tests that mock 1
  collaborator too many; tests whose only assertion is on a value the test itself built.
- **Ambiguous tiers.** Tests on the boundary between host logic and rendering, such as a reducer test that
  reads a formatted string, so `tier` has more than 2 positives.
- **Balance.** At least 10 positives and 10 negatives per question in the report split, and at least 30 cases
  per blocking question, which is also what the block calibration in §7 needs.

The 22 cases stay as a smoke set that every backend must pass; the harder set is the one that ranks.

### 10.4 Metrics

Every metric is per question and per backend, and every number carries its n.

| Metric | Definition |
|---|---|
| Counts | true and false positives and negatives at the configured threshold, with the flag firing as the positive class |
| Precision, recall, true-positive rate, true-negative rate | from those counts; recall and the true-positive rate are the same number, shown once |
| Accuracy | the most probable option against the label, for binary, Choice and Score questions alike |
| Brier score | the mean over cases of the squared error summed over options, from the full distribution |
| Reliability | the flagged probability in 10 equal bins: mean predicted, observed rate and count per bin, plus the expected calibration error. Thresholds gate, so a backend whose 0.9 isn't right 9 times in 10 can't set one |
| Stability | over k repeats, k at least 3: the share of cases whose decision or most probable option flips, and the mean standard deviation of the flagged probability |
| Agreement | Cohen's κ between the 2 backends on each question's decision, from the majority over repeats |
| Latency | wall time p50 and p95 per request, and per case (all requests to answer 1 case once), plus the backend's own reported time |
| Cost and tokens | input and output tokens per case, cost per case, and cost per 1,000 judgments, where 1 judgment is 1 question for 1 case |

The benchmark sends each case's requests 1 at a time by default, so queueing doesn't pollute latency, and never
reads or writes the judge cache, so repeats measure the model and not the cache.

### 10.5 Honesty rules

- **n beside every number.** The page never shows a rate without its count, as in `0.91 (10/11)`.
- **Intervals.** Proportions carry 95% Wilson intervals. Brier, the calibration error, κ and each difference
  between backends carry 95% intervals from a paired bootstrap over cases, 2,000 resamples with a fixed seed.
- **Small sets say so.** The 22-case set has few positives per question: 5 for `fails-if-broken`, 2 for `tier`,
  8 for `name-specificity` and 3 for `asserts-implementation`. A perfect 5/5 recall has a 95% interval from 0.57
  to 1.00, and 3/3 runs from 0.44 to 1.00. The page states that whenever the interval of a difference crosses 0.
- **No tuning on reported cases.** A fixed rule splits every dataset: a case whose SHA-256 of its id starts
  below `0x55` is in the tune split, about 1 in 3; the rest are in the report split. Threshold sweeps read only
  the tune split. Every headline metric, and the block calibration in §7, reads only the report split. A
  threshold chosen on the report split is the mistake this rule exists to stop.

### 10.6 Commands and output

```
swiftgate judge bench --dataset <path|built-in id> --backend claude:claude-sonnet-5-5 --backend jev:jev-1.13.0
                      [--repeats 3] [--concurrency 1] --out <file>
swiftgate judge bench-render <file> [--out <file.md>]
```

`bench` writes 1 versioned JSON: `schemaVersion`, the `swiftgate` version, the start time, the dataset id, hash
and split counts, the labeller mix, and per backend its identity and every run's raw answers with usage, per
repeat and per case. It also writes the metrics section, computed by pure domain code from those raw answers.
`bench-render` recomputes the metrics from the raw answers and refuses a file whose stored metrics differ. It
prints a markdown comparison page: a table per question with both backends side by side, the intervals, the
reliability bins, and every case where the backends disagree, with both probabilities.

The measuring lives in `swiftgate`, not in a script, so the eval runner and the gate share 1 definition of every
metric. Results go under `evals/results/<date>-judge-benchmark/`: the JSON and the rendered page, committed.

### 10.7 Recordings per backend

`plugin/gate/Fixtures/judge/` holds 1 recording today. It becomes 1 per backend: `recording.json` stays
Claude's, recorded again at `claude-sonnet-5-5`, and `recording-jev.json` and `baseline-jev.json` hold Jev's.
`self-test --judge` scores every recording that exists, each against its own baseline, offline. The block
calibration (§7) reads these recordings, not the benchmark JSON.

Jev's thresholds come from the tune split. A threshold tuned on Claude never carries over: a Noul probability and
a Choice probability for the same question aren't comparable, per TypeSafe's own jaggedness notes.

### 10.8 Freshness

- A recording records the identity that answered it, pinned model included. `self-test --judge` fails with
  `swiftgate.self-test.judge-stale` when a recording's model isn't its backend's current default pin, so a pin
  bump forces a re-record.
- `last-pass.json` for `calibrate design` records the agents' models but not the judge's. It gains
  `judge: {backend, model}`. The push tier's `calibration-freshness.wrong-model` also covers a record whose judge
  isn't the command's default judge, so a Jev-judged pass never stands in for the shipped one.
- A benchmark result names its dataset hash and both served versions, so a reader can tell whether a comparison
  is stale without running it again.

## 11. Order of adoption

### 11.1 Planned now

| Order | Use | Jev mapping | Why here |
|---|---|---|---|
| 1 | `test-quality@1` (`swiftgate judge`, `check --tier ready`) | `fails-if-broken`, `asserts-implementation`: Noul. `tier`: Choice. `name-specificity`: Score | Typed already, and the only question set with a labelled set and a baseline |
| 2 | The commit comment judge (`comments@1`) | `loses-fact`, `right-size`: Noul | Latency-bound in the hook (15 s, at most 6 comments) and advisory only. A fast backend helps most here |
| 3 | `calibrate design`'s judged labels | Choice | Choice plus a threshold already. The known flaky answers near p of 0.55 and 0.6 are the uncertain band the benchmark's reliability bins measure |

### 11.2 Later candidates, not in the plan

Each needs its own labelled set before it counts.

| Use | Shape | Note |
|---|---|---|
| Comment audit | 1 question set for KEEP, TRIM and CUT, shared by the `comment-audit` skill, the commit judge and the `comments.*` rules | 3 implementations today; the skill would call `judge ask` |
| Eval rubrics | each "PASS only if all hold" rubric split into 1 Noul per clause; code ANDs them | Probabilities in place of votes, and a per-clause diagnosis. 4 guard rubrics share 1 evasion clause. Needs §9 slicing and 30 labels per clause |
| Design claim checker | a Jev first pass on each quote and claim; Claude (opus) only for the uncertain band | TypeSafe's citation-check cookbook has this shape. Refuted claims still need a reason, so Claude writes it |
| `design-lint.perf-missing-dimension` | 7 Nouls in 1 request, 1 per performance dimension | Replaces a keyword match with a judgment; the rule is major, so it stays deterministic until calibrated |
| Noisy minor rules | a Noul confirms each hit of `comments.restates-code`, `comments.ai-prose`, `test.misplaced-t2` | The rule stays deterministic and Jev only filters its false positives |

### 11.3 Poor fits

| Use | Why not |
|---|---|
| The verifier | It must trace code and reproduce a failure, which is multi-step reasoning, not a closed question |
| Review panels, the design challenger, pre-mortem, the evidence auditor | They generate findings; Jev can only pick among answers it's given |
| Build worker outcome labels | `build check-return` already cross-checks them against git and the run store |
| Prose rules | They are major and can't be suppressed, so they stay deterministic |
| `DesignDiff`'s unchanged, clarify and amend | It decides whether an approval survives an edit; that must stay mechanical |
| Any question over a whole eval transcript | Over the context limit, and long noisy state is where Jev loses accuracy |

## 12. Decisions from the user (2026-09-30)

| # | Question | Decision |
|---|---|---|
| 1 | May Jev ever block the `ready` gate? | Yes, on its own, but only once calibrated: per question and per pinned model, at least 30 person-labelled cases and true-positive and true-negative rates that meet the bar. The code enforces it and downgrades an uncalibrated block to advisory with a note; a model change makes the calibration stale (§7) |
| 2 | Do the eval runner's `llm` graders move onto `swiftgate judge ask`? | Build `ask` now. The evals owners trial it on 1 rubric split into 1 Noul per clause before anything else moves (§8) |
| 3 | How does a Jev finding get its reason? | A template reason for advisory findings. Every finding that would block, a calibrated Jev block included, gets a Claude-written reason (§6) |
| 4 | What does the egress opt-in look like? | `backend = "jev"` needs `send_to = "api.typesafe.ai"`; the key comes from `TYPESAFE_API_KEY` (§5) |
| 5 | Should the tier question's option descriptions move into Choice `criteria`? | Not for the benchmark: `test-quality@1` stays as is, and `test-quality@2` comes only if Jev's `tier` metrics fall short (§4.1) |

## 13. Testing the harness

- **Fixtures from real runs only.** A capture task sends real requests to `api.typesafe.ai` with the user's key.
  It captures 1 `test-quality@1` request for a labelled case, covering Noul, Choice and Score, and 1 `comments@1`
  request. It also captures a bad key (401), an invalid question (422), and 1 request to `jev-latest` for the
  served model id. Each command goes in `plugin/gate/Tests/Fixtures/README.md`. Nobody can force a 429 or 529 on
  demand: the retry test drives the fake transport by status code alone, and the adapter never parses those bodies.
- **Mapping.** Each captured reply decodes to a distribution that `JudgeAnswers.validate` accepts, and each
  Score level maps to the right option (a swapped order fails).
- **No key leaks.** With a sentinel key, no error, finding, cache file or recording contains it.
- **Blocking only when calibrated.** A Jev answer at p of 0.99 on `fails-if-broken` at `ready` is minor with no
  recording, with a recording from another model, and with 29 person labels. It is major with a passing
  calibration for that question and model, and a passing calibration for `asserts-implementation` alone doesn't
  unlock `fails-if-broken`. The same answer from a Claude identity is major, as today.
- **Benchmark metrics.** Pure domain tests pin each metric on small inputs worked by hand: a Brier score, a
  Wilson interval, κ for 2 known decision lists, a flip share over 3 repeats, a bin table. The bootstrap with a
  fixed seed gives the same interval twice.
- **Offline self-test.** `self-test --judge` scores `recording-jev.json` against `baseline-jev.json` with no
  network.
