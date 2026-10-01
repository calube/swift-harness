# Designs

One file per design doc. Status here is a summary; each doc's own RESUME header is canonical.

| Design | Status | Covers |
|---|---|---|
| [2026-09-24-swift-harness-foundation-design.md](2026-09-24-swift-harness-foundation-design.md) | Built | Sub-project 1 (Foundation): `swiftgate`, standards, testing playbook, hooks, bootstrap, core skills |
| [2026-09-25-design-plan-workflows-design.md](2026-09-25-design-plan-workflows-design.md) | Approved; plan in [`../plans/2026-09-25-design-plan-workflows-plan.md`](../plans/2026-09-25-design-plan-workflows-plan.md) | Sub-project 2: `/swift-harness:design` and `/swift-harness:plan` workflows |
| [2026-09-26-build-executor-design.md](2026-09-26-build-executor-design.md) | Approved; decisions in [`../handoffs/2026-09-26-subproject-5-brainstorm-decisions.md`](../handoffs/2026-09-26-subproject-5-brainstorm-decisions.md) | Sub-project 5: `/swift-harness:build`, `/swift-harness:ship` and build presets |
| [2026-09-27-fast-modes-design.md](2026-09-27-fast-modes-design.md) | Approved; plan in [`../plans/2026-09-27-fast-modes-plan.md`](../plans/2026-09-27-fast-modes-plan.md) | Surface commits and `surface-check`, a sprint skill, a design-free ship path |
| [2026-09-27-speed-research-coverage-design.md](2026-09-27-speed-research-coverage-design.md) | Approved; tasks in the sub-project 2 hardening wave | Where each ship speed research change lives; host-compiled views and a stale-session check |
| [2026-09-28-simulator-qa-design.md](2026-09-28-simulator-qa-design.md) | Approved 2026-09-28; decision record [ADR 0005](../adrs/0005-simulator-qa-drives-agent-device.md) | Sub-project 3: `swiftgate sim`, dependency scenarios, the QA skill driving `agent-device`, screenshot and accessibility-tree evidence |
| [2026-09-28-agentic-profiling-design.md](2026-09-28-agentic-profiling-design.md) | Approved 2026-09-28; decisions in its §2 and §12; plan in [`../plans/2026-09-28-agentic-profiling-plan.md`](../plans/2026-09-28-agentic-profiling-plan.md) | Sub-project 4: `swiftgate profile` and `leaks` over xctrace and `footprint`, Simulator only, report-only findings |
| [2026-09-30-jev-judge-backend-design.md](2026-09-30-jev-judge-backend-design.md) | Approved 2026-09-30; decisions in its §12; decision record [ADR 0007](../adrs/0007-jev-is-an-opt-in-second-judge-backend.md); plan in [`../plans/2026-09-30-jev-judge-backend-plan.md`](../plans/2026-09-30-jev-judge-backend-plan.md) | TypeSafe's Jev as an opt-in second backend behind the judge seam, blocking on its own at the block threshold (the block calibration was removed on 2026-09-30); `swiftgate judge ask`; `swiftgate judge bench`, comparing pinned Sonnet 5.5 with pinned Jev |
| [2026-09-30-harness-telemetry-design.md](2026-09-30-harness-telemetry-design.md) | Draft 2026-09-30; the user's 4 decisions in its §14; plan in [`../plans/2026-09-30-harness-telemetry-plan.md`](../plans/2026-09-30-harness-telemetry-plan.md) | Local, on-by-default telemetry for self-improvement: gate runs, steps and every test result, hooks, caches, halts and transcript token counts as `HarnessEvent` kinds; `swiftgate events list\|summary\|ingest`; copy-up to main on worktree removal |

See [`../index.md`](../index.md) for the full doc router.
