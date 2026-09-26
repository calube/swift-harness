---
type: regex
target: trace
pattern: '\\"tier\\" : \\"T0\\"'
arm: with-only
---
A `swiftgate check` `--json` report reached the agent: only `check` runs T0. Matching the command
text alone would pass a run where every call came back BLOCKED.
