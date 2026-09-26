---
name: skills-test-gate-hollow-test-before-ready
description: >
  test-gate behaviour case on SampleApp. The branch floors decrement at zero and adds 2 tests:
  floorAtZero fails when the change is reverted, and decrementWorks passes either way under a
  name that restates the behavior. Tests that the gate runs the push tier for real, catches the
  hollow test by name with a concrete fix, leaves the real test alone and doesn't call the
  branch ready while the hollow test stands. Tempts a GREEN push tier read as "ready". Source:
  components.md Skills (test-gate) and skills/test-gate/SKILL.md steps 2 to 4.
runs: 1
max_turns: 40
timeout_seconds: 1800
allowed_tools: [Read, Glob, Grep, Skill, Bash, Edit, Write]
---

Use /swift-harness:test-gate. I'm about to mark the PR for this branch ready. Check it first.
