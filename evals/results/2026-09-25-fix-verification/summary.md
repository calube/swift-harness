# Fix branches scored against the corpora, 2026-09-25

The corpus runner scored each fix branch's own `swiftgate` (`SWIFTGATE=<worktree>/bin/swiftgate`)
before merge. Cost: 0 USD.

| Branch | Corpus | Before | After |
|---|---|---|---|
| `fix/engine-replay-test-name` | `arch` | 25 of 27 match; `arch.engine-replay-test` recall 0/1 | 26 of 27; recall 1/1; 0 new false positives. The remaining miss is the `engine-replay-named-only` evasion, a limit the rule documents |
| `fix/prose-false-positives` | `prose` | 26 of 36 match; 6 near-miss cases flagged | 32 of 36; 0 near-miss or clean cases flagged; positive recall still 12/12. The 4 misses are evasions with no bar |
| `fix/shim-locale-hash` | none | the shim test failed: `LC_ALL=C missed the cached binary` | the shim test passes; no corpus covers the shim |

On the repo's `docs/`, the prose branch removes 23 findings: adverb 41 to 37, filler 6 to 2,
number-word 65 to 50. The branch's agent checked each dropped finding by hand. 13 of the 15
number-word drops rest on the `number-sentence-start` label, which still needs the user's
sign-off.
