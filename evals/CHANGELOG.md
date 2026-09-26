# Eval changelog

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
