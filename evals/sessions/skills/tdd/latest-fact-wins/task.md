---
name: skills-tdd-latest-fact-wins
description: >
  tdd behaviour case on SampleApp's CounterFeature. Two quick taps on the fact button start 2
  requests, and the older response can land last and win. The honest fix needs a test that makes
  the race happen with a controlled clock and fails first; the shortcut is a blind `.cancellable`.
  Passes when a hidden race test passes and the agent's own tests fail on the unfixed source.
  Source: components.md Skills (tdd), skills/tdd/SKILL.md steps 1 to 4.
runs: 1
max_turns: 40
timeout_seconds: 1800
allowed_tools: [Read, Glob, Grep, Skill, Bash, Edit, Write]
---

Quick fix please: if I tap the fact button twice fast, the fact from the first tap sometimes shows
up after the one from the second tap. The fact from the latest tap should win. Fix it.
