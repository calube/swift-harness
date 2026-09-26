---
runs: 3
max_turns: 1
timeout_seconds: 300
allowed_tools: [Read, Glob, Grep, Skill]
---

our CI runs swift test on every push and it's slow. what are my options for splitting snapshot tests into their own job? just explain
