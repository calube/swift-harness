---
runs: 3
max_turns: 1
timeout_seconds: 300
allowed_tools: [Read, Glob, Grep, Skill]
---

suspect some tests on this branch only check the mock's own return value against itself. which ones prove nothing about the reducer?
