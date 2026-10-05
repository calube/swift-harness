# 0006. Profiling wraps xctrace, and reports before it blocks

Status: accepted 2026-09-28, not built. The harness froze before profiling shipped: `swiftgate` has no `profile`
or `leaks` command. Goes with the [agentic profiling design](../designs/2026-09-28-agentic-profiling-design.md),
and fills the profiling row of the [Foundation design](../designs/2026-09-24-swift-harness-foundation-design.md)'s
map.

## Context

The harness needs a profiling check an agent can run and a gate can read. The QA and profiling tool survey
(2026-09-26) probed this laptop. On the Simulator, `xcrun xctrace` records Time Profiler, App Launch, Hangs and
os_signpost intervals, and `footprint -j` gives a memory peak, all headless. The SwiftUI and Animation Hitches
instruments refuse the Simulator. The host `leaks` tool and the Leaks template failed on both simulator runtimes.
The likely fix needs Developer mode, which only the user can enable. agent-device's `perf` commands offer a simpler
capture layer, but their report shape isn't under the gate's control and they don't cover signpost intervals.
Simulator timings run on the Mac's cores and have no measured run-to-run variance yet.

## Decision

`swiftgate profile` wraps `xcrun xctrace` and `footprint` itself, and the gate owns the parsing into compact JSON.
agent-device `perf` stays an ad-hoc tool for agents and never feeds the gate.

Profiling is Simulator only: Time Profiler, App Launch, Hangs, the `footprint` peak, os_signpost intervals per span,
and XCTMetric tests. A device lane is out of scope for now.

Every profiling finding is report only until enough runs exist to set a noise band per metric. A later change turns
on blocking beyond those bands.

Leak evidence defaults to XCTest-level checks (a weak reference is `nil` after the object's owner releases it). A
repo may override it to the host `leaks` tool once that works on its machine.

## Consequences

These would hold once profiling ships; none applies to the frozen harness.

- No new dependency, and the check lives in `plugin/gate/` like every other check.
- A regression shows up in `validate`'s evidence and the PR body but can't fail a build yet. A real slowdown can
  merge; the finding still names it.
- Blocking needs a history of A/A runs per host first, so the design records noise, not only deltas.
- SwiftUI body cost and hitches stay unmeasured. The standards' SwiftUI rows stay review-enforced, with signpost spans
  and Time Profiler as the Simulator proxy.
- Leak coverage is only as good as the weak-reference tests a change adds, until the host tool works.
