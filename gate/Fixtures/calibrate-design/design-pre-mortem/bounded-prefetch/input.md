This run gives you no tools. Your context pack is inline below, and it holds everything you
would otherwise read from disk.

# Pre-mortem pack

## Design doc

```markdown
---
status: proposed
area: photos
tier: deep
---

# Album thumbnails

## Problem

Opening an album shows grey placeholders for seconds while thumbnails load one by one.

## Requirements

- req-album-thumbnails-appear-while-scrolling: thumbnails for visible photos appear while the user scrolls albums of up to 5,000 photos.

## Decision

- AlbumFeature downloads thumbnails for the visible rows plus one screen ahead, through a task group that keeps at most 6 downloads in flight, and cancels downloads for rows that scroll off screen [ev-thumbnail-client-download-is-async].

## Architecture

AlbumFeature (feature) calls ThumbnailClient (interface); ThumbnailClientLive downloads with URLSession.

## Test plan by tier

- test-prefetch-caps-in-flight-downloads-at-six: a 5,000-photo album never has more than 6 downloads in flight — tier T1
- test-prefetch-cancels-rows-scrolled-away: scrolling past a row cancels its download — tier T1

## Observability

- Each download logs its photo id and duration at debug level through LogClient.

## Perf & scale

- fan-out: at most 6 downloads in flight, whatever the album size.
- backpressure: rows past the lookahead wait for a free slot; off-screen rows are cancelled.
- 10×: an album 10 times larger keeps the same 6 in flight and the same lookahead.

## Risks

- A slow CDN delays thumbnails.
```

## Cited claims

```json
{"id": "ev-thumbnail-client-download-is-async", "lane": "codebase", "text": "ThumbnailClient.download takes a photo id and asynchronously returns image data.", "citation": {"kind": "file", "loc": "Packages/Photos/Sources/ThumbnailClient/ThumbnailClient.swift:L9-L9", "quote": "public var download: @Sendable (Photo.ID) async throws -> Data"}, "status": "supported"}
```
