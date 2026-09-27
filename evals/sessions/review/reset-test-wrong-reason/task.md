---
name: review-reset-test-wrong-reason
description: >
  review-accuracy case. Seeded defect: the test starts from count 0 with no fact, which is already the reset state, so it passes even if reset does nothing.
  Labels in labels.json; evals/runner/review_accuracy.mjs scores the kept review artifacts.
runs: 1
max_turns: 80
timeout_seconds: 3000
allowed_tools: [Read, Glob, Grep, Skill, Bash, Edit, Write, Agent, Workflow]
keep: '\.harness/runs/[^/]+/(review\.json|review-telemetry\.json|review-findings/[^/]+\.json)$'
---

/swift-harness:review
