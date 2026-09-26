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

Glob of `.build/checkouts/*`: `swift-dependencies/` only. There is no `swift-composable-architecture/` directory.

## Lane brief

- Which TCA API cancels an in-flight effect when a new one with the same id starts, and what is its signature at the pinned version?
