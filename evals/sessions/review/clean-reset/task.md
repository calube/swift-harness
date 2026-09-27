---
name: review-clean-reset
description: >
  review-accuracy case. Clean control: a correct change with an exhaustive test; expect merge and no major finding.
  Labels in labels.json; evals/runner/review_accuracy.mjs scores the kept review artifacts.
runs: 1
max_turns: 80
timeout_seconds: 3000
allowed_tools: [Read, Glob, Grep, Skill, Bash, Edit, Write, Agent, Workflow]
keep: '\.harness/runs/[^/]+/(review\.json|review-findings/[^/]+\.json)$'
---

/swift-harness:review
