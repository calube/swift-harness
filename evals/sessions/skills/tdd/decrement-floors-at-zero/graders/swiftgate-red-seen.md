---
type: command
arm: with-only
timeout_seconds: 30
run: grep -E '"command":"(test|check) [^"]*".*"verdict":"RED"' .harness/runs/history.jsonl
---
The agent ran a `swiftgate test` or `check` that came back RED. swiftgate records each run's verdict
in `.harness/runs/history.jsonl`, however the agent printed it; a regex over the trace missed a real
RED that the agent had piped through a JSON filter. The stop hook records as `hook stop`, so its
runs don't count, and a BLOCKED run isn't RED.
