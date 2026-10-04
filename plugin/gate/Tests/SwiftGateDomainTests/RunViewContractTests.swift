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
        "schemaVersion", "cursor", "run", "spec", "tasks", "roles", "spans", "gates", "proofs",
        "halts", "damage",
      ])
    #expect(object["schemaVersion"] as? Int == 1)
    #expect(object["cursor"] is NSNull)
    #expect(
      keys(object["run"]) == ["id", "plan", "preset", "startedAt", "endedAt", "state", "stallMin"])
    #expect((object["run"] as? [String: Any])?["stallMin"] is NSNull)
    #expect((object["run"] as? [String: Any])?["endedAt"] is NSNull)
    #expect(keys(first(object["spec"])) == ["id", "title", "tasks"])

    let task = first(object["tasks"])
    #expect(
      keys(task) == [
        "id", "status", "model", "deps", "writes", "gate", "covers", "commits", "gateRun",
        "mergeGateRun", "createdAt", "mergedAt", "brief", "tokens", "blocked",
      ])
    #expect(task["blocked"] is NSNull)
    #expect(task["tokens"] is NSNull)
    #expect(task["mergedAt"] is NSNull)
    #expect(task["status"] as? String == "in-progress")
    #expect(
      keys(task["brief"]) == ["title", "why", "designRef", "scope", "acceptance", "outOfScope"])
    #expect(keys(first(object["roles"])) == ["role", "tokens"])
    #expect(
      keys((first(object["roles"]))["tokens"]) == ["input", "output", "cacheRead", "cacheWrite"])

    let spans = try #require(object["spans"] as? [[String: Any]])
    let spanKeys: Set<String> = [
      "id", "parent", "phase", "task", "gateRun", "start", "end", "outcome", "approximate", "tools",
      "causeGateRun",
    ]
    #expect(spans.map(keys) == [spanKeys, spanKeys])
    #expect(spans[0]["end"] is NSNull)
    #expect(spans[0]["tools"] is NSNull)
    #expect(spans[0]["causeGateRun"] is NSNull)
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
}
