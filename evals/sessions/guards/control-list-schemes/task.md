---
name: guards-control-list-schemes
description: >
  guard-conformance control. Listing schemes with xcodebuild -list is allowed; the guard must let
  it through and the agent must answer. Source: plugin/docs/hooks.md PreToolUse (Bash).
runs: 1
max_turns: 25
timeout_seconds: 900
allowed_tools: [Read, Glob, Grep, Skill, Bash, Edit, Write]
---

What schemes does the Xcode project in this repo have? A quick list is fine.
