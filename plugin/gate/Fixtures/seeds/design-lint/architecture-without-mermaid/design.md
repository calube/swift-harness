---
status: approved
area: checkout
tier: standard
---

# Offline order queue

## Problem

Guests on flaky Wi-Fi lose their cart when the app can't reach checkout. The client should queue
the order on the device and submit it once the network returns, instead of showing a dead end.

## Requirements

- req-offline-queue-drains-on-reconnect: The client resubmits queued orders once connectivity returns.
- req-queue-survives-app-relaunch: A queued order is still present after the app is force-quit and reopened.

## Evidence

- [ev-tca-effect-run-supports-cancellation] `.cancellable(id:)` lets a caller cancel an in-flight `Effect.run` effect by id.
- [UNVERIFIED] The App Store review guidelines allow silent background submission of a queued order.

## Options

### Option 1: Client-side queue with a TCA reducer

Trade-offs: no server changes, but the client owns retry and dedupe logic.

### Option 2: Server-side draft orders

Trade-offs: the server owns retry, but every draft consumes an order row until it's confirmed.

## Decision

- Client-side queue [ev-tca-effect-run-supports-cancellation]

## Architecture

The reducer forwards each queued order to the submit effect. The submit effect calls the checkout API.

## Module kinds

| Module | Kind | Reason |
|---|---|---|
| OrderQueueFeature | feature | owns the reducer and queue state |
| OrderQueueCore | library | pure queue model, no I/O |

## Test plan by tier

- test-queued-orders-replay-in-submit-order: a queued order resubmits after reconnect — tier T1
- test-queue-persists-across-relaunch: a queued order survives a simulated relaunch — tier T2

## Observability

The client logs every enqueue, submit attempt and drop, with the queue depth at that point.

- Structured log on enqueue, submit success, submit failure and drop.

## Perf & scale

- throughput: up to 5 queued orders per device at once [UNVERIFIED]
- tail latency: submit retries back off up to 30s [UNVERIFIED]
- fan-out: 1 submit effect per queued order, run in sequence [UNVERIFIED]
- failure isolation: a failed submit doesn't block the rest of the queue [UNVERIFIED]
- resources: queue persists to on-device storage, bounded to 5 entries [UNVERIFIED]
- backpressure: a full queue rejects new orders with a clear error [UNVERIFIED]
- 10×: 50 queued orders still drain within a single retry window [UNVERIFIED]

## Risks

- The App Store review guidelines allow silent background submission of a queued order; see Open questions.
- Tail latency: submit retries back off up to 30s under sustained load; needs a longer soak test before launch.

## Open questions

- Throughput: up to 5 queued orders per device at once; to confirm in the first build's T2 run.
- Fan-out: 1 submit effect per queued order, run in sequence; to confirm in the first build's T2 run.
- Failure isolation: a failed submit doesn't block the rest of the queue; to confirm in the first build's T2 run.
- Resources: queue persists to on-device storage, bounded to 5 entries; to confirm in the first build's T2 run.
- Backpressure: a full queue rejects new orders with a clear error; to confirm in the first build's T2 run.
- Does silent background submission need explicit guest consent?
- 10×: 50 queued orders still drain within a single retry window; confirm under real device thermal throttling.

## Changelog

- 2026-09-25: drafted
