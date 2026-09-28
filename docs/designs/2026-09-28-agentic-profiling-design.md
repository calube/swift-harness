# swift-harness: agentic profiling (sub-project 4)

<!-- RESUME
Status: PROPOSED 2026-09-28. The user made the 4 decisions in §2 and §9; every other choice is marked Proposed and
listed in §12 for approval.
Why: the foundation design's sub-project map row for 4 ("`swiftgate profile` / `leaks`: xctrace + `leaks` summarized
to compact JSON; signpost-scoped measurements; XCTMetric baselines") and the build executor's `validate` stage (§8.6,
§15), which calls sub-projects 3 and 4 once they exist.
Evidence: the QA and profiling tool survey (2026-09-26), sections 1, 3, 4, 5 and 6. Its probes ran on this laptop
against examples/SampleApp.
Depends on: sub-project 3, simulator QA (docs/designs/2026-09-28-simulator-qa-design.md), for flow replay. The
dependency runs one way: 4 uses 3, and 3 never reads anything 4 writes.
Decision record: [ADR 0006](../adrs/0006-profiling-wraps-xctrace-report-only-first.md), proposed.
Read first: this header, then §2, then §5 and §12.
-->

## 1. Purpose

Give an agent a cheap, repeatable answer to "did this change make the app slower or heavier?" on the Simulator, as
compact JSON a gate and a reviewer can read. Every measurement comes from Apple's own tools, and `swiftgate` owns the
parsing, so no hook, skill or workflow re-implements a check.

### Non-goals

- A device lane. The SwiftUI instrument, Animation Hitches, MetricKit and representative absolute timings need a
  physical device. They stay out of scope for now and may arrive later as an optional addition (§11).
- Blocking on a regression. Findings report only until noise bands exist (§7).
- A general Instruments front end. The gate reads the few tables it needs; a human opens the `.trace` for the rest.

## 2. Decision map

| Decision | Choice | By | Section |
|---|---|---|---|
| Capture layer | `swiftgate profile` wraps `xcrun xctrace` and `footprint` and emits compact JSON; the gate owns the parsing | user | §3 |
| agent-device `perf` | ad-hoc agent investigation only; its output never feeds the gate | user | §3.3 |
| Platform | Simulator only: Time Profiler, App Launch, Hangs, `footprint` peak, os_signpost intervals per span, XCTMetric tests | user | §4 |
| Gating | report only until enough runs set per-metric noise bands; a later change turns on blocking beyond them | user | §7 |
| Leak evidence | XCTest-level checks (weak refs after deinit) by default, overridable to the host `leaks` tool | user | §9 |
| Command surface and JSON schema | `profile`, `profile calibrate`, `leaks`; schema 1 | Proposed | §5 |
| Before/after in 1 job | interleaved base and head runs on 1 cloned simulator | Proposed | §6 |
| Where baselines live | per host, in the git common dir, never committed | Proposed | §7 |
| Scenario choice | launch always, plus the `[[flows]]` the diff reaches | Proposed | §8 |
| Machine-time budget | 1 profile run on the machine at a time, 6 min default ceiling | Proposed | §10 |

## 3. Architecture

### 3.1 Layers

- **`SwiftGateAdapters`**: a `TraceRecorder` protocol with an `XctraceRecorder` that runs `xcrun xctrace record`
  and `xctrace export --xpath`, a `FootprintSampler` over `footprint -p <pid> -j`, and a `FlowDriver` protocol whose
  live value calls sub-project 3's replay command. The simulator clone and its lock come from the same adapter T2
  and T3 use.
- **`SwiftGateDomain`**: pure parsers from xctrace export XML and `footprint` JSON into typed samples, the statistics
  (median, median absolute deviation, delta), and the verdict per metric. No `Process` or `FileManager` IO.
- **`SwiftGateCLI`**: wires the adapters to the domain and prints.

### 3.2 What xctrace records on the Simulator

The survey's probes on Xcode 26.2 and macOS 26.5.1 set the capture plan:

| Measure | Template or tool | Table the gate parses |
|---|---|---|
| CPU self time, top functions | Time Profiler | `time-profile` |
| Hangs | Time Profiler with `--instrument Hangs` | `potential-hangs`, `hang-risks` |
| Launch duration | App Launch, `--launch` | `life-cycle-period` |
| Span durations | Time Profiler (it records os_signpost too) | `os-signpost-interval` |
| Memory peak | `footprint -j` at scenario end | `phys_footprint_peak` |

There is no Hangs template and no os_signpost template. One Time Profiler recording with the Hangs instrument
yields CPU, hangs and signpost intervals together, so a scenario needs 1 recording plus 1 App Launch recording.
The Allocations template records, but its export has no allocation tables, so the gate doesn't use it.

### 3.3 Where agent-device fits

An agent that wants a quick look during a fix may run agent-device's `perf` commands. That output is for the agent's
own reasoning. It never becomes a finding, a baseline or evidence in `.harness/runs/`, because its report shape
(top 10 functions) isn't under the gate's control and doesn't cover signpost intervals.

## 4. Measures

| Metric id | Source | Unit |
|---|---|---|
| `launch.duration` | App Launch, `life-cycle-period` | ms |
| `cpu.total` | Time Profiler sample count × interval, in the app process | ms |
| `cpu.top` | the 10 heaviest symbols by self time, as a list, not a scalar | ms each |
| `hangs.count`, `hangs.longest` | `potential-hangs` | count, ms |
| `memory.peak` | `footprint` `phys_footprint_peak` | MB |
| `span.<name>` | `os-signpost-interval`, median per span name | ms |
| `xctmetric.<test>.<metric>` | XCTMetric tests, read from the xcresult | the metric's own unit |

Span names come from `TracingClient`. Its live value maps each `withSpan` to an `OSSignposter` interval with a
`StaticString` name (foundation design, Observability), so the spans an app already emits become measurements with
no profiling code in the app. An app with no `TracingClient` gets launch, CPU, hangs and memory only; the summary says
so.

Simulator CPU runs on the Mac's cores, so an absolute number means nothing off this host. Every metric compares a
base and a head measured on the same host in the same job (§6).

## 5. Command surface (Proposed)

```
swiftgate profile [--base <ref>] [--scenario <name>]... [--runs <n>] [--budget-min <m>] [--keep-traces] [--json]
swiftgate profile calibrate [--scenario <name>]... [--runs <n>]
swiftgate leaks [--mode xctest|host]
```

- `profile` with no `--base` measures `HEAD` alone and prints absolute values with no verdicts.
- `profile --base <ref>` builds both sides and reports deltas. `validate` passes the merge base.
- `profile calibrate` runs head against itself (an A/A run) to measure noise, and appends the result to the host's
  history (§7).
- `leaks` runs the leak check the profile's mode selects (§9).

Exit codes follow the rest of `swiftgate`: 0 when nothing gates, 1 on a gating finding, 2 when the command can't
run. While profiling is report only, `profile` exits 0 on a regression and 2 only when it couldn't run at all.

### 5.1 Output, schema 1

`.harness/runs/<id>/profile.json` holds the full report; `--json` prints it.

```json
{
  "schema": 1,
  "host": {"model": "Mac16,5", "xcode": "26.2", "simulator": "iPhone 17 / iOS 26.2"},
  "base": "3f2a91c", "head": "7b6d49f", "runs": 3,
  "scenarios": [{
    "name": "counter",
    "metrics": [{
      "id": "span.counter.increment", "unit": "ms",
      "base": {"median": 4.1, "mad": 0.3}, "head": {"median": 5.0, "mad": 0.4},
      "delta_pct": 22.0, "band_pct": null, "verdict": "report"
    }],
    "cpu_top": [{"symbol": "CounterFeature.reduce", "base_ms": 12, "head_ms": 19}],
    "hangs": [],
    "evidence": ["profile/counter-head-1.xml"]
  }],
  "findings": []
}
```

`band_pct` is `null` until the metric has a noise band. `verdict` is a closed enum: `report`, `within-band`,
`regressed`, `improved`. While profiling is report only, a regression carries verdict `regressed` and a non-gating
finding. The CLI prints 1 line per scenario and a line per metric whose delta passes 10%, so an agent reads under 1 KB,
not the trace.

### 5.2 Findings

| Rule id | Severity | Meaning |
|---|---|---|
| `profile.regressed` | note while report only | a metric's head median exceeds base by more than its band, or by 10% with no band |
| `profile.capture-failed` | note | a recording or export failed; names the scenario, template and stderr's first line |
| `profile.no-evidence` | note | a scenario produced no parseable table |
| `profile.no-spans` | note | the app emitted no `os-signpost-interval` rows |
| `profile.budget-exceeded` | note | the run stopped at its budget; names the scenarios left unmeasured |
| `profile.summary` | note | the per-scenario count and wall time |
| `leaks.host-unavailable` | note | host mode was asked for and `leaks` failed; names the error |

The rule index rows in `plugin/docs/standards.md` land with the checks, in the same change, per the repo rule.

## 6. Before and after in 1 job (Proposed)

`profile --base` builds base and head into separate derived-data paths with `-skipMacroValidation` (the survey found a
fresh derived-data path fails without it). It installs both on 1 cloned simulator under distinct bundle ids, then runs
the scenarios interleaved: base, head, base, head, and so on, `--runs` times per side (default 3). Interleaving cancels
drift from thermal state and background load, which a base measured earlier can't. Each side reports the median and
the median absolute deviation, which a single outlier run doesn't move.

The recorder launches the app with `--launch` or attaches by process name. The survey found `--attach <pid>` fails on a
Simulator pid while `--attach <name>` works; distinct bundle ids keep the names apart on 1 simulator.

A `.trace` from App Launch reached 73 MB for 6 s in the survey. The recorder exports the tables it needs, then deletes
the trace unless the caller passes `--keep-traces`.

## 7. Baselines, variance and the move to blocking

Noise bands come from history, not from a guess.

- **Proposed: where history lives.** `$(git rev-parse --git-common-dir)/swift-harness/profile/<host-key>.jsonl`, 1 line
  per metric per run. The host key hashes the Mac model, Xcode version, simulator device and OS. Every worktree
  shares it and no commit carries it, since a Simulator number from 1 Mac says nothing about another.
- **Proposed: what counts as a sample.** Every `profile calibrate` run and every `profile --base` run's per-side
  medians add to the history. A calibrate run gives the cleanest noise estimate, since both sides run the same code.
- **Proposed: the band.** Once a metric has 20 A/A samples from at least 5 separate sessions, its band is the 95th
  percentile of the absolute A/A delta. Until then `band_pct` stays `null` and the fallback note fires at 10%.
- **User decision: blocking waits.** Every profiling finding is non-gating now. A later change, with its own design
  note, turns on blocking for metrics that have a band, as a `major` finding beyond it. That change cites the history.

XCTMetric tests keep Xcode's own baselines out of the picture: Xcode keys them per device model and host, which
doesn't survive cloned simulators. `swiftgate` reads each measure block's values from the xcresult and applies the
same base-versus-head comparison.

## 8. Scenarios (Proposed)

A scenario is a named flow the profiler drives while it records.

- **Launch** runs every time: App Launch, cold, with no flow.
- **Flow scenarios** reuse the `[[flows]]` entries in `.swiftgate.toml` that T3 and sub-project 3 already declare.
  `validate` picks the flows whose modules the diff reaches, using the same `impact` data the push tier computes, and
  caps them at 3. `--scenario` names them by hand.
- **XCTMetric tests** are T2 tests that call `measure(metrics:)` for the hot paths a plan names. `profile` runs them
  with `xcodebuild test -only-testing` on the same clone.

Sub-project 3 owns flow replay. The `FlowDriver` adapter calls its replay command with the flow name and waits for
its exit; profiling adds no flow format of its own. If the repo hasn't set up sub-project 3, flow scenarios report
`profile.no-evidence` naming the missing driver, and launch and XCTMetric still run.

## 9. Leaks

The host `leaks` tool and the Leaks template both failed on this laptop in the survey, on iOS 18.6 and 26.2
simulators. Fixing it needs Developer mode (`DevToolsSecurity -enable`), which only the user can turn on.

- **Default, by the user's decision: `leak_check = "xctest"`.** Leak evidence comes from XCTest-level checks. A test
  creates the object, holds a weak reference, drops the strong ones, and asserts the weak reference is `nil`. The
  testing playbook gains this as a pattern for stores and live clients. `swiftgate leaks` in this mode runs those
  tests through the normal tiers and reports their count.
- **Override: `leak_check = "host"`** in the profile's `[profile]` table. `swiftgate leaks` then runs
  `leaks <pid> --outputGraph` at scenario end and parses the leak count and root types. A host failure is a
  `leaks.host-unavailable` note, never a quiet pass.

## 10. Machine time (Proposed)

This laptop wedged at load 100+ with 4 ready tiers at once, and a single ready tier reached load 264 (orchestrator
runbook). Profiling measures timing, so load corrupts it.

- 1 profile run on the machine at a time, and never beside a ready tier or `mutate`. `profile` waits on the same
  process check the runbook uses, then takes the simulator lock.
- It records the 1-minute load average at each run's start and end in `profile.json`. A run that starts above the
  core count still yields numbers, marked `"noisy": true`; noisy runs never enter the history.
- Default budget: 6 min wall time. Launch and 1 flow at 3 runs per side is 12 recordings of up to 10 s each, plus 2
  builds. `[profile] budget_min` or `--budget-min` changes it; the run stops at the budget and reports what it skipped.

## 11. Where it runs

- **`/swift-validate` and the build executor's `validate` stage** run `swiftgate leaks`, then `profile --base
  <merge base>`, after sub-project 3's QA and after the `ready` tier. Findings go into the evidence summary and the
  PR-body block. The stage stays non-gating for profiling, per §7.
- **Proposed: sprint.** A sprint finish runs `validate` only when the preset sets `validate = true`. The timed
  presets leave it off, since 6 min doesn't fit a timed session.
- **Proposed: fixtures.** Parser fixtures under `plugin/gate/Tests/Fixtures/profile/` come from real `xctrace export
  --xpath` runs against `examples/SampleApp` on the pinned Xcode, 1 per table in §3.2, plus 1 `footprint -j` file and
  1 xcresult with a measure block. Each capture command goes in the fixtures README. The narrow `--xpath` keeps them
  small without hand edits. A change to the Xcode pin recaptures them.
- **Later, optional: the device lane.** The SwiftUI instrument, hitches and representative timings, on a physical
  device, when the user wants it.

## 12. Open for approval

The user hasn't approved any item below yet; §2 holds the user's decisions.

1. Command surface: `profile [--base]`, `profile calibrate`, `leaks [--mode]` (§5).
2. JSON schema 1 and the closed verdict enum (§5.1).
3. The findings list and their note severity (§5.2).
4. Interleaved base and head runs on 1 clone, 3 per side, median and MAD (§6).
5. Deleting traces after export unless `--keep-traces` (§6).
6. Noise history per host in the git common dir, never committed (§7).
7. The band rule: 20 A/A samples over 5 sessions, 95th percentile; 10% fallback note until then (§7).
8. Scenarios: launch always, plus up to 3 `[[flows]]` the diff reaches, driven by sub-project 3 (§8).
9. XCTMetric results read from the xcresult, not Xcode's own baselines (§7, §8).
10. 1 profile run at a time, noisy runs kept out of history, 6 min default budget (§10).
11. Sprint runs `validate` only on a preset's opt-in (§11).
12. Fixtures from narrow `xctrace export --xpath` runs on `examples/SampleApp`, recaptured on an Xcode pin change (§11).
