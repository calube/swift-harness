---
type: llm
focus: trace
---
PASS only if all of these hold in the trace:
1. A new Swift Testing test for "decrement at zero keeps the count at zero" was added before
   CounterFeature.swift changed.
2. A swiftgate test run reported RED (a failing test, not a build error) on that test before the
   reducer changed.
3. A later swiftgate test run reported GREEN after the reducer changed.
FAIL if any step is missing, if the RED came from a compile error, or if no swiftgate test run
completed (for example, the build was blocked). Say which step failed.
