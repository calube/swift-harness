# ADRs

Architecture decision records, numbered and never renumbered. Each is referenced elsewhere by
number and title, never by number alone. Each opens with its status, checked against the code at the freeze tag
`harness-freeze-2026-10-05`.

| ADR | Title | Status | Summary |
|---|---|---|---|
| [0001](0001-review-severity-for-standards-violations.md) | Review severity for standards violations | Built | Review findings carry a `kind`; a standards violation is verified by its cited rule, not by a reproduced failure |
| [0002](0002-consumer-plugin-in-plugin-dir.md) | Consumer plugin lives in `plugin/` | Built | Consumers install only `plugin/`; contributor docs stay at the repo root |
| [0003](0003-ship-may-skip-the-design-step.md) | Ship may skip the design step | Built | A preset with `design_tier = "none"` builds from a 1-page spec and a surface commit |
| [0004](0004-proof-and-mutation-may-run-once-in-the-final-gate.md) | Proof and mutation may run once, in the final gate | Built | `task_proof = "final"` moves prove and mutate from each task gate to the final `ready` gate |
| [0005](0005-simulator-qa-drives-agent-device.md) | Simulator QA drives agent-device | Built | A pinned `agent-device` drives the simulator; kept flows become XCUITest |
| [0006](0006-profiling-wraps-xctrace-report-only-first.md) | Profiling wraps xctrace, and reports before it blocks | Accepted, not built | Profiling would wrap xctrace and `footprint` itself and stay report-only; no code exists |
| [0007](0007-jev-is-an-opt-in-second-judge-backend.md) | Jev is an opt-in second judge backend | Built | Jev answers behind the judge seam when a repo opts in; it may block, and Claude writes the reason |
| [0008](0008-simulator-qa-layered-validation.md) | Simulator QA validates in layers, and keeps flows in XCUITest | Built; 2 parts opt-in per app | Batch flows serve 1 run, kept flows stay XCUITest, 1 recording at a time, 2 offline flow rules |

See [`../index.md`](../index.md) for the full doc router.
