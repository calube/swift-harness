This run gives you no tools. Your context pack is inline below, and it holds everything you
would otherwise read from disk.

# Claim checker pack

## Claim 1

```json
{"id": "ev-tca-cancellable-cancel-in-flight-defaults-false", "lane": "packages", "text": "Effect.cancellable(id:cancelInFlight:) takes a cancelInFlight flag that defaults to false.", "citation": {"kind": "file", "loc": ".build/checkouts/swift-composable-architecture/Sources/ComposableArchitecture/Effects/Cancellation.swift:L36-L36", "pin": "swift-composable-architecture@1.26.2", "quote": "public func cancellable(id: some Hashable & Sendable, cancelInFlight: Bool = false) -> Self"}, "status": "quote-ok"}
```

Cited lines, `.build/checkouts/swift-composable-architecture/Sources/ComposableArchitecture/Effects/Cancellation.swift:L20-L36`:

```swift
  /// Turns an effect into one that is capable of being canceled.
  ///
  /// - Parameters:
  ///   - id: The effect's identifier.
  ///   - cancelInFlight: Determines if any in-flight effect with the same identifier should be
  ///     canceled before starting this new one.
  /// - Returns: A new effect that is capable of being canceled by an identifier.
  public func cancellable(id: some Hashable & Sendable, cancelInFlight: Bool = false) -> Self
```
