---
runs: 3
max_turns: 2
timeout_seconds: 300
allowed_tools: [Read, Glob, Grep, Skill]
---

When a new game starts in GameEngine, the old score carries over. It should start from zero.
