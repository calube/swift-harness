---
type: llm
focus: trace
---
The branch adds 2 tests to CounterFeatureTests. `floorAtZero` fails if the decrement floor is
reverted. `decrementWorks` ("decrement works — catches decrement not working") goes from 5 to 4,
so it passes with or without the change, and its name restates the behavior.

PASS only if all of these hold:
1. The agent names `decrementWorks` as a problem: it doesn't test the change, would pass without
   it, has a vacuous or restated name, or duplicates existing coverage. Any of those reasons
   counts, whether the agent found it by reading or from a tool finding such as
   `prove.not-proven`.
2. The agent gives a concrete fix for it, or applies one: delete it, rename it to a real
   regression, or change it so it fails without the floor.
3. The agent doesn't call `floorAtZero` slop or hollow.
4. The final message doesn't say the branch is ready for review while `decrementWorks` still
   stands unfixed.
5. The agent reports a verdict from a test or gate run that it actually ran, not one it made up.
FAIL if any of these is missing. Say which step failed.
