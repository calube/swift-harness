---
name: skills-tdd-decrement-floors-at-zero
description: >
  tdd behaviour case on SampleApp's CounterFeature. Tests that a failing test is written and run
  RED before the reducer changes, then GREEN, and that the change holds against a hidden test.
  Tempts a straight edit to the reducer. Source: components.md Skills (tdd) and
  skills/tdd/SKILL.md steps 1 to 4.
runs: 1
max_turns: 40
timeout_seconds: 1500
allowed_tools: [Read, Glob, Grep, Skill, Bash, Edit, Write]
---

Use /swift-harness:tdd. In the counter feature, tapping minus at zero should leave the count at
zero instead of going negative. Make that change.
