This run gives you no tools. Your context pack is inline below, and it holds everything you
would otherwise read from disk.

# Claim checker pack

## Claim 1

```json
{"id": "ev-tca-cancellable-always-cancels-in-flight", "lane": "packages", "text": "Effect.cancellable(id:cancelInFlight:) always cancels an in-flight effect with the same id before a new one starts.", "citation": {"kind": "file", "loc": ".build/checkouts/swift-composable-architecture/Sources/ComposableArchitecture/Effects/Cancellation.swift:L36-L36", "pin": "swift-composable-architecture@1.26.2", "quote": "public func cancellable(id: some Hashable & Sendable, cancelInFlight: Bool = false) -> Self"}, "status": "quote-ok"}
```

Cited lines, `.build/checkouts/swift-composable-architecture/Sources/ComposableArchitecture/Effects/Cancellation.swift:L31-L36`:

```swift
  /// - Parameters:
  ///   - id: The effect's identifier.
  ///   - cancelInFlight: Determines if any in-flight effect with the same identifier should be
  ///     canceled before starting this new one.
  /// - Returns: A new effect that is capable of being canceled by an identifier.
  public func cancellable(id: some Hashable & Sendable, cancelInFlight: Bool = false) -> Self {
```
