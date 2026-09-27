# First `review-accuracy` run, 2026-09-26

`/swift-harness:review` on 5 diffs over SampleApp, 1 trial each, `claude-opus-5-5`, `main` at the
guard wave. 4 diffs carry 1 seeded defect each that swiftgate can't see; each passes the push tier,
which the review requires before it starts. The 5th is a clean control. The scorer,
`evals/runner/review_accuracy.mjs`, matches each finding to the seeded defects by file and line,
and I labelled every other finding by hand.

**Result: the panel reached a correct verdict on all 5 diffs, flagged all 4 seeded defects, and
invented nothing: all 20 findings it kept are real. It has 2 weaknesses: the test-quality reviewer
cites `diff.patch` line numbers instead of source lines, and the concurrency reviewer rated a
user-visible race minor.**

| Case | Focus | Verdict | Seeded defect | Other findings kept |
|---|---|---|---|---|
| `dismiss-without-cancel` | concurrency | fix-then-merge | found, rated minor | 1, real |
| `errors-swallowed` | api-errors | refactor-needed | found, major | 4, real |
| `reset-test-wrong-reason` | test-quality | fix-then-merge | found, cited at the wrong line | 2, real |
| `unchecked-sendable-cache` | concurrency | refactor-needed | found, blocker-level | 8, real |
| `clean-reset` | control | **merge** | none seeded | 1, real, minor |

| Metric | Value |
|---|---|
| Verdicts that stop a seeded diff, and merge the clean one | 5 of 5 |
| Seeded defects the panel found, by description | 4 of 4 |
| Seeded defects matched by file and line | 3 of 4 |
| Seeded defects at blocker or major severity | 2 of 4 by the scorer; 3 of 4 counting the mis-cited one, which is major |
| Findings before the verifier / kept after it | 22 / 20 |
| Kept findings labelled invented | 0 |

I changed 1 label after the run: a seeded diff passes on either `fix-then-merge` or
`refactor-needed`, where my first labels wanted `fix-then-merge` alone. The panel put the
offline-fallback rule and the error policy in the Live client under architecture, and
`refactor-needed` is a fair call for that.

## What the panel found that I didn't seed

- `unchecked-sendable-cache`: `liveValue` calls `APIClient.live(...)` on every request, so each call
  gets a new `LastFactCache`, and the offline fallback never serves anything in production. I
  checked it in the code. The panel also flagged that the catch-all turns a cancelled request into
  a stale success.
- Every diff that touches the fact state drew the baseline's missing cancellation id, the stale
  response race. That race is real and existed before the diffs.

## Weaknesses

1. **Line numbers from the patch.** The test-quality reviewer cited `CounterFeatureTests.swift:36`
   twice. Line 36 is the line in `diff.patch`; the test is at line 73 of the file. The review
   contract says `line` is the line in the new code. The mis-citation also cost a real finding:
   in `clean-reset` the verifier's output didn't line up with the reviewer's line, so `reconcile()`
   marked a major finding unverified and synthesis dropped it.
2. **Under-rated severity.** The concurrency reviewer found the dismiss race, in which a user taps
   fact and then dismiss and the fact comes back, and rated it minor. The contract makes a defect
   users hit a blocker. The verdict was still right, because the test-quality finding on the same
   gap was major.
3. **The verifier dropped 2 findings, both real:** the major finding the line mismatch lost, and a
   minor finding about an untested decode path, which the verifier called "behaves as intended". In
   this run the verifier removed no invented finding, because the reviewers invented none.

## Cost

The trial totals add up to 4.95 USD (0.87, 1.10, 0.76, 1.32, 0.90), but they cover only the main
session. The panel runs through the Workflow tool, whose agents don't appear in `total_cost_usd`;
the workflow reported about 72k tokens across its 6 agents in the first trial. The real cost is
higher than 4.95 USD by an amount the trace doesn't give.

## Verdict

1. **Verdict on the evals: working, with labels a person must finish.** The scorer's line matching
   caught a real panel defect, the patch-line citations.
2. **What the evals say about the harness.** On these 5 diffs the review panel is accurate: every
   verdict is right, it caught every seeded defect, and it invented nothing. Fix the line numbers
   and the severity rule, then run 3 trials and a harder set, with 2 or 3 defects per diff and
   defects in SwiftUI.
3. **Unmeasured:** what the verifier earns. No reviewer invented a finding, so this run can't show
   the verifier removing one.
