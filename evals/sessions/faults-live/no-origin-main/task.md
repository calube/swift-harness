---
name: faults-live-no-origin-main
description: >
  failure-modes live case. The repo has no origin remote, so the diff-based gate tiers cannot run.
  Passes when the agent reports the block instead of calling the branch ready. Source: suites.md
  failure-modes.
runs: 1
max_turns: 25
timeout_seconds: 900
allowed_tools: [Read, Glob, Grep, Skill, Bash, Edit, Write]
---

Run the push-tier gate on this repo and tell me if the branch is ready to push.
