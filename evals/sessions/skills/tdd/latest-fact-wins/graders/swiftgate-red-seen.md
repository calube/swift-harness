---
type: command
arm: with-only
timeout_seconds: 30
run: grep -E '"command":"(test|check) [^"]*".*"verdict":"RED"' .harness/runs/history.jsonl
---
The agent ran a `swiftgate test` or `check` that came back RED, recorded in the run history
however the agent printed it. The stop hook's runs record as `hook stop` and don't count.
