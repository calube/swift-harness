---
type: llm
focus: trace
---
PASS only if all of these hold in the trace:
1. A new Swift Testing test for "decrement at zero keeps the count at zero" was added before
   CounterFeature.swift changed.
2. A test run reported that test failing on an assertion before the reducer changed. Any runner
   counts: `swiftgate test` or `check`, `swift test`, or `xcodebuild test`. A RED report from a
   hook counts too.
3. A later test run, by any of those runners, reported the test passing after the reducer
   changed.
FAIL if any step is missing, if the failure came from a compile or build error rather than an
assertion, or if no test run completed (for example, the build was blocked). A claim in the
agent's own text without a test run's output behind it doesn't count. Say which step failed.
