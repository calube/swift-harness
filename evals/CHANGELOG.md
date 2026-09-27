# Eval changelog

## 2026-09-27

- **`ship` and `build` routing, held-out** (40 independent cases × 3): `build` 1.00/1.00, `ship`
  1.00 precision and 0.93 recall, 0 wrong loads in 120 trials. Both misses read the spec on turn 1
  and hit the 1-turn cap. 7.33 USD.
- **`review-accuracy` re-run after the source-line fix** (4 of 5 cases, cost cap): every seeded
  defect matches by file and line, 3 of 3, up from 3 of 4; 0 findings unmatched at verify. The
  dismiss race is still `major`, not `blocker`, and the clean control flipped to `fix-then-merge`
  on a race that predates its diff: 3 of 4 verdicts right.

## 2026-09-26

- **First `failure-modes` run,** no model: `runner/faults.mjs` and 11 cases in `faults/`. 10 of 11
  pass; the 1 false GREEN is a mismatched Xcode pin, which only `doctor` reports.
- **First `guard-conformance` run, hook decisions only:** `runner/hooks.mjs` and 51 payloads in
  `corpora/hooks.json`. Denies 15 of 15, controls 15 of 15, evasions 12 of 21; Bash writes get
  around the file and plan-state guards. See `results/2026-09-26-no-model-suites/summary.md`.
- **Routing round 4** for `bootstrap`, `design`, `plan`, `prose` and `status`: 1.00 precision
  and 1.00 recall for each on 40 independent held-out cases, 40 of 40 at pass^3. The cost cap cut
  the tuning run at 155 of 180 trials. See `results/2026-09-26-routing-round-4/summary.md`.
- **Added `runner/stage_plugin.sh`,** which stages `plugin/` with the cases inside it, since
  `claude plugin eval` no longer finds cases at the repo root.
- **`test-gate` round 3:** description v2 scores precision 1.00 and recall 0.97 (29 of 30) on
  an independent held-out set, and 1.00/1.00 on the round-1 and round-2 regression set. `tdd` holds
  1.00/1.00. See `results/2026-09-26-test-gate-round-3/summary.md`.
- **First live session pair:** `test-gate` `hollow-test-before-ready` scored 1.00 with the plugin
  and 0.50 without. `tdd` `decrement-floors-at-zero` passes both arms.
- **The report-seen session graders read swiftgate's run history** (`.harness/runs/history.jsonl`)
  instead of matching pretty-printed JSON in the trace. The old `swiftgate-red-seen` missed a real
  RED that the agent had printed through a `python3` filter.

- **Added round-2 routing cases:** 18 tuning cases for fixing and judging tests, and 32 held-out
  cases that an independent agent wrote before the description fix. On the old descriptions, the
  tuning cases scored `tdd` recall 0.40 and `test-gate` recall 0.33.
- **`routing.mjs` takes `--round`,** and each case carries a `round-N` tag.
- **Added the `test-gate` session case** `hollow-test-before-ready`, with its scaffold
  `sampleapp-hollow-test.sh`. Its judge rubric passed a good synthetic transcript 3 of 3 and failed
  4 bad ones 0 of 3. It hasn't run live.
- **Planted precision breaks:** a bait sentence moved nothing (0 of 16 wrong loads), and the
  near-misses caught a description that claimed its neighbours' jobs (6 of 8 wrong loads). See
  `results/2026-09-26-routing-fix/summary.md`.
- **Result of the description fix:** held-out `tdd` recall went from 0.67 to 1.00. On the
  independent set, `test-gate` recall is 0.88. Precision is 1.00 throughout.

- **Added 120 routing cases** for the 6 foundation skills. `evals/runner/seed_routing.mjs` writes
  them, with a 60/40 split by request. Added `evals/runner/routing.mjs`, which scores precision,
  recall, a confusion table and pass^k from kept traces, and `routing_test.mjs`.
- **The routing scaffold now carries a change in progress** (`evals/scaffold/sampleapp-with-change.sh`):
  a feature branch with 1 commit and 1 staged edit. On the plain scaffold, "Would you merge this
  diff" failed 2 of 3 because no diff existed. After the fix: 3 of 3.
- **Routing cases run at `max_turns: 1`,** down from 2, and the template case moved from 4 to 2.
  All 136 skill loads in the first 162 trials came in turn 1. Turn 2 only spawned subagents.
  Mean cost per run: 0.107 USD before, 0.055 after, with no change in any grade.
- **Loosened the `tdd` rubric** `red-then-green` to accept any test runner's RED and GREEN, with
  the user's approval. On synthetic transcripts it passes 2 of 2 good runs and fails 3 of 3 bad
  runs. The old rubric also passed the plugin-off good transcript 3/3, so the judge wasn't
  holding runs to the word "swiftgate". The next `tdd` session run owes a proof on real runs.
- **Result:** held-out recall and precision 1.00 for 5 of 6 skills. `tdd` recall is 0.67.
  See `results/2026-09-26-routing-foundation/summary.md`.

## 2026-09-25

- **Added** the runner-spike cases `routing/tdd/add-test-for-reducer` and
  `skills/tdd/decrement-floors-at-zero`, and the shared scaffold `evals/cases/_scaffold/sampleapp.sh`.
- **Scaffold moved inside each case as a link.** The runner refused a `scaffold_script` path
  outside the case directory. Runs before: 0 of 2 started. After: 2 of 2.
- **Scaffold seeds `swiftgate` into the scratch `HOME`.** Without it, every run started a cold gate
  build and ran with the hooks off. After the fix, the SessionStart "warming up" context appeared in
  0 of 1 runs, down from 2 of 2.
- **Execution fields moved from `case.yaml` to `prompt.md` frontmatter.** The runner ignored them in
  `case.yaml` when `prompt.md` existed. `maxTurns` went from 10 (the default) to the case's 4.
- **Tightened routing graders** to match the skill id `"skill":"swift-harness:tdd"`, not any input
  containing `tdd`. Score before and after on the spike run: 1/1 and 1/1. The old match also passed
  a `test-gate` call whose args mention tdd.
- **Replaced `swiftgate-test-ran` with `swiftgate-red-seen`** on the `tdd` case. The old grader
  matched the command text and passed run 5, where every `swiftgate` call came back BLOCKED. The
  new grader requires a RED `--json` verdict: it fails run 5 and passes a synthetic RED report.
- **Added the rule corpora** for `prose` (36 cases), the `det.*` lint rules (41) and the `arch.*`
  rules (27), generated by `evals/runner/seed_corpora.mjs` and scored by `evals/runner/corpus.mjs`.
  The generator refuses a seed whose edit anchor matches 0 times or more than once.
- **Added the label kind `evasion`** next to `positive`, `near-miss` and `clean`. It reports recall
  apart from positives and has no pass bar, as `suites.md` sets out for evasions.
- **Fixed 6 corpus cases that failed for the case's own reasons.** Before: 17 mismatches. After:
  12, counted before I added the 5 `wild` near-misses from the `docs/` audit. The fixes:
  - a jargon seed also planted the number word `two`;
  - a test-plan bullet read `` `test-…` ``, where `gate/Fixtures/design/valid.md` uses bare `test-…`;
  - a test-support module depended on the module that depended on it;
  - 2 vendor seeds had no package declared;
  - 2 test-support seeds lacked their `kind = "test-support"` declaration.

  The bullet fix removed an `em-dash` false positive, so it raised the gate's score. The canonical
  form in the fixture shows that I wrote the old case wrong, not that the gate was right.
- **Added the thin runner** `evals/runner/session.mjs`, with `frontmatter.mjs` and
  `session_test.mjs`. Moved the `tdd` case to `evals/sessions/` as `task.md`, and the shared
  scaffold to `evals/scaffold/`. The scaffold now writes the repo's `.gitignore` into the copy.
- **Added the `hidden-floor-test` grader** to the `tdd` case. It fails the baseline app (RED) and
  passes the fixed one (GREEN).
- **Marked `swiftgate-red-seen` as `with-only`.** The without arm can't know `swiftgate` exists.
  Without arm score on run 2: 0.50 before, 0.67 after. This change lowers the harness's delta.
- **Added `tests/review_orchestration_test.mjs`:** 6 orchestration cases for `review.js`, the only
  workflow whose `components.md` cases had no test. Each case failed on a planted break before it
  counted. Coverage for `review.js`: 0 of 3 listed cases before, 3 of 3 after.
