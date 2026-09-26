# Design fixtures

These design docs are hand-authored (spec §5.3 templates), not captured tool output. The one
exception is a citation's `loc`/`quote`: where a claim cites a real third-party source line, that
line is copied verbatim from a real checkout at the pinned version, never invented.

| File | Verified against |
|---|---|
| `valid.evidence/claims.jsonl` (`ev-tca-effect-run-supports-cancellation`) | `swift-composable-architecture@1.26.2`, pinned by `examples/SampleApp/Packages/CounterFeature/Package.swift`. Resolved with `(cd examples/SampleApp/Packages/CounterFeature && swift package resolve)`, then the citation's `loc`/`quote` is `Sources/ComposableArchitecture/Effects/Cancellation.swift:L36` (`grep -n "public func cancellable" .build/checkouts/swift-composable-architecture/Sources/ComposableArchitecture/Effects/Cancellation.swift`) copied verbatim from `.build/checkouts/swift-composable-architecture/...` in that package's working copy. |
