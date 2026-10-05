import Foundation
import SwiftGateDomain
import Testing

@Suite("run view contract")
struct RunViewContractTests {
  private let start = Date(timeIntervalSince1970: 1_790_000_000.25)

  private var view: RunView {
    RunView(
      run: RunView.Run(id: "b1", plan: "p", preset: "standard", startedAt: start, state: .running),
      spec: [RunView.SpecRow(id: "req-a", title: "A", tasks: ["t1"])],
      tasks: [
        RunView.Task(
          id: "t1", status: .inProgress, model: .opus, deps: ["t0"], writes: ["Sources/A.swift"],
          gate: .push, covers: ["req-a"], createdAt: start,
          brief: RunView.Brief(title: "Do A", why: "Because", scope: ["a"]))
      ],
      roles: [RunView.Role(role: .buildWorker, tokens: RunView.Tokens(input: 1))],
      spans: [
        RunView.Span(id: "s1", phase: .worker, task: "t1", start: start),
        RunView.Span(
          id: "s2", parent: "s1", phase: .step, start: start, end: start, outcome: .ok,
          approximate: true,
          tools: RunView.ToolSummary(calls: [ToolCallCount(tool: .read, count: 1, milliseconds: 2)])
        ),
      ],
      gates: [
        RunView.Gate(
          runID: "g1", verdict: .green, milliseconds: 9,
          steps: [
            RunView.GateStepRow(
              tier: .t0, step: .lint, startMs: nil, milliseconds: 3, verdict: .green)
          ])
      ],
      proofs: [RunView.Proof(gateRun: "g1", test: "T/a()", outcome: .passesReverted)],
      halts: [RunView.Halt(reason: .question, at: start)],
      damage: [RunView.Damage(source: "events/gate.jsonl", reason: "line 3: not JSON")])
  }

  private func keys(_ value: Any?) -> Set<String> {
    Set((value as? [String: Any])?.keys.map { $0 } ?? [])
  }

  private func first(_ value: Any?) -> [String: Any] {
    ((value as? [Any])?.first as? [String: Any]) ?? [:]
  }

  @Test(
    "a RunView encodes the design's keys and no other, absent values as null — catches a renamed or dropped key the page won't read"
  )
  func encodesDesignKeys() throws {
    let data = try RunViewJSON.encode(view)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(
      keys(object) == [
        "schemaVersion", "cursor", "run", "spec", "tasks", "roles", "cost", "spans", "gates",
        "proofs", "halts", "validation", "damage", "unwritten", "evidenceBase", "evidenceFiles",
        "finalReport",
      ])
    #expect(object["schemaVersion"] as? Int == 1)
    #expect(object["cursor"] is NSNull)
    #expect(object["validation"] is NSNull)
    #expect(object["finalReport"] is NSNull)
    #expect(
      keys(object["run"]) == [
        "id", "plan", "preset", "startedAt", "endedAt", "state", "stallMin", "timeBox",
        "snapshotAt",
      ])
    #expect((object["run"] as? [String: Any])?["stallMin"] is NSNull)
    #expect((object["run"] as? [String: Any])?["timeBox"] is NSNull)
    #expect((object["run"] as? [String: Any])?["endedAt"] is NSNull)
    #expect(keys(first(object["spec"])) == ["id", "title", "tasks"])

    let task = first(object["tasks"])
    #expect(
      keys(task) == [
        "id", "status", "model", "deps", "writes", "gate", "covers", "commits", "gateRun",
        "mergeGateRun", "createdAt", "mergedAt", "brief", "tokens", "blocked", "failureReason",
      ])
    #expect(task["blocked"] is NSNull)
    #expect(task["failureReason"] is NSNull)
    #expect(task["tokens"] is NSNull)
    #expect(task["mergedAt"] is NSNull)
    #expect(task["status"] as? String == "in-progress")
    #expect(
      keys(task["brief"]) == ["title", "why", "designRef", "scope", "acceptance", "outOfScope"])
    #expect(keys(first(object["roles"])) == ["role", "tokens", "costUSD", "unpriced"])
    #expect(first(object["roles"])["costUSD"] is NSNull)
    #expect(
      keys((first(object["roles"]))["tokens"]) == ["input", "output", "cacheRead", "cacheWrite"])

    let spans = try #require(object["spans"] as? [[String: Any]])
    let spanKeys: Set<String> = [
      "id", "parent", "phase", "task", "gateRun", "start", "end", "outcome", "approximate", "tools",
      "causeGateRun", "failureReason", "baseline", "flow",
    ]
    #expect(spans.map(keys) == [spanKeys, spanKeys])
    #expect(spans[0]["failureReason"] is NSNull)
    #expect(spans[0]["baseline"] as? Bool == false)
    #expect(spans[0]["end"] is NSNull)
    #expect(spans[0]["tools"] is NSNull)
    #expect(spans[0]["causeGateRun"] is NSNull)
    #expect(spans[0]["flow"] is NSNull)
    #expect(keys(spans[1]["tools"]) == ["calls", "otherCount", "ms", "files", "droppedPaths"])
    #expect(
      keys(first((spans[1]["tools"] as? [String: Any])?["calls"])) == ["tool", "count", "ms"])

    let gate = first(object["gates"])
    #expect(
      keys(gate) == [
        "runId", "task", "command", "verdict", "ms", "tests", "ruleCounts", "steps", "failure",
      ])
    #expect(gate["failure"] is NSNull)
    #expect(keys(first(gate["steps"])) == ["tier", "step", "startMs", "ms", "verdict"])
    #expect(first(gate["steps"])["startMs"] is NSNull)
    #expect(
      keys(first(object["proofs"])) == [
        "gateRun", "task", "test", "outcome", "proofBase", "assertion",
      ])
    #expect(
      keys(first(object["halts"])) == ["task", "reason", "at", "answer", "waitMs", "gateRun"])
    #expect(first(object["halts"])["gateRun"] is NSNull)
    #expect(keys(first(object["damage"])) == ["source", "reason"])
  }

  @Test(
    "a RED gate's failure encodes its tiers, findings, failing tests, report and command, absent values as null — catches a failure key the page won't read"
  )
  func encodesGateFailureKeys() throws {
    var view = view
    view.gates[0].verdict = .red
    view.gates[0].failure = RunView.GateFailure(
      checkTier: .push, stage: .merge, tiers: [.t2],
      findings: [
        RunView.FailureFinding(
          rule: "t2.test-failed", severity: .major, file: nil, line: nil, message: "m",
          truncated: false)
      ], moreFindings: 2, failedTests: [RunView.FailedTest(test: "T.a/b")], moreFailedTests: 1,
      command: "swiftgate events list --run g1")
    let object = try #require(
      JSONSerialization.jsonObject(with: try RunViewJSON.encode(view)) as? [String: Any])
    let failure = try #require(first(object["gates"])["failure"] as? [String: Any])
    #expect(
      keys(failure) == [
        "checkTier", "stage", "tiers", "findings", "moreFindings", "failedTests",
        "moreFailedTests", "report", "command",
      ])
    #expect(failure["report"] is NSNull)
    #expect(failure["checkTier"] as? String == "push")
    #expect(failure["tiers"] as? [String] == ["T2"])
    let finding = first(failure["findings"])
    #expect(keys(finding) == ["rule", "severity", "file", "line", "message", "truncated"])
    #expect(finding["file"] is NSNull)
    #expect(finding["line"] is NSNull)
    let test = first(failure["failedTests"])
    #expect(keys(test) == ["test", "tier", "proof", "file", "line"])
    #expect(test["proof"] is NSNull)
  }

  @Test(
    "a validation section encodes its plan, counts and each row's keys, absent values as null — catches a validation key the page won't read"
  )
  func encodesValidationKeys() throws {
    var view = view
    view.validation = RunViewValidation(
      plan: "p", counts: RunViewValidation.Counts(red: 1),
      rows: [
        RunViewValidation.Row(
          row: 1, requirement: "req-a", layer: .acceptance, result: .red, qaRun: "q1", at: start,
          history: [
            RunViewValidation.Attempt(qaRun: "q1", stage: .atBase, result: .red, at: start)
          ]),
        RunViewValidation.Row(
          row: 2, requirement: "req-a", layer: .flow, result: .pass, qaRun: "q1", at: start,
          flow: RunViewFlow(
            source: .batch, run: "q1",
            steps: [RunViewFlow.Step(n: 1, label: nil, offsetMs: 0, ok: true)],
            videoUnverified: .recorderBusy)),
      ],
      keptFlows: [
        RunViewKeptFlow(
          name: "counter", test: nil, gateRun: "g1", at: start,
          flow: RunViewFlow(source: .xcuitest, run: "g1"))
      ])
    let object = try #require(
      JSONSerialization.jsonObject(with: try RunViewJSON.encode(view)) as? [String: Any])
    let validation = try #require(object["validation"] as? [String: Any])
    #expect(keys(validation) == ["plan", "counts", "rows", "keptFlows"])
    #expect(
      keys(validation["counts"]) == ["pass", "red", "unverified", "waiting", "abandoned", "atBase"])
    let row = first(validation["rows"])
    #expect(
      keys(row) == [
        "row", "requirement", "layer", "check", "runsAfter", "result", "message", "exitStatus",
        "ms", "evidence", "waitingOn", "qaRun", "at", "output", "outputCut", "flow", "atBase",
        "history", "lastPass",
      ])
    #expect(row["flow"] is NSNull)
    #expect(row["lastPass"] is NSNull)
    let attempt = first(row["history"])
    #expect(
      keys(attempt) == [
        "qaRun", "stage", "after", "result", "message", "exitStatus", "ms", "evidence",
        "waitingOn", "reusedFrom", "at", "output", "outputCut", "flow",
      ])
    #expect(attempt["stage"] as? String == "at-base")
    #expect(attempt["reusedFrom"] is NSNull)
    #expect(row["check"] is NSNull)
    #expect(row["exitStatus"] is NSNull)
    #expect(row["result"] as? String == "red")
    #expect(row["at"] as? String == "2026-09-21T14:13:20.250Z")
    let flowKeys: Set<String> = [
      "source", "run", "steps", "video", "sheet", "videoUnverified", "sheetUnverified",
    ]
    let flow = try #require(
      ((validation["rows"] as? [[String: Any]])?.last)?["flow"] as? [String: Any])
    #expect(keys(flow) == flowKeys)
    #expect(flow["video"] is NSNull)
    #expect(flow["videoUnverified"] as? String == "recorderBusy")
    let step = first(flow["steps"])
    #expect(keys(step) == ["n", "label", "offsetMs", "ok"])
    #expect(step["label"] is NSNull)
    let kept = first(validation["keptFlows"])
    #expect(keys(kept) == ["name", "test", "gateRun", "task", "at", "flow"])
    #expect(kept["test"] is NSNull)
    #expect(kept["task"] is NSNull)
    #expect(keys(kept["flow"]) == flowKeys)
  }

  @Test(
    "a blocked task's reason encodes its time, cause, halt, gate run and rejection, absent values as null — catches a block key the page won't read"
  )
  func encodesTaskBlockKeys() throws {
    var view = view
    view.tasks[0].status = .blocked
    view.tasks[0].blocked = RunView.TaskBlock(at: start, cause: .returnNotStored)
    let object = try #require(
      JSONSerialization.jsonObject(with: try RunViewJSON.encode(view)) as? [String: Any])
    let block = try #require(first(object["tasks"])["blocked"] as? [String: Any])
    #expect(keys(block) == ["at", "cause", "halt", "gateRun", "rejection"])
    #expect(block["cause"] as? String == "return-not-stored")
    #expect(block["halt"] is NSNull)
    #expect(block["gateRun"] is NSNull)
    #expect(block["rejection"] is NSNull)
  }

  @Test(
    "RunView times are ISO 8601 strings with milliseconds — catches a numeric date the page can't parse"
  )
  func timesAreISOWithMilliseconds() throws {
    let object = try #require(
      JSONSerialization.jsonObject(with: try RunViewJSON.encode(view)) as? [String: Any])
    #expect(
      (object["run"] as? [String: Any])?["startedAt"] as? String == "2026-09-21T14:13:20.250Z")
    #expect(first(object["halts"])["at"] as? String == "2026-09-21T14:13:20.250Z")
  }

  @Test(
    "the run carries its preset's stall minutes — catches a live page that can never flag a stall"
  )
  func runCarriesStallMinutes() throws {
    let preset = BuildPreset(
      designTier: .none, maxParallel: 1, review: .gate, taskGate: .tier(.fast), mergeGate: .push,
      workerModel: .sonnet, timeBudgetMin: 0, stopStartsBeforeMin: 0, onDesignConflict: .block,
      stallMin: 3)
    let record = BuildRunRecord(
      runID: "b1", plan: "p", startedAt: start, presetName: "brownfield", preset: preset)
    let join = BuildJoin.Run(
      plan: "p", runID: "b1", writeSets: [:], returns: [:], events: [], record: record)
    let view = RunViewBuilder.build(RunViewInput(buildRun: "b1", join: join))
    #expect(view.run.stallMin == 3)
    let object = try JSONSerialization.jsonObject(with: RunViewJSON.encode(view))
    #expect(((object as? [String: Any])?["run"] as? [String: Any])?["stallMin"] as? Int == 3)
  }

  @Test(
    "a run with a time box carries its minutes, source and the moments starts stop, the cutoff comes and the box ends — catches a viewer that can't show the box a run must fit"
  )
  func runCarriesTheTimeBox() throws {
    let preset = BuildPreset(
      designTier: .none, maxParallel: 3, review: .classified, taskGate: .tier(.slice),
      mergeGate: .merge, workerModel: .claudeSonnet55, timeBudgetMin: 45,
      stopStartsBeforeMin: 13, onDesignConflict: .amend, taskProof: .prove, stallMin: 2)
    let box = RunTimeBox(
      startedAt: start,
      limits: TimeBoxLimits(
        budgetMin: 45, stopStartsBeforeMin: 13, finalReserveMin: 5, source: .config))
    let record = BuildRunRecord(
      runID: "b1", plan: "p", startedAt: start.addingTimeInterval(300), presetName: "brownfield",
      preset: preset, timeBox: box)
    let join = BuildJoin.Run(
      plan: "p", runID: "b1", writeSets: [:], returns: [:], events: [], record: record)

    let view = RunViewBuilder.build(RunViewInput(buildRun: "b1", join: join))

    #expect(
      view.run.timeBox
        == RunView.TimeBox(
          budgetMin: 45, source: .config, startedAt: start,
          noNewStartsAt: start.addingTimeInterval(32 * 60),
          cutoffAt: start.addingTimeInterval(40 * 60), endsAt: start.addingTimeInterval(45 * 60)))
    let object = try JSONSerialization.jsonObject(with: RunViewJSON.encode(view))
    let encoded = ((object as? [String: Any])?["run"] as? [String: Any])?["timeBox"]
    #expect(
      keys(encoded) == ["budgetMin", "source", "startedAt", "noNewStartsAt", "cutoffAt", "endsAt"])
  }
}
