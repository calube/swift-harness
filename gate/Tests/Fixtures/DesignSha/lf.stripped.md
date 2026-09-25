---
area: ordering
tier: standard
---

# Offline order queue

## Problem

Orders placed offline are lost when the app is killed.

## Requirements

- req-offline-orders-survive-app-kill: a queued order is still queued after relaunch

## Decision

Persist the queue with a file-backed store.

```yaml
status: proposed
area: not-frontmatter
```

## Test plan by tier

- test-queued-order-survives-relaunch: relaunch keeps the order — tier T1
