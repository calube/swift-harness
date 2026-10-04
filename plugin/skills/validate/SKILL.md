---
name: validate
description: This skill should be used to produce ready-for-review evidence for a swift-harness Swift change — run swiftgate check --tier ready, read the run report, and emit a paste-ready PR body block with verdicts, test counts, durations and anything not run. Use when the user says "validate", "prove this is ready", "evidence for the PR", "write the testing section", "fill in how this was tested", "summarise the tests for the PR description", or before opening or marking a pull request ready.
---

# Validate

Thin by design: `swiftgate check --tier ready` is the judge; this skill turns its report into
evidence. It never re-runs a check another way and never reports a step it didn't see pass.

`SG="${CLAUDE_PLUGIN_ROOT}/bin/swiftgate"`. Pass `--base <ref>` when the branch doesn't target
`origin/main`.

## Steps

1. Run `"$SG" check --tier ready --json` in the foreground. It takes minutes (simulator tiers).
2. From the JSON read `runID`, `verdict`, `durationMilliseconds`, `tiers[]` (`tier`, `verdict`,
   `durationMilliseconds`, `testCounts`), `findings[]` and `allowances[]`. The same report is saved
   at `.harness/runs/<runID>/report.json` beside the run's logs and result bundles.
3. If `verdict` is `RED`, stop: list the gating findings as `file:line rule — message` and hand off
   to `/swift-harness:test-gate` or `/swift-harness:tdd` to fix them. Don't write a PR block for a
   RED run.
4. If `verdict` is `BLOCKED`, stop: run `"$SG" doctor` and report what the environment needs.
5. If `GREEN`, write the block below. Every number comes from the report; `swiftgate.not-run`
   findings go under "Not run", never under a passing tier; a tier with a
   `swiftgate.nothing-selected` note ran no tests, so say so instead of listing it GREEN. List
   any `swiftgate.budget` or `swiftgate.scopes-fallback` finding under "Notes". T0 has no
   `testCounts`, so its Tests cell is always "—".
6. Add simulator QA from the runs `/swift-harness:qa` or a `validate` stage printed for this
   change, never from a run of your own. For each flow, read `.harness/runs/<runID>/sim/report.json`,
   whose `sim/report.json` keys `runID`, `verdict` and `stepCount` fill 1 "Simulator QA" row. For
   a `qa run`, read `.harness/runs/<runID>/qa/report.json`: its `qa/report.json` keys `runID`,
   `final` and `rows[]`, and each row's keys `requirement`, `layer`, `check`, `result` and
   `evidence` fill 1 row per validation row, with its evidence paths relative to that run. With
   no QA run for this change, or a preset whose `sim_qa` is `off`, list it under "Not run" as
   `simulator QA: <reason>`.

```markdown
### Validation

`swiftgate check --tier ready` — **GREEN** in <total> (run `<runID>`)

| Tier | Verdict | Tests | Time |
|---|---|---|---|
| T0 static | GREEN | — | <duration> |
| T1 host | GREEN | <passed> passed, <skipped> skipped | <duration> |
| T2 simulator | GREEN | … | … |
| T3 flows | GREEN | … | … |
| Simulator QA | <verdict> | <stepCount> steps | run `<runID>` |

| Done when | Layer | Check | Result | Evidence |
|---|---|---|---|---|
| `<requirement>` | <layer> | `<check>` | <result> | <evidence paths>, run `<runID>` |

- Red/green proof, stress and per-test reach: <the `changed-tests.summary` finding messages>
- Diff coverage: <the `coverage.summary` finding message, if the report has one>
- Waivers: <rule × count from allowances, or "none">
- Not run: <each swiftgate.not-run message, simulator QA with its reason when it didn't run, or "nothing">
- Notes: <budget or scope notes, or omit the line>
```

7. Show the block, then ask with `AskUserQuestion` whether to add it to the PR description (only
   if a PR exists) or leave it for them to paste. Never open a PR from this skill.

A later sub-project adds before/after profiling here; until then the block claims only what the
gate and simulator QA ran.
