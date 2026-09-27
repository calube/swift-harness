---
name: review-errors-swallowed
description: >
  review-accuracy case. Seeded defect: every transport, status and decoding failure returns a placeholder Fact instead of throwing, so the reducer never reaches factFailed, the error is never logged, and the user sees made-up text as a fact.
  Labels in labels.json; evals/runner/review_accuracy.mjs scores the kept review artifacts.
runs: 1
max_turns: 80
timeout_seconds: 3000
allowed_tools: [Read, Glob, Grep, Skill, Bash, Edit, Write, Agent, Workflow]
keep: '\.harness/runs/[^/]+/(review\.json|review-findings/[^/]+\.json)$'
---

/swift-harness:review
