import Foundation
import SwiftGateDomain
import Testing

@Suite("run view guard")
struct RunViewGuardTests {
  static func view(
    writes: [String] = ["Sources/Counter.swift"], damage: [RunView.Damage] = [],
    ruleCounts: [String: Int] = [:]
  ) -> RunView {
    RunView(
      run: RunView.Run(id: "20261004T045528Z-58d28c78", plan: "counter", state: .done),
      tasks: [
        RunView.Task(id: "first", status: .done, writes: ["Tests/CounterTests.swift"], gate: .push),
        RunView.Task(id: "second", status: .done, writes: writes, gate: .push),
      ],
      gates: [
        RunView.Gate(
          runID: "20261004T050310Z-ed998508", command: "check push", verdict: .green,
          milliseconds: 1, ruleCounts: ruleCounts)
      ],
      damage: damage)
  }

  @Test(
    "an absolute path in a task's write set and a home path in a damage row are rejected naming the field — catches a guard that skips a string"
  )
  func namesTheField() throws {
    #expect(try RunViewGuard.rejection(of: Self.view()) == nil)
    #expect(
      try RunViewGuard.rejection(of: Self.view(writes: ["Sources/A.swift", "/Users/x/B.swift"]))
        == RunViewGuard.Rejection(field: "tasks[1].writes[1]", reason: .absolutePath))
    #expect(
      try RunViewGuard.rejection(
        of: Self.view(damage: [RunView.Damage(source: "~/notes.txt", reason: "unreadable")]))
        == RunViewGuard.Rejection(field: "damage[0].source", reason: .homePath))
  }

  @Test(
    "a dictionary key holding a newline is rejected naming its object — catches a guard that checks values only"
  )
  func checksKeys() throws {
    let rejection = try RunViewGuard.rejection(
      of: Self.view(ruleCounts: ["swift.ok": 1, "split\nrule": 2]))
    #expect(
      rejection == RunViewGuard.Rejection(field: "gates[0].ruleCounts{key}", reason: .newline))
  }
}
