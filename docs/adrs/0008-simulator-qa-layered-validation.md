# 0008. Simulator QA validates in layers, and keeps flows in XCUITest

Status: accepted 2026-10-04, built, with 2 parts opt-in per app. Goes with the
[simulator QA amendment](../designs/2026-10-04-simulator-qa-layered-evidence-amendment.md) and the 17 decisions
in its §12. Batch flows, the recording lock and both flow rules ship. The typed id module and keep-always
attachments are opt-in per app: bootstrap stamps neither, and only `examples/SampleApp` sets them up.
Amends [ADR 0005](0005-simulator-qa-drives-agent-device.md).

## Context

[ADR 0005](0005-simulator-qa-drives-agent-device.md) made `agent-device` the agent's hands and evidence collector,
kept the regression gate in XCUITest, and left the repo with no `.ad` scripts and no Maestro YAML. Its QA run was
exploratory: the skill chose what to try once the build had finished.

The amendment plans each requirement's checks before the code exists, in 4 layers: unit, acceptance, flow and
state. A validation task writes the checks while the build runs, and they run after each merge. Prepared flows
run as `agent-device` batch steps files. That brings a steps file into a harness that had ruled out scripted
formats for the tool.

A research run on the example app measured both ways of running a flow. A warm batch flow took 4.1 to 4.5 s; a
warm XCUITest `test-without-building` took 6.5 to 7.9 s, and up to 20 s under load. The steps inside matched,
since the tool's iOS backend is itself an XCUITest bundle. The gap is the fixed cost of each `xcodebuild` call,
which T3 pays once for all its flows. The Swift compiler let an accessibility-id typo through to a 39 s run-time
failure, and an offline check against the tool's schemas and the app's ids caught it in 70 ms. The step schemas
held across 0.21.16, 0.21.18 and 0.21.20.

## Decision

1. **Batch flows serve 1 run.** A prepared or final-pass flow is an `agent-device` batch steps file in a `qa/`
   folder outside the tracked tree: the validation worktree's `.harness/qa/<plan>/`, which the orchestrator
   copies into plan state. `swiftgate qa run` runs it on the device `sim up` leased. No gate replays it across
   runs, and the repo still holds no steps file.
2. **Kept flows stay XCUITest.** A flow worth keeping becomes a T3 XCUITest plus a `[[flows]]` entry, as [ADR 0005](0005-simulator-qa-drives-agent-device.md)
   decided. The app and its UI tests share a typed accessibility-id module, so an id typo fails to compile. When the app's
   test plan keeps attachments always, as `examples/SampleApp`'s does, a kept flow leaves an MP4 and per-step activities on a pass. Both flow sources
   normalise to 1 `qa.flow` record for the report.
3. **1 recording at a time per Mac.** The Mac allows 1 simulator recording at once, whoever started it. A
   machine-wide recording lock with 1 slot orders the harness's final passes. When another session holds a
   recording, `qa run --final` retries every 15 s for up to 5 minutes, then runs the flow without video and marks
   the video `unverified`. The row's pass never depends on video.
4. **2 offline flow rules.** Before any step runs, `qa.flow-schema` checks each step's input against the pinned
   tool's schemas, captured from its MCP `tools/list`, and `qa.flow-unknown-id` checks each `id="…"` selector
   against the ids the typed module declares. Each ships with a captured fixture and a rule-index row.

The pin moves to 0.21.18, and any bump recaptures the fixtures and the schemas.

## Consequences

- The [ADR 0005](0005-simulator-qa-drives-agent-device.md) rule "the repo holds no `.ad` scripts and no Maestro YAML" holds: steps files live outside the
  tracked tree and serve 1 run.
- A prepared flow that proves its worth needs a port to XCUITest. The contract-named identifiers carry over, so
  the port is mechanical.
- The regression gate still compiles against the app and runs in T3. Batch runs gain speed from skipping
  `xcodebuild`, not from faster steps.
- Final passes from 2 sessions on 1 Mac queue for the recording lock, and a recording outside the harness can
  leave a video `unverified`.
- The harness now parses the tool's step schemas too, so a version bump recaptures them with the other fixtures.
- Revisit kept flows in batch only if the step schemas hold across several minor releases and `xcodebuild`'s
  fixed cost starts to dominate kept-flow time.
