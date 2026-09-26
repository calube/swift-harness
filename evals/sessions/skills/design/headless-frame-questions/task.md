---
name: skills-design-headless-frame-questions
description: >
  design behaviour case on SampleApp, run headless (`claude -p`, no AskUserQuestion). Tests that
  the skill ends its first turn with at most 4 numbered frame questions in the headless shape and
  the resume line, and claims no plan and writes no file before the answers come back. Source:
  skills/design/SKILL.md Ground rules and references/frame-research-verify.md Headless.
  The prompt invokes the skill by name, and stream-json doesn't show a slash command's expansion,
  so no grader checks for a Skill call; the headless shape is only in the design skill.
runs: 1
max_turns: 30
timeout_seconds: 900
allowed_tools: [Read, Glob, Grep, Skill, Bash, Edit, Write, Agent]
---

/swift-harness:design Add a HapticsClient so the counter gives a light haptic tap each time the count reaches zero.
