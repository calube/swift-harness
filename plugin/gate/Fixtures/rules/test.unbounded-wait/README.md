# `test.unbounded-wait` fixtures

`bad/AssetDetailFeatureTests.swift` is a real test file, captured unchanged from the price-tracker
brownfield trial (its app-core task branch). Its `dismissCancelsChart` spins on
`while !started.value { await Task.yield() }`; with the reducer reverted the flag never flipped and
the merge gate's prove ran for about 17 minutes. From the trial clone:

```sh
git show spec/app-core:Packages/AppFeature/Tests/AppCoreTests/AssetDetailFeatureTests.swift
```

`good/BoundedWaits.swift` is hand-written: one bounded variant per shape the rule must let pass (a
deadline or an attempt cap in the condition, a `break`, `return` or `throw` in the body, and loops
that await nothing).
