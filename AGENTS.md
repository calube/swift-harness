# swift-harness

A Claude Code plugin holding SwiftUI iOS work to a consistent bar. Full docs: [`docs/index.md`](docs/index.md).

Status: frozen at `harness-freeze-2026-10-05`; see
[`docs/handoffs/2026-10-05-practice-app-results.md`](docs/handoffs/2026-10-05-practice-app-results.md).

This file is for contributors: people building the harness itself. The plugin that consumers
install is [`plugin/`](plugin/): skills, agents, hooks, workflows, templates, the `swiftgate`
source in `plugin/gate/`, and the reference docs skills read at runtime
([ADR 0002](docs/adrs/0002-consumer-plugin-in-plugin-dir.md)). Nothing under `plugin/` may
reference a path above it, and `plugin/bin/swiftgate` is the only shim.

Run `lefthook install` once, after installing lefthook, so this repo's `lefthook.yml` wires
pre-push to `plugin/bin/swiftgate check --tier push` and commit-msg to the comments check.

## Invariants you could violate without realizing

- **Never re-implement a check.** Every enforcement point (hook, skill, git hook, future CI) calls
  `swiftgate`. If you find yourself hand-writing a lint/arch/test check, stop: it belongs in
  `plugin/gate/`.
- **Gate layering.** `SwiftGateDomain` is pure: no Foundation `Process`/`FileManager` IO. Adapters
  live behind protocols in `SwiftGateAdapters`. `SwiftGateCLI` stays thin: it wires adapters to
  domain logic and prints, nothing more.
- **Capture fixtures; never hand-author them.** A fixture under `plugin/gate/Tests/Fixtures/` comes
  from a real tool run. Record the exact capture command in that directory's `README.md`.
- **Every new rule ships a fixture and a rule-index row.** Add the row to
  `plugin/docs/standards.md`'s rule id index in the same change that adds the check.
- **An escape hatch needs a same-line reason.** `@unchecked Sendable`, `nonisolated(unsafe)`,
  `try!`, `as!`, `fatalError`, and any `*-disable` suppression carry
  `// swiftgate:allow <rule> — <reason>` on the same line. A bare allow is itself a finding.
- **Comments carry only what the code can't give back.** No restated code, no diff/history
  narration ("previously", "switched from", "this PR"), no local machine paths, no line-number
  references, no opaque codenames (`Phase N`, `Stage N`, `[A-Z]{1,3}\d+`).
- **A new or changed test must fail for a real reason first.** Assertion-free, tautological,
  existence-only, or sleep-based tests are findings, not passes.
- **One committer per worktree.** Multi-task work runs in `git worktree` checkouts, one per task;
  each worktree's worker commits to its own branch and never pushes. Only the orchestrator merges
  to `main`.
- **Plan/ledger state is orchestrator-only.** It lives in the git common dir
  (`$(git rev-parse --git-common-dir)/swift-harness/plans/`), shared by every worktree and never
  committed. A subagent is never the orchestrator, even inside the orchestrator's own session;
  don't hand-edit `ledger.json` or `index.json`.

For building an app on top of the harness (module kinds, `@Dependency`, TCA, logging clients, no
singletons), read [`plugin/docs/standards.md`](plugin/docs/standards.md), not this file.

The plan and wave process that build this harness live in
[the current plan](docs/plans/2026-09-25-design-plan-workflows-plan.md), the
[orchestrator runbook](docs/handoffs/subproject-2-orchestrator-runbook.md), and the
[interfaces note](docs/handoffs/subproject-2-interfaces.md) each wave appends to.

Everything else (the rule catalog, testing tiers, hooks, design docs, ADRs) is in
[`docs/index.md`](docs/index.md). Don't guess a rule; grep `plugin/docs/standards.md` or ask.

`CLAUDE.md` in this repo is a symlink to this file.
