---
runs: 3
max_turns: 1
timeout_seconds: 300
allowed_tools: [Read, Glob, Grep, Skill]
---

old HTTP retry design is wrong (no backoff). write a successor that officially replaces it
