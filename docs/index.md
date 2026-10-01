# swift-harness docs

The one routing surface for this repo's docs. Every doc is reachable from here, by a link on this
page or through an area index below.

## If you're… → Read

| If you're… | Read |
|---|---|
| New to the repo, or an agent starting a session | [`../AGENTS.md`](../AGENTS.md), then this file |
| Seeing everything the harness does, with the command behind each capability | [`capabilities.md`](capabilities.md) |
| Writing or reviewing Swift code against the harness's rules | [`plugin/docs/standards.md`](../plugin/docs/standards.md) |
| Writing or reviewing tests (tiers, red/green, snapshots, flake stress) | [`plugin/docs/testing-playbook.md`](../plugin/docs/testing-playbook.md) |
| Turning on the test-quality judge, choosing Claude or Jev, or measuring backends with `judge bench` | [`plugin/docs/testing-playbook.md`](../plugin/docs/testing-playbook.md) §5.4, then the [judge benchmark summary](../evals/results/2026-09-30-judge-benchmark/summary.md) |
| Auditing the judge's calls and decisions, or where the judge runs (`judge events`) | [`plugin/docs/judge-audit.md`](../plugin/docs/judge-audit.md) |
| Working on or debugging a Claude Code hook | [`plugin/docs/hooks.md`](../plugin/docs/hooks.md) |
| Changing what a reviewer or verifier returns | [`plugin/docs/review-contract.md`](../plugin/docs/review-contract.md) |
| Moving a file into or out of the shipped plugin | [ADR 0002](adrs/0002-consumer-plugin-in-plugin-dir.md): consumers get `plugin/`, contributors the rest |
| Checking what was verified end-to-end on `examples/SampleApp` | [`e2e-report.md`](e2e-report.md) |
| Planning or running evals of the harness and `swiftgate` (objectives, suites, eval apps) | [`../evals/README.md`](../evals/README.md), then [`../evals/runbook.md`](../evals/runbook.md) and the current eval handoff [`handoffs/2026-09-26-evals-routing-foundation.md`](handoffs/2026-09-26-evals-routing-foundation.md) |
| Fixing what the first interview trial run of `/swift-harness:ship` found | [`handoffs/2026-09-27-interview-trial-run-1.md`](handoffs/2026-09-27-interview-trial-run-1.md) |
| Researching why `/swift-harness:ship` is too slow for a coding interview (trial run 2 evidence) | [`handoffs/2026-09-27-interview-trial-run-2.md`](handoffs/2026-09-27-interview-trial-run-2.md) |
| Looking up why a review-severity rule exists | [`adrs/README.md`](adrs/README.md) |
| Reading or extending a design (Foundation, design & plan workflows, …) | [`designs/README.md`](designs/README.md) |
| Picking up mid-build, or handing work to the next session | [`handoffs/2026-09-25-subproject-2.md`](handoffs/2026-09-25-subproject-2.md), today's queue [`handoffs/2026-09-28-day-queue.md`](handoffs/2026-09-28-day-queue.md), [`handoffs/2026-09-25-subproject-2-brainstorm-decisions.md`](handoffs/2026-09-25-subproject-2-brainstorm-decisions.md), [`handoffs/worker-brief.md`](handoffs/worker-brief.md), [`handoffs/subproject-2-interfaces.md`](handoffs/subproject-2-interfaces.md), [`handoffs/subproject-2-orchestrator-runbook.md`](handoffs/subproject-2-orchestrator-runbook.md), the sign-off review and its fix waves [`handoffs/subproject-2-review.md`](handoffs/subproject-2-review.md) |
| Building sub-project 2 (design & plan workflows): tasks, waves, merge points | [`plans/2026-09-25-design-plan-workflows-plan.md`](plans/2026-09-25-design-plan-workflows-plan.md) |
| Building sub-project 5 (the build executor, `/build` and `/ship`): tasks, waves, merge points | [`plans/2026-09-26-build-executor-plan.md`](plans/2026-09-26-build-executor-plan.md), design [`designs/2026-09-26-build-executor-design.md`](designs/2026-09-26-build-executor-design.md), interfaces [`handoffs/subproject-5-interfaces.md`](handoffs/subproject-5-interfaces.md) |
| Building the fast modes (`surface-check`, `/sprint`): tasks, waves, merge points | [`plans/2026-09-27-fast-modes-plan.md`](plans/2026-09-27-fast-modes-plan.md), design [`designs/2026-09-27-fast-modes-design.md`](designs/2026-09-27-fast-modes-design.md), [ADR 0003](adrs/0003-ship-may-skip-the-design-step.md) |
| Building a spec in 1 session on 1 branch (`/swift-harness:sprint`), or changing what that skill does | [`plugin/skills/sprint/SKILL.md`](../plugin/skills/sprint/SKILL.md), its spec page format [`plugin/skills/sprint/references/spec-page.md`](../plugin/skills/sprint/references/spec-page.md), and `swiftgate sprint --help` |
| Tracing a ship speed research change to its design, ADR or plan task | [`designs/2026-09-27-speed-research-coverage-design.md`](designs/2026-09-27-speed-research-coverage-design.md), [ADR 0004](adrs/0004-proof-and-mutation-may-run-once-in-the-final-gate.md) |
| Designing or building simulator QA (`swiftgate sim`, scenarios, the QA skill) | plan [`plans/2026-09-28-simulator-qa-plan.md`](plans/2026-09-28-simulator-qa-plan.md), design [`designs/2026-09-28-simulator-qa-design.md`](designs/2026-09-28-simulator-qa-design.md), [ADR 0005](adrs/0005-simulator-qa-drives-agent-device.md) |
| Designing or building sub-project 4 (agentic profiling: `swiftgate profile`, `leaks`) | plan [`plans/2026-09-28-agentic-profiling-plan.md`](plans/2026-09-28-agentic-profiling-plan.md), design [`designs/2026-09-28-agentic-profiling-design.md`](designs/2026-09-28-agentic-profiling-design.md), [ADR 0006](adrs/0006-profiling-wraps-xctrace-report-only-first.md) |
| Designing or building the Jev judge backend (`[judge] backend = "jev"`, `swiftgate judge ask`, the `judge bench` benchmark) | plan [`plans/2026-09-30-jev-judge-backend-plan.md`](plans/2026-09-30-jev-judge-backend-plan.md), design [`designs/2026-09-30-jev-judge-backend-design.md`](designs/2026-09-30-jev-judge-backend-design.md), [ADR 0007](adrs/0007-jev-is-an-opt-in-second-judge-backend.md), interfaces [`handoffs/jev-judge-interfaces.md`](handoffs/jev-judge-interfaces.md) |
| Designing or building harness telemetry (`.harness/events/`, `swiftgate events`, `build halt\|resume`) | plan [`plans/2026-09-30-harness-telemetry-plan.md`](plans/2026-09-30-harness-telemetry-plan.md), design [`designs/2026-09-30-harness-telemetry-design.md`](designs/2026-09-30-harness-telemetry-design.md) |
| Hardening sub-project 2 (plan-lock cache, telemetry, rule index, host-compiled views, stale sessions): tasks, waves, merge points | [`plans/2026-09-27-subproject-2-hardening-plan.md`](plans/2026-09-27-subproject-2-hardening-plan.md) |
| Understanding how the Foundation build was sequenced | [`plans/2026-09-24-foundation-plan.md`](plans/2026-09-24-foundation-plan.md) — temporary: `docs/plans/` is committed only until sub-project 2's own (uncommitted) ledger exists |

## The framework in 30 seconds

- **Target:** SwiftUI, iOS 18+, Swift 6 language mode. Xcode 26.2 / Swift 6.2.3, pinned;
  `swiftgate doctor` blocks on a mismatch.
- **Shape:** a thin app target plus local Swift packages. Core packages import no UI framework, run
  under `swift test` on the Mac, and reach every source of nondeterminism through `@Dependency`.
- **TCA 1.x is the default architecture:** `@Reducer`, `@ObservableState` and `TestStore`. TCA 2.0
  is a subscriber-only beta; don't use it.
- **Every service is a `FooClient`/`FooClientLive` pair.** IO and vendor SDKs live only in `*Live`
  modules, and only the app target imports those. No singletons.
- **`swiftgate` is the single enforcement point.** A hook, skill or git hook that re-implements a
  check is a defect.
- **Escape hatches carry a reason:** `@unchecked Sendable`, `try!`, `as!`, `fatalError` and any
  suppression need a same-line `swiftgate:allow <rule> — <reason>`.
- **Log and trace through `LogClient`/`TracingClient` only**, with privacy-tagged attributes.
- **Comments carry only what the code can't give back:** no restated code, history, local paths,
  codenames or line numbers.
- Review findings carry `kind` (`defect` | `standards-violation`), set out in
  [ADR 0001](adrs/0001-review-severity-for-standards-violations.md).
