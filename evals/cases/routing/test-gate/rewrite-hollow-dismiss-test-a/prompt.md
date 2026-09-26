---
runs: 3
max_turns: 1
timeout_seconds: 300
allowed_tools: [Read, Glob, Grep, Skill]
---

review feedback says the dismiss test asserts nothing meaningful. rewrite it so it'd actually fail if dismiss stopped clearing the fact
