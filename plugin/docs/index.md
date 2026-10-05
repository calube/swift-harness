# swift-harness reference docs

The reference docs the swift-harness plugin ships for the app repositories that use it. Find the
page for your question in the table below. Skills, agents and hooks read these pages at runtime. In a session, the SessionStart context names this directory's absolute path
for the current install. The path changes between machines and plugin versions, so never write it
into a committed file.

| If you're… | Read |
|---|---|
| Writing or reviewing Swift code: module kinds, determinism, clients, errors, logging, SwiftUI, comments | [`standards.md`](standards.md) |
| Looking up a rule id from a `swiftgate` verdict, such as `det.date-init` or `A2` | [`standards.md` § Rule id index](standards.md#rule-id-index) |
| Writing or judging a test: tiers T0–T3, naming, red/green proof, snapshots, flows | [`testing-playbook.md`](testing-playbook.md) |
| Testing a reducer's repeating timer effect on a `TestClock`, and the shapes of such a test that can't fail | [`testing-clock-effects.md`](testing-clock-effects.md) |
| Reading what a reviewer or verifier returned, or why a finding was dropped | [`review-contract.md`](review-contract.md) |
| Working out why a Claude Code hook denied, blocked or added context | [`hooks.md`](hooks.md) |
| Checking a run's judge calls and decisions, or why the judge blocked a change | [`judge-audit.md`](judge-audit.md) |
| Reading what the harness records locally (`swiftgate events`, `build halt\|resume`), or opting out | [`telemetry.md`](telemetry.md) |
| Checking flow files with `swiftgate qa lint`, or running a plan's validation rows with `qa run` and `qa adopt` | [`simulator-qa.md`](simulator-qa.md) |
| How `qa run` runs a `test:` row, once per check on a leased clone, and reads a runner that never launched | [`simulator-qa-test-rows.md`](simulator-qa-test-rows.md) |
| Bounding a `qa run` with `--deadline`, sending its JSON with `--output`, and which rows the final run takes after a fix carried another task | [`simulator-qa-run-bounds.md`](simulator-qa-run-bounds.md) |
| Proving validation rows red with `qa run --at-base`, a validation worker's `--prepared-by` run, the rows a later run reuses, and a task's rows before it merges | [`simulator-qa-at-base.md`](simulator-qa-at-base.md) |
| How `qa run` drives a flow row as 1 `agent-device batch`, and the qa.flow record it leaves | [`simulator-qa-flows.md`](simulator-qa-flows.md) |
| Writing a flow step for a gesture a selector alone doesn't drive, such as pull to refresh or a swipe | [`simulator-qa-flow-gestures.md`](simulator-qa-flow-gestures.md) |
| Writing a flow's `wait` and `is` steps: the input key each `wait` kind reads, and `qa.flow-kind-key` | [`simulator-qa-flow-steps.md`](simulator-qa-flow-steps.md) |
| Naming an element in a flow step: the selector keys `id`, `label`, `value` and `role`, whole-value matching, several terms and `||` alternatives | [`simulator-qa-flow-selectors.md`](simulator-qa-flow-selectors.md) |
| Rewriting a flow row its flow file kept red, with `qa run --requirement` and `qa adopt --repair` | [`simulator-qa-flow-repair.md`](simulator-qa-flow-repair.md) |
| How T3 turns each kept XCUITest flow into a qa.flow record with its video | [`simulator-qa-kept-flows.md`](simulator-qa-kept-flows.md) |
| Judging a simulator run's steps with `swiftgate sim verify`, or ending it with `sim down` | [`simulator-qa-sim.md`](simulator-qa-sim.md) |
| Which controls `sim verify`'s accessibility rules judge, in an owned repository or a brownfield clone | [`simulator-qa-audit.md`](simulator-qa-audit.md) |
| Seeing a build run as 1 page (`swiftgate report --html`, `swiftgate view`), or emitting a span with `swiftgate events span` | [`run-viewer.md`](run-viewer.md) |
| Knowing when a saved report is final, or what a live page polls and calls not written yet | [`run-viewer-live.md`](run-viewer-live.md) |
| Finding where the run viewer's reason for a red span, stopped task or halted build comes from | [`run-viewer-failures.md`](run-viewer-failures.md) |
| Reading the run viewer's Validation tab: which `qa run` results it keeps and how it links evidence | [`run-viewer-validation.md`](run-viewer-validation.md) |

Your repository's `docs/index.md` routes its own docs (designs, plans, ADRs); this page doesn't.
