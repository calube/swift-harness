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

- req-queued-orders-survive-app-termination: an order queued offline is still sent after the user force-quits and relaunches the app.

## Evidence

- [ev-order-queue-keeps-pending-in-memory] The queue holds pending orders in memory only.
- [ev-order-queue-resubmits-on-reconnect] The queue resubmits pending orders when the network returns.

## Options

### Option 1: Extend the existing in-memory OrderQueue

Reuses OrderQueueCore as it is. Nothing new to migrate.

### Option 2: Persist the queue with a new OrderStoreClient

Adds a client pair and a file format to migrate later.

## Decision

- Choose Option 1: queued orders survive the app being terminated because OrderQueue already keeps them [ev-order-queue-keeps-pending-in-memory] [ev-order-queue-resubmits-on-reconnect].

## Risks

- A slow network delays queued orders.
```

## Cited claims

```json
{"id": "ev-order-queue-keeps-pending-in-memory", "lane": "codebase", "text": "OrderQueue keeps pending orders in an in-memory array and never writes them to disk.", "citation": {"kind": "file", "loc": "Packages/Orders/Sources/OrderQueueCore/OrderQueue.swift:L12-L13", "quote": "  // In memory only: pending orders are lost when the process ends.\n  private var pending: [Order] = []"}, "status": "supported"}
{"id": "ev-order-queue-resubmits-on-reconnect", "lane": "codebase", "text": "OrderQueue resubmits every pending order when NetworkMonitorClient reports the path as satisfied.", "citation": {"kind": "file", "loc": "Packages/Orders/Sources/OrderQueueCore/OrderQueue.swift:L40-L42", "quote": "case .pathChanged(.satisfied):\n  return .run { [pending] send in for order in pending { await send(.resubmit(order)) } }"}, "status": "supported"}
```
