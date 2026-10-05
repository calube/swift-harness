# Designs

1 file per design. Each design opens with a status line checked against the code at the freeze tag
`harness-freeze-2026-10-05`, and an "In brief" summary. The bodies are the designs as approved; short notes mark
where the shipped code differs. The plans that built these designs live only in the freeze tag.

| Design | Status | Summary |
|---|---|---|
| [Foundation](2026-09-24-swift-harness-foundation-design.md) | Built | `swiftgate`, the standards, the testing playbook, hooks, bootstrap and the core skills |
| [Design and plan workflows](2026-09-25-design-plan-workflows-design.md) | Built | `/swift-harness:design` turns a request into an evidence-backed design; `/swift-harness:plan` turns it into scheduled tasks |
| [Build executor](2026-09-26-build-executor-design.md) | Built | `/swift-harness:build`, `/swift-harness:ship` and named presets turn a plan or a spec file into merged, gated code |
| [Fast modes](2026-09-27-fast-modes-design.md) | Built | Surface commits with `surface-check`, `/swift-harness:sprint`, and ship without a design step |
| [Ship speed research coverage](2026-09-27-speed-research-coverage-design.md) | Built | Maps each ship speed change to what carries it; adds the `arch.ui-host-compiled` rule and a stale-session doctor check |
| [Simulator QA](2026-09-28-simulator-qa-design.md) | Built | `swiftgate sim` leases a simulator, records screenshot and accessibility-tree evidence, and judges it; kept flows become XCUITest |
| [Agentic profiling](2026-09-28-agentic-profiling-design.md) | Designed, not built | A `swiftgate profile` and `leaks` over xctrace and `footprint` on the Simulator, report-only; no code exists |
| [Jev judge backend](2026-09-30-jev-judge-backend-design.md) | Built | TypeSafe's Jev as an opt-in second judge beside Claude, with a cascade to Claude, `judge ask` and `judge bench` |
| [Harness telemetry](2026-09-30-harness-telemetry-design.md) | Built; the code has since added more event kinds | Local, on-by-default typed events for gate runs, tests, hooks, caches, halts and token use; `swiftgate events` |
| [Brownfield profile](2026-10-03-brownfield-profile-design.md) | Built | Runs the harness in a repository it doesn't own: `discover`, `run`, the `slice`, `merge` and `final` tiers, no files in the tree |
| [Run viewer](2026-10-03-run-viewer-design.md) | Built | 1 page per build run: `swiftgate report --html` writes it, `swiftgate view` serves it live |
| [Simulator QA layered evidence](2026-10-04-simulator-qa-layered-evidence-amendment.md) | Partly built: validation rows, `swiftgate qa`, flow rules, video and logs shipped; bootstrap doesn't stamp the typed id module or keep-always attachments | Plans each requirement's checks in 4 layers before the code exists, runs them after each merge, and records evidence beside each pass |

See [`../index.md`](../index.md) for the full doc router.
