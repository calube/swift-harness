# swift-harness

A Claude Code plugin holding SwiftUI iOS work to a consistent bar. Full docs: [`docs/index.md`](docs/index.md).

## Invariants you could violate without realizing

- **Never re-implement a check.** Every enforcement point (hook, skill, git hook, future CI) calls
  `swiftgate`. If you find yourself hand-writing a lint/arch/test check, stop — it belongs in `gate/`.
- **Core modules import no UI framework** (`SwiftUI`, `UIKit`) and touch no `URLSession.shared` or
  vendor SDK directly. IO and vendor SDKs live only in `*Live` modules, imported only by the app
  target.
- **Every source of nondeterminism is a `@Dependency`** (`\.date`, `\.uuid`, `\.continuousClock`,
  randomness). `Date()`, `UUID()`, `Task.sleep`, `.random(in:)` in Core or a client interface is a
  finding, not a style choice.
- **No singletons** (`static let shared`, a global `var`). Reach shared services through
  `@Dependency`.
- **TCA is 1.x only.** `ViewStore`, `WithViewStore`, `@BindingState`, `TaskResult`, `AnyCasePath`,
  and any TCA 2.0 API are banned, even if they compile.
- **An escape hatch needs a same-line reason.** `@unchecked Sendable`, `nonisolated(unsafe)`,
  `try!`, `as!`, `fatalError`, and any `*-disable` suppression carry
  `// swiftgate:allow <rule> — <reason>` on the same line. A bare allow is itself a finding.
- **Log only through `LogClient`/`TracingClient`.** No direct `Logger`, `OSSignposter`, `print`, or
  vendor logging/tracing SDK outside `LogClientLive`/`TracingClientLive`.
- **Comments carry only what the code can't give back.** No restated code, no diff/history
  narration ("previously", "switched from", "this PR"), no local machine paths, no line-number
  references, no opaque codenames (`Phase N`, `Stage N`, `[A-Z]{1,3}\d+`).
- **A new or changed test must fail for a real reason first.** Assertion-free, tautological,
  existence-only, or sleep-based tests are findings, not passes.
- **Plan/ledger state is orchestrator-only.** A subagent is never the orchestrator, even inside the
  orchestrator's own session; don't hand-edit `ledger.json` or `index.json`.

Everything else — the rule catalog, testing tiers, hooks, design docs, ADRs — is in
[`docs/index.md`](docs/index.md). Don't guess a rule; grep `docs/standards.md` or ask.

`CLAUDE.md` in this repo is a symlink to this file.
