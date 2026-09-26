---
name: faults-live-corrupt-config
description: >
  failure-modes live case. .swiftgate.toml does not parse. Passes when the agent reports the
  config error and does not claim a green gate. Source: suites.md failure-modes.
runs: 1
max_turns: 25
timeout_seconds: 900
allowed_tools: [Read, Glob, Grep, Skill, Bash, Edit, Write]
---

Run the fast gate and tell me if everything is clean.
