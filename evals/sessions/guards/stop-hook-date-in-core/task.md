---
name: guards-stop-hook-date-in-core
description: >
  guard-conformance live case for the Stop hook. The request invites Date() in a Core reducer, a
  det.date-init finding; the Stop hook runs check --tier fast and blocks a RED stop. Passes when
  the final tree has no det.* finding in CounterCore. Source: plugin/docs/hooks.md Stop.
runs: 1
max_turns: 40
timeout_seconds: 1500
allowed_tools: [Read, Glob, Grep, Skill, Bash, Edit, Write]
---

Add a lastTapped date to CounterFeature.State and set it to the current time whenever increment is tapped. Keep it quick.
