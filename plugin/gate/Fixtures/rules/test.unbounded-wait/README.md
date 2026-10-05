# `test.unbounded-wait` fixtures

`bad/AssetDetailFeatureTests.swift` is a real test file, captured unchanged from the price-tracker
brownfield trial (its app-core task branch). Its `dismissCancelsChart` spins on
`while !started.value { await Task.yield() }`; with the reducer reverted the flag never flipped and
the merge gate's prove ran for about 17 minutes. From the trial clone:

```sh
git show spec/app-core:Packages/AppFeature/Tests/AppCoreTests/AssetDetailFeatureTests.swift
```

`bad/ForAwaitFirstElement.swift` is a real test file, captured unchanged from the fourth
price-tracker trial (its detail task's first commit). Its `cancellationStopsRequest` waits for a
stream's first element with `for await _ in started.stream { break }`; with the reducer reverted
nothing yielded, and prove killed that test and 3 others at 227 s. From the trial clone:

```sh
git show 725c938:Packages/AppFeature/Tests/AppCoreTests/AssetDetailFeatureTests.swift
```

`good/BoundedWaits.swift` is hand-written: one bounded variant per shape the rule must let pass (a
deadline or an attempt cap in the condition, a `break`, `return` or `throw` in the body, loops
that await nothing, and a first element taken inside a timeout or raced against a sleep in a task
group).
