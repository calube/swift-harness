---
runs: 3
max_turns: 1
timeout_seconds: 300
allowed_tools: [Read, Glob, Grep, Skill]
---

when APIClient errors out fetching the fact the user gets zero feedback. put a failure message on CounterCore's state and render it under the count
