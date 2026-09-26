This run gives you no tools. Your context pack is inline below, and it holds everything you
would otherwise read from disk.

# Evidence auditor pack

## Design doc

```markdown
---
status: proposed
area: ordering
tier: standard
---

# Offline order queue

## Problem

Orders placed while the phone has no signal fail and the user has to place them again.

## Requirements

- req-queued-orders-retry-after-signal-returns: an order queued offline is sent, without the user acting, once the network returns while the app is running.

## Evidence

- [ev-order-queue-keeps-pending-in-memory] The queue holds pending orders in memory only.
- [ev-order-queue-resubmits-on-reconnect] The queue resubmits pending orders when the network returns.
- [ev-order-queue-sends-one-at-a-time] The queue sends one order at a time.

## Options

### Option 1: Extend the existing in-memory OrderQueue

Reuses OrderQueueCore as it is. Nothing new to migrate.

### Option 2: Persist the queue with a new OrderStoreClient

Adds a client pair and a file format to migrate later.

## Decision

- Choose Option 1: while the app runs, OrderQueue holds queued orders in memory and resubmits them when the network returns [ev-order-queue-keeps-pending-in-memory] [ev-order-queue-resubmits-on-reconnect].
- The queue keeps sending one order at a time [ev-order-queue-sends-one-at-a-time].

## Perf & scale

- fan-out: one order request in flight at a time [ev-order-queue-sends-one-at-a-time].

## Risks

- Queued orders are lost if the app is terminated before the network returns, because the queue lives in memory only; the requirement covers only a running app.
```

## Cited claims

```json
{"id": "ev-order-queue-keeps-pending-in-memory", "lane": "codebase", "text": "OrderQueue keeps pending orders in an in-memory array and never writes them to disk.", "citation": {"kind": "file", "loc": "Packages/Orders/Sources/OrderQueueCore/OrderQueue.swift:L12-L13", "quote": "  // In memory only: pending orders are lost when the process ends.\n  private var pending: [Order] = []"}, "status": "supported"}
{"id": "ev-order-queue-resubmits-on-reconnect", "lane": "codebase", "text": "OrderQueue resubmits every pending order when NetworkMonitorClient reports the path as satisfied.", "citation": {"kind": "file", "loc": "Packages/Orders/Sources/OrderQueueCore/OrderQueue.swift:L40-L42", "quote": "case .pathChanged(.satisfied):\n  return .run { [pending] send in for order in pending { await send(.resubmit(order)) } }"}, "status": "supported"}
{"id": "ev-order-queue-sends-one-at-a-time", "lane": "codebase", "text": "OrderQueue sends one order request at a time.", "citation": {"kind": "file", "loc": "Packages/Orders/Sources/OrderQueueCore/OrderQueue.swift:L48-L48", "quote": "try await orders.submit(order)  // serial: one request in flight"}, "status": "supported"}
```
