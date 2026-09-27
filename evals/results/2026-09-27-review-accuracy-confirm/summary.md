# `review-accuracy` confirming run after the severity, dedupe and pre-existing fix, 2026-09-27

`/swift-harness:review` on all 5 seeded diffs, 1 trial each, `claude-opus-5-5`, harness at `0a99c70`.
Merge `42a6f53` shipped the fix: the verifier applies contract severity, synthesis merges nearby findings, and
defects that predate the diff go to a `preExisting` section that never counts toward the verdict.
`evals/runner/review_accuracy.mjs` now scores that section, counts `review.json`'s `unmatched`
list and reports blocker recall apart from blocker-or-major recall.

**Result: 5 of 5 verdicts right, 5 of 5 seeded defects found and kept at blocker or major, 0
invented. The dismiss race now comes back a `blocker`. `clean-reset` was never clean: its reset
handler adds a real race, so I relabelled it a seeded defect. I now freeze review-accuracy, per
the user's rule. It has no clean control until a clean diff replaces `clean-reset`.**

| Case | Verdict | Seeded defect | Severity of the matching findings | Kept | Pre-existing |
|---|---|---|---|---|---|
| `clean-reset` | fix-then-merge | reset leaves the request running (relabelled) | blocker, minor | 2 | 0 |
| `dismiss-without-cancel` | fix-then-merge | dismiss leaves the request running | **blocker**, major, major | 4 | 0 |
| `errors-swallowed` | refactor-needed | failure becomes a fake fact | blocker, blocker, major, major, minor | 5 | 1 |
| `reset-test-wrong-reason` | fix-then-merge | reset test starts at zero | major | 2 | 0 |
| `unchecked-sendable-cache` | refactor-needed | unsynchronized cache | major | 7 | 0 |

| Metric | First run | Re-run | This run |
|---|---|---|---|
| Right verdicts | 5 of 5 | 3 of 4 | 5 of 5 |
| Seeded defects matched by file and line | 3 of 4 | 3 of 3 | 5 of 5 |
| At blocker or major | 2 of 4 | 3 of 3 | 5 of 5 |
| At blocker | not counted | 1 of 3 | 3 of 5 |
| Findings before the verifier / kept | 22 / 20 | 16 / 14 | 23 / 20 |
| Kept findings invented | 0 | 0 | 0 |
| Unmatched at verify | not counted | 0 | 0 |

The first 2 columns score `clean-reset` as a clean control, and this column scores it as seeded.
Under the old label this run scores 4 of 5 verdicts right.

## The `clean-reset` relabel

I wrote the case as a clean control: its diff adds `resetButtonTapped`, which sets `count` to 0
and `fact` to nil. Every run flagged the same thing at `CounterFeature.swift:67`: a reset during a
fact request leaves `isLoadingFact` true and doesn't cancel the request, so the late response
puts a stale fact back on screen. I labelled that `known` after the first run and called it the
baseline's missing cancellation id. It isn't: the diff adds lines 66 to 70, and a user who taps
Fact then Reset sees the bug. The contract counts a finding on added lines as introduced, so
`preExisting` was right to leave it out. The panel was right; my label was wrong. In the first run
the panel rated it `minor`, so that run's `merge`, which I scored right, was wrong.

## What else the run shows

- **Dedupe.** `dismiss-without-cancel` still keeps 3 findings at line 67: the `C3` race, a
  duplicate of it with no `rule`, and a `P9` test gap. The duplicate differs only in its missing
  rule; the test gap is a separate finding. Both survive because synthesis keys on category.
- **Severity on the cache race.** The `unchecked-sendable-cache` data race came back `major`,
  where the first run rated it blocker-level. Its verdict is still right.
- **Telemetry.** `review.json` names a telemetry file in 3 of 5 trials; `clean-reset` and
  `dismiss-without-cancel` have no `telemetry` key. The kept output has no telemetry file, because
  the review cases' `keep` pattern left it out. I added `review-telemetry.json` to it for the next
  run.
- **Pre-existing.** 1 finding in `errors-swallowed` went to the new section. Synthesis filed no
  seeded defect there.

## Cost

5.31 USD for 5 trials (1.06, 0.89, 1.30, 0.89, 1.17), main session only, within the 9 USD cap.
The Workflow agents' cost isn't in that figure, and this run kept no telemetry file to supply it.
Wall time 429 to 607 seconds a trial, except `clean-reset` at 1,577 seconds, which the kept
output doesn't explain.

## Verdict

1. **Verdict on the evals: working.** The scorer caught a label error that 2 earlier runs hid.
   Review-accuracy has no clean control now, so it can't measure a false `fix-then-merge`. A
   replacement needs a diff whose reset also cancels the request, proved clean by hand first.
2. **What the evals say about the harness.** On these 5 diffs the panel reaches the right verdict,
   finds every seeded defect at blocker or major, and invents nothing. Under the freeze,
   nothing here reopens a fix wave: no verdict is wrong, and the dismiss race is a blocker. The
   `telemetry` key missing from 2 of 5 reports goes to swift-harness-fe.
3. **Unmeasured:** false positives on a clean diff, and every case beyond 1 trial.
