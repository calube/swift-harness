---
runs: 3
max_turns: 1
timeout_seconds: 300
allowed_tools: [Read, Glob, Grep, Skill]
---

testDismissFact only checks the action gets received. add an assertion that state.fact is nil after it
