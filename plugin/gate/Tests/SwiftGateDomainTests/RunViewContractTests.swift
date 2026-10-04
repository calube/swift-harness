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
    #expect(keys(object["run"]) == ["id", "plan", "preset", "startedAt", "endedAt", "state"])
    #expect((object["run"] as? [String: Any])?["endedAt"] is NSNull)
    #expect(keys(first(object["spec"])) == ["id", "title", "tasks"])

    let task = first(object["tasks"])
    #expect(
      keys(task) == [
        "id", "status", "model", "deps", "writes", "gate", "covers", "commits", "gateRun",
        "mergeGateRun", "createdAt", "mergedAt", "brief", "tokens",
      ])
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
    ]
    #expect(spans.map(keys) == [spanKeys, spanKeys])
    #expect(spans[0]["end"] is NSNull)
    #expect(spans[0]["tools"] is NSNull)
    #expect(keys(spans[1]["tools"]) == ["calls", "otherCount", "ms", "files", "droppedPaths"])
    #expect(
      keys(first((spans[1]["tools"] as? [String: Any])?["calls"])) == ["tool", "count", "ms"])

    let gate = first(object["gates"])
    #expect(
      keys(gate) == ["runId", "task", "command", "verdict", "ms", "tests", "ruleCounts", "steps"])
    #expect(keys(first(gate["steps"])) == ["tier", "step", "startMs", "ms", "verdict"])
    #expect(first(gate["steps"])["startMs"] is NSNull)
    #expect(
      keys(first(object["proofs"])) == [
        "gateRun", "task", "test", "outcome", "proofBase", "assertion",
      ])
    #expect(keys(first(object["halts"])) == ["task", "reason", "at", "answer", "waitMs"])
    #expect(keys(first(object["damage"])) == ["source", "reason"])
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
}
