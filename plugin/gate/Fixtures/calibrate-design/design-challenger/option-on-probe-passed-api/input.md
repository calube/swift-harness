This run gives you no tools. Your context pack is inline below, and it holds everything you
would otherwise read from disk.

# Pack

## Design doc

```markdown
---
status: proposed
area: connectivity
tier: standard
---

# Connectivity banner

## Problem

The app shows no sign that it is offline, so users retry actions that can't succeed.

## Requirements

- req-offline-banner-appears-within-a-second: the banner appears within 1 second of the device losing its network path.

## Evidence

- [ev-nwpathmonitor-path-update-handler] NWPathMonitor calls pathUpdateHandler with each new path.
- [ev-async-stream-makestream-returns-stream-and-continuation] AsyncStream.makeStream returns a stream and its continuation.
- [ev-nwpathmonitor-start-queue-and-cancel] NWPathMonitor has start(queue:) and cancel().
- [ev-async-stream-continuation-on-termination] AsyncStream.Continuation has a settable onTermination handler.

## Options

### Option 1: Wrap NWPathMonitor's pathUpdateHandler in NetworkMonitorClient

The live client sets `pathUpdateHandler` and yields each `NWPath` into an `AsyncStream`.

### Option 2: Iterate NWPathMonitor.pathUpdates directly

The live client runs `for await path in monitor.pathUpdates` and needs no stream of its own.

## Decision

- Choose Option 1: NetworkMonitorClientLive sets `pathUpdateHandler` and yields each path into a stream from `AsyncStream.makeStream` [ev-nwpathmonitor-path-update-handler] [ev-async-stream-makestream-returns-stream-and-continuation].
- Each call to the client's stream creates its own NWPathMonitor, calls `start(queue:)` on it, and calls `cancel()` from the continuation's `onTermination` [ev-nwpathmonitor-start-queue-and-cancel] [ev-async-stream-continuation-on-termination].

## Architecture

NetworkMonitorClient (interface) and NetworkMonitorClientLive (imports Network). ConnectivityFeature reads the client's stream.

## Test plan by tier

- test-banner-shows-when-path-unsatisfied: the reducer sets `isOffline` on an unsatisfied path — tier T1

## Risks

- None recorded.
```

## Cited claims and probe verdicts

```json
{"id": "ev-nwpathmonitor-path-update-handler", "lane": "apple-docs", "text": "NWPathMonitor has a settable pathUpdateHandler that takes an NWPath.", "citation": {"kind": "probe", "loc": "probes/Probe_ev_nwpathmonitor_path_update_handler.swift", "pin": "26.2"}, "status": "supported"}
{"id": "ev-async-stream-makestream-returns-stream-and-continuation", "lane": "apple-docs", "text": "AsyncStream.makeStream(of:) returns a stream and its continuation.", "citation": {"kind": "probe", "loc": "probes/Probe_ev_async_stream_makestream_returns_stream_and_continuation.swift", "pin": "26.2"}, "status": "supported"}
{"id": "ev-nwpathmonitor-start-queue-and-cancel", "lane": "apple-docs", "text": "NWPathMonitor has start(queue:) and cancel() methods.", "citation": {"kind": "probe", "loc": "probes/Probe_ev_nwpathmonitor_start_queue_and_cancel.swift", "pin": "26.2"}, "status": "supported"}
{"id": "ev-async-stream-continuation-on-termination", "lane": "apple-docs", "text": "AsyncStream.Continuation has a settable onTermination handler.", "citation": {"kind": "probe", "loc": "probes/Probe_ev_async_stream_continuation_on_termination.swift", "pin": "26.2"}, "status": "supported"}
```

`probes/Probe_ev_nwpathmonitor_path_update_handler.verdict.json`:

```json
{"claimId": "ev-nwpathmonitor-path-update-handler", "verdict": "pass", "diagnostics": [], "pins": [], "sdk": "26.2"}
```

`probes/Probe_ev_async_stream_makestream_returns_stream_and_continuation.verdict.json`:

```json
{"claimId": "ev-async-stream-makestream-returns-stream-and-continuation", "verdict": "pass", "diagnostics": [], "pins": [], "sdk": "26.2"}
```

`probes/Probe_ev_nwpathmonitor_start_queue_and_cancel.verdict.json`:

```json
{"claimId": "ev-nwpathmonitor-start-queue-and-cancel", "verdict": "pass", "diagnostics": [], "pins": [], "sdk": "26.2"}
```

`probes/Probe_ev_async_stream_continuation_on_termination.verdict.json`:

```json
{"claimId": "ev-async-stream-continuation-on-termination", "verdict": "pass", "diagnostics": [], "pins": [], "sdk": "26.2"}
```
