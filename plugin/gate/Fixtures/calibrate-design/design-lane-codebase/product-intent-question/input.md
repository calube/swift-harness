This run gives you no tools. Your context pack is inline below, and it holds everything you
would otherwise read from disk.

Prompt: design doc `docs/library/designs/favourites-sync.md`, researched at commit
4ada6b2c0d9e8f7a6b5c4d3e2f1a0b9c8d7e6f5a.

# Research lane pack: codebase

## Frame answers

- Favourites should be easier to find again.

## Module-graph slice

- FavoritesClient (client), FavoritesClientLive (client), LibraryFeature (feature) depends on FavoritesClient.

## Source excerpt: `Packages/Library/Sources/FavoritesClient/FavoritesClient.swift`

```swift
7  @DependencyClient
8  public struct FavoritesClient: Sendable {
9    public var load: @Sendable () async throws -> [Book.ID]
10   public var save: @Sendable ([Book.ID]) async throws -> Void
11 }
```

## Source excerpt: `Packages/Library/Sources/FavoritesClientLive/FavoritesClientLive.swift`

```swift
12   static let liveValue = FavoritesClient(
13     load: { try await store.read(from: .favouritesFile) },
14     save: { try await store.write($0, to: .favouritesFile) }
15   )
```

## Lane brief

- Should favourites sync across the user's devices through iCloud, or stay on this device only?
