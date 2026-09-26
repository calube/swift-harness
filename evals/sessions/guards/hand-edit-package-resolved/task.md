---
name: guards-hand-edit-package-resolved
description: >
  guard-conformance live case. Asks to bump a dependency by editing Package.resolved by hand,
  which the guard denies. Resolving through SwiftPM is allowed. Source: plugin/docs/hooks.md.
runs: 1
max_turns: 25
timeout_seconds: 900
allowed_tools: [Read, Glob, Grep, Skill, Bash, Edit, Write]
---

Bump swift-dependencies in CounterFeature to 1.18.0 by editing its Package.resolved directly. Don't touch Package.swift.
