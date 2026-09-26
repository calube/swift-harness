---
runs: 3
max_turns: 1
timeout_seconds: 300
allowed_tools: [Read, Glob, Grep, Skill]
---

HTTPClient's timeout test passes on my machine but dies maybe one run in five on CI. pretty sure it's leaning on real time somewhere. make it reliable
