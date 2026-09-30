# 0007. Jev is an opt-in second judge backend

Status: accepted by the user, 2026-09-30, with the Jev judge backend design
(`docs/designs/2026-09-30-jev-judge-backend-design.md`) and the 5 decisions in its §12.

## Context

`swiftgate` already has a judge seam: typed questions in, a probability per option out, and `JudgePolicy`
turning probabilities into findings by threshold. Claude, through `claude -p --json-schema`, is its only working
backend. The config accepts `[judge] backend = "jev"`, but that adapter is a placeholder that reports `BLOCKED`.

TypeSafe's Jev is a decision model. It answers yes/no (Noul), Choice and Score questions with probabilities over
HTTP, runs every question about 1 state in parallel, and charges per input token. It writes no text, so it
returns no reason. Its context holds 64K tokens per request, and 32K for the state plus the longest question.
The evals design already names it as a candidate second judge for short pass or fail dimensions, and not as the
main judge, because it gives no reason, has no built-in abstain answer, and loses accuracy on long, noisy
context.

The repo also runs 2 judge stacks that share no code: the gate's Swift judge and the eval runner's
`claude -p` PASS/FAIL voting. CLAUDE.md says every check goes through `swiftgate`.

## Decision

Jev becomes a second backend behind the existing `Judge` protocol, as a `JevJudge` adapter in
`SwiftGateAdapters` beside `ClaudeCLIJudge`. `[judge] backend` selects it. `SwiftGateDomain` stays pure: the
question sets, policy and calibration code don't change shape.

Claude stays the default backend. Jev is opt-in per repository, because it sends test source, diffs and comments
to a third party: `backend = "jev"` needs `send_to = "api.typesafe.ai"` beside it. Its API key comes from
`TYPESAFE_API_KEY` and never from config.

Jev may block the `ready` tier on its own, but only for a question with a passing calibration. For each
question id and pinned Jev model, the code checks the committed Jev recording against the evals design's bar.
The bar is at least 30 person-labelled cases, and true-positive and true-negative rates of at least 0.8 and at
least Claude's, at the repository's block threshold. Without that, the finding is advisory with a note saying why. A new Jev model makes
the calibration stale until someone records it again.

A Jev finding that blocks carries a reason Claude writes about that subject. An advisory Jev finding carries a
template reason: the question, the probability and the model.

A general `swiftgate judge ask` takes a question set and subjects as JSON, so other callers, the eval runner
among them, can ask the same judge instead of building their own. The eval runner trials it on 1 rubric, split
into 1 Noul per clause, before anything else moves.

## Consequences

- A repository can try Jev with 1 config line and an API key, and turn it off the same way. Nothing changes for
  a repository that doesn't opt in.
- `swiftgate judge bench` compares pinned Sonnet 5.5 (`claude-sonnet-5-5`) with pinned Jev on the same labelled
  datasets, k times, and commits a versioned result with every number's n and interval. Jev's thresholds come
  from each dataset's tune split, never from the cases the benchmark reports. A threshold tuned on Claude never
  carries over, because Jev's probabilities differ in shape.
- The 22-case test-quality set can't rank the 2 backends: Sonnet 5.5 scores at or near 1.00 on it. A harder,
  person-labelled set has to exist before the benchmark can say which backend is better.
- A blocking Jev finding still costs 1 Claude call, for its reason. Claude runs only on those findings.
- Jev can't block anything until a person labels at least 30 cases per blocking question; the 22 cases the
  tuning agent labelled don't count.
- The cache key and every recording carry the pinned Jev model id, so a new Jev release re-asks, and the
  calibration record shows which judge scored it.
- `swiftgate` gains its first HTTP client. It lives in 1 adapter behind a protocol, and tests replay captured
  replies.
- Jev's service, rate limits and prices can change without notice. A Jev outage costs a `judge.not-run` note,
  never a RED gate.
