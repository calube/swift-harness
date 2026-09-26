---
runs: 3
max_turns: 1
timeout_seconds: 300
allowed_tools: [Read, Glob, Grep, Skill]
---

rebased fact-dismiss onto main and now the dismiss case in CounterCoreTests is red. it expects fact to be nil after dismissing but it's still holding the old string. get it green
