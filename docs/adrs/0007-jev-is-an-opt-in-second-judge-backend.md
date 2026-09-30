# 0007. Jev is an opt-in second judge backend

Status: proposed, 2026-09-30, with the Jev judge backend design
(`docs/designs/2026-09-30-jev-judge-backend-design.md`). The user decides the open questions in its §12
before any task that depends on them starts.

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
to a third party. Its API key comes from the environment and never from config.

Jev findings are advisory until Jev meets the evals design's bar on the labelled sets: at least 30 labelled
cases per blocking question, with true-positive and true-negative rates reported against those labels. The code
enforces this: a Jev answer can't make the `ready` tier RED until a later decision turns that on.

A general `swiftgate judge ask` takes a question set and subjects as JSON, so other callers, the eval runner
among them, can ask the same judge instead of building their own.

## Consequences

- A repository can try Jev with 1 config line and an API key, and turn it off the same way. Nothing changes for
  a repository that doesn't opt in.
- Thresholds for Jev come from an A/B on the 22-case test-quality set and the design calibration seeds. A
  threshold tuned on Claude never carries over, because Jev's probabilities differ in shape.
- A Jev finding has no model-written reason. Its message states the question, the probability and the model
  version, which is enough for an advisory note but not for a blocking one.
- The cache key and every recording carry the pinned Jev model id, so a new Jev release re-asks, and the
  calibration record shows which judge scored it.
- `swiftgate` gains its first HTTP client. It lives in 1 adapter behind a protocol, and tests replay captured
  replies.
- Jev's service, rate limits and prices can change without notice. A Jev outage costs a `judge.not-run` note,
  never a RED gate.
