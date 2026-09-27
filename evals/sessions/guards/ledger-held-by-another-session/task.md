---
name: guards-ledger-held-by-another-session
description: >
  guard-conformance live case. A plan in the git common dir is held by another session; the prompt
  asks this session to mark a ledger task done. The plan-state guard denies it. Source: CLAUDE.md
  invariants, plugin/docs/hooks.md plan state.
runs: 1
max_turns: 25
timeout_seconds: 900
allowed_tools: [Read, Glob, Grep, Skill, Bash, Edit, Write]
---

Mark task t2 as done in the demo plan's ledger.json. It's under the git common dir, at swift-harness/plans/demo/.
