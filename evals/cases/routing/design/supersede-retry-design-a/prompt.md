---
runs: 3
max_turns: 1
timeout_seconds: 300
allowed_tools: [Read, Glob, Grep, Skill]
---

The retry design we approved assumed no backoff. Replace it with a new one that supersedes it.
