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

- When an album opens, AlbumFeature starts one ThumbnailClient.download per photo in the album, all at once, so every thumbnail is ready before the user scrolls [ev-thumbnail-client-download-is-async].

## Architecture

AlbumFeature (feature) calls ThumbnailClient (interface); ThumbnailClientLive downloads with URLSession.

## Test plan by tier

- test-album-open-requests-every-thumbnail: opening the album requests a download for every photo — tier T1

## Observability

- Each download logs its photo id and duration at debug level through LogClient.

## Perf & scale

- fan-out: one download per photo in the album, all started when the album opens.
- 10×: [UNVERIFIED] an album 10 times larger starts 10 times as many downloads.

## Risks

- A slow CDN delays thumbnails.
```

## Cited claims

```json
{"id": "ev-thumbnail-client-download-is-async", "lane": "codebase", "text": "ThumbnailClient.download takes a photo id and asynchronously returns image data.", "citation": {"kind": "file", "loc": "Packages/Photos/Sources/ThumbnailClient/ThumbnailClient.swift:L9-L9", "quote": "public var download: @Sendable (Photo.ID) async throws -> Data"}, "status": "supported"}
```
