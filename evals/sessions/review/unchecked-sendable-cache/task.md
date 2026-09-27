---
name: review-unchecked-sendable-cache
description: >
  review-accuracy case. Seeded defect: `last` is read and written from whatever task calls randomFact, with no lock or actor; the allow reason ("main thread") is false, so concurrent fact requests race.
  Labels in labels.json; evals/runner/review_accuracy.mjs scores the kept review artifacts.
runs: 1
max_turns: 80
timeout_seconds: 3000
allowed_tools: [Read, Glob, Grep, Skill, Bash, Edit, Write, Agent, Workflow]
keep: '\.harness/runs/[^/]+/(review\.json|review-findings/[^/]+\.json)$'
---

/swift-harness:review
