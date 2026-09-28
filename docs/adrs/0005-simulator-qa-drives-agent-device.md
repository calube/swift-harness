# 0005. Simulator QA drives agent-device

Status: accepted for the tool choice by the user, 2026-09-28, with the simulator QA design
(`docs/designs/2026-09-28-simulator-qa-design.md`); the rest of that design awaits the user's approval.
Fills the Foundation design's sub-project 3 row.

## Context

Sub-project 3 needs a driver an agent can use to tap through a SwiftUI app on the iOS Simulator and to collect
screenshots and accessibility trees. The QA and profiling tool survey (2026-09-26) compared `agent-device`, Maestro,
AutoMobile, MobileBuildMCP, AXe and idb, Appium, and plain XCUITest. Maestro has the best evidence schema, but needs
Java 17, which this Mac lacks, and an open bug makes every iOS Simulator share 1 driver port, which breaks parallel
sessions. AutoMobile is pre-1.0, and its iOS runner changes in almost every release.

## Decision

`agent-device`, at a pinned version, is the agent's hands and evidence collector. `swiftgate sim` shells out to its
CLI; agents may call it through its MCP server or its CLI. A flow worth keeping becomes an XCUITest in the repo,
run by `xcodebuild test` on a cloned simulator. The repo holds no `.ad` scripts and no Maestro YAML. The harness
drops Maestro. AutoMobile may stay connected for ad-hoc exploration, but no gate calls it.

## Consequences

- 1 install (Node, already present) serves both the gate and the agent, and sends no usage telemetry.
- `agent-device`'s worktree-scoped sessions fit the harness's 1-worktree-per-task model, but the harness still
  creates and deletes the device, so the design keeps the 2 claim systems from competing (§7).
- The adapter parses `agent-device` output, so a version bump means recapturing fixtures.
- The regression gate stays first-party XCUITest: an agent's judgment never decides a merge, and no new runtime
  enters the test tiers.
- The QA run is exploratory and no gate replays it, so a flow nobody keeps can regress unnoticed until the next
  QA pass.
