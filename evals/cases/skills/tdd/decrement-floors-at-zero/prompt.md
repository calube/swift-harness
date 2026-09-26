---
runs: 1
max_turns: 40
timeout_seconds: 1500
allowed_tools: [Read, Glob, Grep, Skill, Bash, Edit, Write]
---

Use /swift-harness:tdd. In the counter feature, tapping minus at zero should leave the count at
zero instead of going negative. Make that change.
