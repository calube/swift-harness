---
runs: 3
max_turns: 1
timeout_seconds: 300
allowed_tools: [Read, Glob, Grep, Skill]
---

the retry/timeout case in HTTPClientTests is intermittent. I think it's racing an actual sleep. rework it so it's not at the mercy of the clock
