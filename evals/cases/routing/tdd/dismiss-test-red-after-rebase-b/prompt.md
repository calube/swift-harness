---
runs: 3
max_turns: 1
timeout_seconds: 300
allowed_tools: [Read, Glob, Grep, Skill]
---

`swift test` in Packages/CounterFeature: the fact-dismiss test fails, expected nil got "42 is the answer...". something in the reducer isn't clearing it. sort it out pls
