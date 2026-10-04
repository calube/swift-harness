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
| Seeing a build run as 1 page (`swiftgate report --html`, `swiftgate view`), or emitting a span with `swiftgate events span` | [`run-viewer.md`](run-viewer.md) |

Your repository's `docs/index.md` routes its own docs (designs, plans, ADRs); this page doesn't.
