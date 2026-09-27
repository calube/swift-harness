# `review-accuracy` re-run after the source-line fix, 2026-09-27

`/swift-harness:review` on the same seeded diffs as the
[first run](../2026-09-26-review-accuracy/summary.md), 1 trial each, `claude-opus-5-5`, harness at
`2f39ae8`, after the fix that makes reviewers cite new-file lines and keeps an unmatched finding
visible (merge `a11a0aa`). The runner stopped at the 8 USD cap after 4 of 5 cases:
`unchecked-sendable-cache` didn't run. `evals/runner/review_accuracy.mjs` scored the kept runs,
and every finding matched a seeded defect or a `known` label, so none needed a new label.

**Result: the line fix works. Every seeded defect now matches by file and line, and no finding went
missing between reviewer and verifier. The severity fix didn't take: the dismiss race is still
`major`, not `blocker`. The clean control now comes back `fix-then-merge`, because the stricter
severity rule raised a race the diff didn't introduce to `major`.**

| Case | Focus | Verdict | Seeded defect | Kept findings |
|---|---|---|---|---|
| `dismiss-without-cancel` | concurrency | fix-then-merge | found, **major** (want blocker) | 5: 4 copies of the race, 1 test gap |
| `errors-swallowed` | api-errors | refactor-needed | found, blocker | 6, real |
| `reset-test-wrong-reason` | test-quality | fix-then-merge | found at `CounterFeatureTests.swift:76`, major | 2, real |
| `clean-reset` | control | **fix-then-merge** (want merge) | none seeded | 1: the baseline race, major |
| `unchecked-sendable-cache` | concurrency | didn't run | | |

| Metric | First run (5 cases) | Re-run (4 cases) |
|---|---|---|
| Right verdicts | 5 of 5 | 3 of 4 |
| Seeded defects matched by file and line | 3 of 4 | 3 of 3 |
| Seeded defects at blocker or major | 2 of 4 by the scorer | 3 of 3 |
| Findings before the verifier / kept after it | 22 / 20 | 16 / 14 |
| Kept findings labelled invented | 0 | 0 |
| Findings unmatched at verify (`unmatchedAtVerify`) | not counted | 0 |

## What changed

1. **Line numbers, fixed.** The test-quality reviewer cited `diff.patch` lines in the first run.
   Every finding in this run cites a line in the new file: the reset test at
   `CounterFeatureTests.swift:76`, the dismiss test at 74, both inside their labelled ranges. The
   verifier paired every finding, so `reconcile()` dropped nothing as unmatched. The 2 dropped
   findings were copies of a kept finding that the verifier marked unverified.
2. **Severity, not fixed.** `plugin/agents/concurrency.md` now names this exact race, "the user
   taps Fact, then Dismiss", as a `blocker`. The panel still rated it `major` in 3 findings and
   `minor` in 1. The verdict stays right only because `fix-then-merge` accepts a `major`.
3. **Duplicates.** Synthesis dedupes a defect by file, line and category. The dismiss race came
   back from 3 reviewers at lines 67, 69, 69 and 70, so 4 copies of 1 defect survived.
4. **The clean control flipped.** In the first run the baseline's missing cancellation id came
   back `minor` and the verdict was `merge`. This time the reviewer rated it `major`, so the
   verdict became `fix-then-merge`. The race is real, but the diff didn't introduce it: the fact
   effect had no cancellation id before the diff. I kept the label: a clean diff should merge. The
   review contract has no rule for a defect that predates the diff, and the stricter severity
   wording gives reviewers a reason to rate it higher.

## Cost

The 4 trials add up to 4.10 USD (0.77, 1.14, 1.31, 0.88), main session only. The panel runs
through the Workflow tool, whose agents `total_cost_usd` leaves out, so the real cost is higher.
Wall time: 391 to 455 seconds a trial.

## Verdict

1. **Verdict on the evals: working.** The scorer separated the 2 fixes: it confirmed the line fix
   and caught the severity fix failing. `unmatchedAtVerify` stayed 0, so the new count has no
   positive case yet.
2. **What the evals say about the harness.** I proposed 3 fixes to swift-harness-fe as a wave.
   First, the severity rule in the reviewer prompt doesn't move the rating, so apply it in the
   verifier, which sees the failure scenario. Second, dedupe a defect across nearby lines, not
   only the same line. Third, add a contract rule for a defect that predates the diff, so it
   can't block a clean change.
3. **Unmeasured:** `unchecked-sendable-cache` on the fixed harness, and every case beyond 1 trial.
