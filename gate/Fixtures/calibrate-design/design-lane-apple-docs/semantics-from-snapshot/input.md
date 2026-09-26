This run gives you no tools. Your context pack is inline below, and it holds everything you
would otherwise read from disk.

Prompt: design doc `docs/reading/designs/article-fetch.md`, SDK pin 26.2.

# Research lane pack: apple-docs

## Frame answers

- Fetch article bodies from the server when the user opens an article.

## Stored snapshots (`<slug>.evidence/snapshots/`, taken at SDK 26.2)

`snapshots/observation-migrating.md`:

> SwiftUI updates a view only when an observable property changes and the view's body reads the property directly.

## Probe snippet rule

A `probe` claim's snippet is built against SDK 26.2 by `swiftgate probe` after you return.

## Lane brief

- Does SwiftUI redraw a view when an observable property changes that the view's body never reads?
