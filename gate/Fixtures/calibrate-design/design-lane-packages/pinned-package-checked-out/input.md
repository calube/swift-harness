This run gives you no tools. Your context pack is inline below, and it holds everything you
would otherwise read from disk.

Prompt: design doc `docs/search/designs/search-debounce.md`.

# Research lane pack: packages

## Frame answers

- Cancel the previous search request when the user types again.

## `Package.resolved` pins

- swift-composable-architecture 1.26.2
- swift-dependencies 1.17.1

## `.build/checkouts/`

Glob of `.build/checkouts/*`: `swift-composable-architecture/`, `swift-dependencies/`.

`.build/checkouts/swift-composable-architecture/Sources/ComposableArchitecture/Effects/Cancellation.swift`, lines 32-36:

```swift
32  ///   - cancelInFlight: Determines if any in-flight effect with the same identifier should be
33  ///     canceled before starting this new one.
34  /// - Returns: A new effect that is capable of being canceled by an identifier.
35  @_documentation(visibility: public)
36  public func cancellable(id: some Hashable & Sendable, cancelInFlight: Bool = false) -> Self
```

## Lane brief

- Which TCA API cancels an in-flight effect when a new one with the same id starts, and what is its signature at the pinned version?
