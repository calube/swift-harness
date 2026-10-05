# swift-harness docs

The one routing surface for this repo's docs. Every doc is reachable from here, by a link on this
page or through an area index below.

Status: the harness froze at the tag `harness-freeze-2026-10-05`, with all 7 practice apps passing the
brownfield one-shot. The [practice-app results](results/2026-10-05-practice-app-results.md) list the open
follow-ups.

## If you're… → Read

| If you're… | Read |
|---|---|
| New to the repo, or an agent starting a session | [`../AGENTS.md`](../AGENTS.md), then this file |
| Seeing everything the harness does, with the command behind each capability | [`capabilities.md`](capabilities.md) |
| Seeing how the harness did on seven practice apps: pass rates, wall time, cost, what each failure taught, and the open follow-ups | [`results/2026-10-05-practice-app-results.md`](results/2026-10-05-practice-app-results.md) |
| Writing or reviewing Swift code against the harness's rules | [`plugin/docs/standards.md`](../plugin/docs/standards.md) |
| Writing or reviewing tests (tiers, red/green, snapshots, flake stress) | [`plugin/docs/testing-playbook.md`](../plugin/docs/testing-playbook.md) |
| Turning on the test-quality judge, choosing Claude or Jev, or measuring backends with `judge bench` | [`plugin/docs/testing-playbook.md`](../plugin/docs/testing-playbook.md) §5.4, then the [judge benchmark summary](../evals/results/2026-09-30-judge-benchmark/summary.md) |
| Auditing the judge's calls and decisions, or where the judge runs (`judge events`) | [`plugin/docs/judge-audit.md`](../plugin/docs/judge-audit.md) |
| Working on or debugging a Claude Code hook | [`plugin/docs/hooks.md`](../plugin/docs/hooks.md) |
| Reading what the harness records locally, the `swiftgate events` summary, or opting out with `[telemetry] enabled = false` | [`plugin/docs/telemetry.md`](../plugin/docs/telemetry.md) |
| Changing what a reviewer or verifier returns | [`plugin/docs/review-contract.md`](../plugin/docs/review-contract.md) |
| Moving a file into or out of the shipped plugin | [ADR 0002](adrs/0002-consumer-plugin-in-plugin-dir.md): consumers get `plugin/`, contributors the rest |
| Checking what the end-to-end run verified on `examples/SampleApp` | [`e2e-report.md`](e2e-report.md) |
| Planning or running evals of the harness and `swiftgate` (objectives, suites, eval apps) | [`../evals/README.md`](../evals/README.md), then [`../evals/runbook.md`](../evals/runbook.md) |
| Running multi-task work on the harness as an orchestrator: worktrees, workers, report checks, merges, gates and the lessons behind them | [`process/orchestrator-runbook.md`](process/orchestrator-runbook.md) |
| Working as a build worker on the harness: standing rules, known pitfalls and the report shape | [`process/worker-brief.md`](process/worker-brief.md) |
| Looking up why the harness made a decision | [`adrs/README.md`](adrs/README.md) |
| Reading or extending a design | [`designs/README.md`](designs/README.md) |
| Changing the core: `swiftgate`, standards, testing playbook, hooks, bootstrap and core skills | design [`designs/2026-09-24-swift-harness-foundation-design.md`](designs/2026-09-24-swift-harness-foundation-design.md), [ADR 0001](adrs/0001-review-severity-for-standards-violations.md) |
| Changing the design and plan workflows (`/swift-harness:design`, `/swift-harness:plan`) | design [`designs/2026-09-25-design-plan-workflows-design.md`](designs/2026-09-25-design-plan-workflows-design.md) |
| Changing the build executor (`/swift-harness:build`, `/swift-harness:ship`, presets) or its speed modes (surface commits, `surface-check`, `/swift-harness:sprint`, design-free ship) | design [`designs/2026-09-26-build-executor-design.md`](designs/2026-09-26-build-executor-design.md), [`designs/2026-09-27-fast-modes-design.md`](designs/2026-09-27-fast-modes-design.md), [`designs/2026-09-27-speed-research-coverage-design.md`](designs/2026-09-27-speed-research-coverage-design.md), [ADR 0003](adrs/0003-ship-may-skip-the-design-step.md), [ADR 0004](adrs/0004-proof-and-mutation-may-run-once-in-the-final-gate.md) |
| Building a spec in 1 session on 1 branch (`/swift-harness:sprint`), or changing what that skill does | [`plugin/skills/sprint/SKILL.md`](../plugin/skills/sprint/SKILL.md), its spec page format [`plugin/skills/sprint/references/spec-page.md`](../plugin/skills/sprint/references/spec-page.md), and `swiftgate sprint --help` |
| Checking a change in a running simulator (`/swift-harness:qa`), or writing a plan's validation checks | [`plugin/skills/qa/SKILL.md`](../plugin/skills/qa/SKILL.md), its validation worker brief [`plugin/skills/qa/references/validation-worker.md`](../plugin/skills/qa/references/validation-worker.md), and [`plugin/docs/simulator-qa.md`](../plugin/docs/simulator-qa.md); the build, sprint and ship `validate` stage that runs it under a preset's `sim_qa` is in the build loop's [validate stage](../plugin/skills/build/references/event-loop.md#validate-stage) |
| Changing simulator QA (`swiftgate sim`, `swiftgate qa`, scenarios, the QA skill, layered validation) | design [`designs/2026-09-28-simulator-qa-design.md`](designs/2026-09-28-simulator-qa-design.md), its amendment [`designs/2026-10-04-simulator-qa-layered-evidence-amendment.md`](designs/2026-10-04-simulator-qa-layered-evidence-amendment.md), [ADR 0005](adrs/0005-simulator-qa-drives-agent-device.md), [ADR 0008](adrs/0008-simulator-qa-layered-validation.md) |
| Picking up profiling, which is designed but not built: `swiftgate` has no `profile` or `leaks` command | design [`designs/2026-09-28-agentic-profiling-design.md`](designs/2026-09-28-agentic-profiling-design.md), [ADR 0006](adrs/0006-profiling-wraps-xctrace-report-only-first.md) |
| Changing the Jev judge backend (`[judge] backend = "jev"`, `swiftgate judge ask`, `judge bench`) | design [`designs/2026-09-30-jev-judge-backend-design.md`](designs/2026-09-30-jev-judge-backend-design.md), [ADR 0007](adrs/0007-jev-is-an-opt-in-second-judge-backend.md) |
| Changing harness telemetry (`.harness/events/`, `swiftgate events`, `build halt\|resume`) | design [`designs/2026-09-30-harness-telemetry-design.md`](designs/2026-09-30-harness-telemetry-design.md) |
| Changing the brownfield profile (a repository the harness doesn't own: `swiftgate discover`, `run`, the `slice`, `merge` and `final` tiers) | design [`designs/2026-10-03-brownfield-profile-design.md`](designs/2026-10-03-brownfield-profile-design.md) |
| Reading a build run as 1 page, offline or live (`swiftgate report --html`, `swiftgate view`, `swiftgate events span`) | [`plugin/docs/run-viewer.md`](../plugin/docs/run-viewer.md) |
| Changing the run viewer (span events, the `RunView` contract, the page and its modules) | design [`designs/2026-10-03-run-viewer-design.md`](designs/2026-10-03-run-viewer-design.md) |
| Looking for a finished plan or handoff | Check out the tag `harness-freeze-2026-10-05`; the docs tree keeps none |

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
