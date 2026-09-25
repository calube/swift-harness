# swift-harness docs

The one routing surface for this repo's docs. Every doc is reachable from here, directly or through
one of the two area indexes below.

## If you're… → Read

| If you're… | Read |
|---|---|
| New to the repo, or an agent starting a session | [`../AGENTS.md`](../AGENTS.md), then this file |
| Writing or reviewing Swift code against the harness's rules | [`standards.md`](standards.md) |
| Writing or reviewing tests (tiers, red/green, snapshots, flake stress) | [`testing-playbook.md`](testing-playbook.md) |
| Working on or debugging a Claude Code hook | [`hooks.md`](hooks.md) |
| Checking what was verified end-to-end on `examples/SampleApp` | [`e2e-report.md`](e2e-report.md) |
| Looking up why a review-severity rule exists | [`adrs/README.md`](adrs/README.md) |
| Reading or extending a design (Foundation, design & plan workflows, …) | [`designs/README.md`](designs/README.md) |
| Picking up mid-build, or handing work to the next session | [`handoffs/2026-09-25-subproject-2.md`](handoffs/2026-09-25-subproject-2.md), [`handoffs/2026-09-25-subproject-2-brainstorm-decisions.md`](handoffs/2026-09-25-subproject-2-brainstorm-decisions.md), [`handoffs/worker-brief.md`](handoffs/worker-brief.md), [`handoffs/subproject-2-interfaces.md`](handoffs/subproject-2-interfaces.md) |
| Building sub-project 2 (design & plan workflows): tasks, waves, merge points | [`plans/2026-09-25-design-plan-workflows-plan.md`](plans/2026-09-25-design-plan-workflows-plan.md) |
| Understanding how the Foundation build was sequenced | [`plans/2026-09-24-foundation-plan.md`](plans/2026-09-24-foundation-plan.md) — temporary: `docs/plans/` is committed only until sub-project 2's own (uncommitted) ledger exists |

## The framework in 30 seconds

- **Target:** SwiftUI, iOS 18+, Swift 6 language mode (complete concurrency checking). Xcode 26.2 /
  Swift 6.2.3, pinned; `swiftgate doctor` blocks on a mismatch.
- **Shape:** a thin app target plus local Swift packages. Core packages are platform-neutral,
  host-testable (`swift test` on the Mac), import no UI framework, and treat every source of
  nondeterminism (clock, RNG, UUID, network, persistence) as a `@Dependency`.
- **TCA is the default architecture** (~99% of Core modules): `@Reducer` + `@ObservableState` +
  `TestStore`, 1.x shape only (TCA 2.0 is a subscriber-only beta — do not use it).
- **Every service is a `FooClient`/`FooClientLive` pair.** IO and vendor SDKs live only in
  `*Live` modules, imported only by the app target. No singletons.
- **`swiftgate` is the single enforcement point.** No hook, skill, or git hook re-implements a
  check; a hook that does is a defect.
- **Escape hatches carry a reason.** `@unchecked Sendable`, `try!`, `as!`, `fatalError`, and any
  suppression need a same-line `swiftgate:allow <rule> — <reason>`; a bare allow is itself a
  finding.
- **Log and trace through `LogClient`/`TracingClient` only** — structured, privacy-tagged
  attributes; no direct `Logger`/`OSSignposter`/`print`/vendor SDK outside their `*Live` modules.
- **Comments carry only what the code can't give back** — no restated code, no diff/history
  narration, no local paths, no codenames, no line-number references.
- Status (as of the Foundation build): review findings carry `kind` (`defect` |
  `standards-violation`), refined in [ADR 0001](adrs/0001-review-severity-for-standards-violations.md).
