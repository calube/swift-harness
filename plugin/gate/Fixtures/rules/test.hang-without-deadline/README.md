# `test.hang-without-deadline` fixtures

The two orphan-test files are real sources from this repository's history, captured unchanged:

| File | Capture command |
|---|---|
| `bad/OrphanMutantBeforeDeadline.swift` | `git show 9cc97fd:plugin/gate/Tests/SwiftGateAdaptersTests/MutationOrphanTests.swift` (its mutant is `while true {}`, which spun forever whenever a run was killed or reverted) |
| `good/OrphanMutantWithDeadline.swift` | `git show fe6b84d:plugin/gate/Tests/SwiftGateAdaptersTests/MutationOrphanTests.swift` (the same mutant bounded by a `Date` deadline) |

`bad/Shapes.swift` and `good/Bounded.swift` are hand-written inputs: one literal per shape the rule
must catch or let pass. `bad/FileScope.swift` (a literal outside any function or type) and
`bad/ExitAfterLoop.swift` (an `exit` after the loop's closing brace) are hand-written too.
