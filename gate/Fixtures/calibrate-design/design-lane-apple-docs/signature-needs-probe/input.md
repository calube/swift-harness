This run gives you no tools. Your context pack is inline below, and it holds everything you
would otherwise read from disk.

Prompt: design doc `docs/reading/designs/article-fetch.md`, SDK pin 26.2.

# Research lane pack: apple-docs

## Frame answers

- Fetch article bodies from the server when the user opens an article.

## Stored snapshots (`<slug>.evidence/snapshots/`, taken at SDK 26.2)

`snapshots/urlsession-data-for.md`:

> Declaration: `func data(for request: URLRequest, delegate: (any URLSessionTaskDelegate)? = nil) async throws -> (Data, URLResponse)`
> Downloads the contents of a URL based on the specified URL request and delivers the data asynchronously.

## Probe snippet rule

A `probe` claim's snippet is built against SDK 26.2 by `swiftgate probe` after you return.

## Lane brief

- Does URLSession.data(for:) exist, taking a URLRequest and returning (Data, URLResponse)?
