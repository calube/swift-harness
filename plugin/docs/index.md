# swift-harness reference docs

The docs the swift-harness plugin ships for app repositories that use it. Skills, agents and hooks
read them at runtime. In a session, the SessionStart context names this directory's absolute path
for the current install. The path changes between machines and plugin versions, so never write it
into a committed file.

| If you're… | Read |
|---|---|
| Writing or reviewing Swift code: module kinds, determinism, clients, errors, logging, SwiftUI, comments | [`standards.md`](standards.md) |
| Looking up a rule id from a `swiftgate` verdict, such as `det.date-init` or `A2` | [`standards.md` § Rule id index](standards.md#rule-id-index) |
| Writing or judging a test: tiers T0–T3, naming, red/green proof, snapshots, flows | [`testing-playbook.md`](testing-playbook.md) |
| Reading what a reviewer or verifier returned, or why a finding was dropped | [`review-contract.md`](review-contract.md) |
| Working out why a Claude Code hook denied, blocked or added context | [`hooks.md`](hooks.md) |
| Reading what the harness records locally (`swiftgate events`, `build halt\|resume`), or opting out | [`telemetry.md`](telemetry.md) |
| Checking flow files with `swiftgate qa lint`, or running a plan's validation rows with `qa run` and `qa adopt` | [`simulator-qa.md`](simulator-qa.md) |
| How `qa run` runs a `test:` row, once per check on a leased clone, and reads a runner that never launched | [`simulator-qa-test-rows.md`](simulator-qa-test-rows.md) |
| How `qa run` drives a flow row as 1 `agent-device batch`, and the qa.flow record it leaves | [`simulator-qa-flows.md`](simulator-qa-flows.md) |
| How T3 turns each kept XCUITest flow into a qa.flow record with its video | [`simulator-qa-kept-flows.md`](simulator-qa-kept-flows.md) |
| Judging a simulator run's steps with `swiftgate sim verify`, or ending it with `sim down` | [`simulator-qa-sim.md`](simulator-qa-sim.md) |
| Which controls `sim verify`'s accessibility rules judge, in an owned repository or a brownfield clone | [`simulator-qa-audit.md`](simulator-qa-audit.md) |
| Seeing a build run as 1 page (`swiftgate report --html`, `swiftgate view`), or emitting a span with `swiftgate events span` | [`run-viewer.md`](run-viewer.md) |
| Knowing when a saved report is final, or what a live page polls and calls not written yet | [`run-viewer-live.md`](run-viewer-live.md) |

Your repository's `docs/index.md` routes its own docs (designs, plans, ADRs); this page doesn't.
