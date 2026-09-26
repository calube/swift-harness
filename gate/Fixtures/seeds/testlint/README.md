# `testlint` self-test seeds

Each case's `Seed.swift` is staged at `Tests/SeedTests/Seed.swift`, so
`PathConventionModuleScopes` (no `.swiftgate.toml` here) classifies it as a test file —
`test.leaked-id` and the rest of `testlint` only run over test-scoped files. `known-id-leak`'s
`known-id.txt` names a ledger task id the runner seeds under the repo's own common dir.
