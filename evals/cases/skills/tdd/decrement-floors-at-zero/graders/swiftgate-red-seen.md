---
type: regex
target: trace
pattern: '\\"verdict\\" : \\"RED\\"'
---
A swiftgate `--json` report with verdict RED reached the agent. Matching the command alone passed
a run where every swiftgate call came back BLOCKED.
