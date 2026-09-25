## swift-harness

This repository is gated by the swift-harness plugin. `swiftgate` is the only gate: skills, Claude
Code hooks and git hooks all call it, and none of them re-implement a check.

**Verdicts.** `GREEN` means the code is good. `RED` means the code is wrong: fix the code. `BLOCKED`
means the environment is wrong (Xcode pin, simulator runtime, disk): fix the environment, never the
code. Pass `--json` for the versioned report; full logs land in `.harness/runs/<run-id>/`.

**Before you call a change done.**

| When | Run |
|---|---|
| While editing | `swiftgate check --tier fast` (T0 + affected host tests; the Stop hook runs it too) |
| Before pushing | `swiftgate check --tier push` (the pre-push hook runs it) |
| Before asking for review | `swiftgate check --tier ready` (adds UI flows, prove, stress, reach) |
| Machine trouble | `swiftgate doctor` |

**Where the rules live.** In the swift-harness plugin:

- `docs/standards.md` — concurrency, architecture, clients, errors, logging, SwiftUI, comments.
  Rule ids such as `det.date-init` or `A2` point into it.
- `docs/testing-playbook.md` — tiers T0–T3, test naming, red/green proof, snapshots, flows (P1–P11).

**Skills.** `/swift-harness:architecture` (design a module, pick its kind),
`/swift-harness:tdd` (test-first), `/swift-harness:test-gate` (pre-ready sequence),
`/swift-harness:validate` (evidence for a PR), `/swift-harness:comment-audit`,
`/swift-harness:status` (active plans across repositories).

**Hard rules.**

- Never run `xcodebuild` directly, erase simulators, or pass snapshot record flags: go through
  `swiftgate` (`swiftgate test --tier t2|t3`, `swiftgate snapshots record`).
- Never hand-edit snapshot references, `Package.resolved`, `.xcresult` bundles, or
  `.harness/plans/`.
- Waive a rule only on the offending line: `// swiftgate:allow <rule-id> — <reason>`. A bare allow
  is itself RED.
- Project settings live in `.swiftgate.toml`; this block is managed by `swiftgate bootstrap`, so
  edit outside the markers.
