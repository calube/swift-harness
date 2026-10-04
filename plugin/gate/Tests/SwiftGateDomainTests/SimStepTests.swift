import Foundation
import SwiftGateDomain
import Testing

@Suite("sim step line")
struct SimStepTests {
  static let snapshot = URL(filePath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "Fixtures/AgentDevice/snapshot.stdout")

  static func step(_ n: Int, assert: String? = nil, settled: Bool? = true) -> SimStep {
    SimStep(
      n: n, label: "home screen", assert: assert, screenshot: SimStep.screenshotPath(n: n),
      tree: SimStep.treePath(n: n), settled: settled, elapsedMs: 812)
  }

  static func object(_ data: Data) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  @Test(
    "steps are named steps/001.png and steps/001.tree.json, zero-padded to 3 digits — catches names that sort 10 before 2"
  )
  func names() {
    #expect(SimStep.stem(1) == "001")
    #expect(SimStep.stem(42) == "042")
    #expect(SimStep.stem(1000) == "1000")
    #expect(SimStep.screenshotPath(n: 3) == "steps/003.png")
    #expect(SimStep.treePath(n: 3) == "steps/003.tree.json")
  }

  @Test(
    "a step with no --assert omits the assert key and an unknown settle omits settled — catches a placeholder empty assertion sim verify would search for"
  )
  func omitsUnset() throws {
    let line = Self.step(1, settled: nil).line()
    let object = try Self.object(line)
    #expect(Set(object.keys) == ["n", "label", "screenshot", "tree", "elapsedMs"])
    #expect(!line.contains(UInt8(ascii: "\n")))

    let asserted = try Self.object(Self.step(2, assert: "Counter: 0").line())
    #expect(asserted["assert"] as? String == "Counter: 0")
    #expect(asserted["settled"] as? Bool == true)
    #expect(asserted["n"] as? Int == 2)
    #expect(asserted["screenshot"] as? String == "steps/002.png")
  }

  @Test(
    "a step line decodes back to the same step, and an unknown key, a missing key or an empty label fails naming it — catches a step log sim verify half-reads"
  )
  func roundTripAndStrict() throws {
    for step in [
      Self.step(1), Self.step(7, assert: "Saved", settled: false), Self.step(2, settled: nil),
    ] {
      #expect(try SimStep.decode(line: step.line()) == step)
    }
    var object = try Self.object(Self.step(1).line())
    object["appStat"] = "runningForeground"
    #expect(throws: SimStepDecodingError.unknownKey(line: 1, "appStat")) {
      try SimStep.decode(line: try JSONSerialization.data(withJSONObject: object))
    }
    object = try Self.object(Self.step(1).line())
    object.removeValue(forKey: "tree")
    #expect(throws: SimStepDecodingError.missingKey(line: 1, "tree")) {
      try SimStep.decode(line: try JSONSerialization.data(withJSONObject: object))
    }
    object = try Self.object(Self.step(1).line())
    object["label"] = ""
    #expect(throws: SimStepDecodingError.invalidValue(line: 1, key: "label", value: "")) {
      try SimStep.decode(line: try JSONSerialization.data(withJSONObject: object))
    }
  }

  @Test(
    "a step log decodes in order, an empty log has no steps, and a gap in numbering fails naming the line — catches two snaps that took one number"
  )
  func log() throws {
    #expect(try SimStep.decodeLog(Data()).isEmpty)
    let two = Self.step(1).line() + Data("\n".utf8) + Self.step(2).line() + Data("\n".utf8)
    #expect(try SimStep.decodeLog(two) == [Self.step(1), Self.step(2)])

    let gap = Self.step(1).line() + Data("\n".utf8) + Self.step(3).line() + Data("\n".utf8)
    #expect(throws: SimStepDecodingError.outOfSequence(line: 2, expected: 2, found: 3)) {
      try SimStep.decodeLog(gap)
    }
    let broken = Self.step(1).line() + Data("\n{\"n\":\n".utf8)
    #expect {
      try SimStep.decodeLog(broken)
    } throws: { error in
      guard case .malformed(let line, _) = error as? SimStepDecodingError else { return false }
      return line == 2
    }
  }

  @Test(
    "two identical captured trees are settled, a changed label is not, and an unparseable tree is unknown — catches a screenshot of a different screen than its tree passing as settled"
  )
  func settled() throws {
    let captured = try Data(contentsOf: Self.snapshot)
    let text = String(decoding: captured, as: UTF8.self)
    #expect(SimStep.settled(before: captured, after: captured) == true)

    try #require(text.components(separatedBy: "\"label\": \"SampleApp\"").count == 2)
    let changed = Data(
      text.replacingOccurrences(of: "\"label\": \"SampleApp\"", with: "\"label\": \"Loading\"")
        .utf8)
    #expect(SimStep.settled(before: captured, after: changed) == false)
    #expect(SimStep.settled(before: captured, after: Data("{}".utf8)) == nil)
  }

  @Test(
    "a refused worktree and a gone session are RED, a driver or file failure is BLOCKED — catches a lost device reported as a machine problem"
  )
  func verdicts() throws {
    #expect(SimSnapRule.notOwner.verdict == .red)
    #expect(SimSnapRule.sessionGone.verdict == .red)
    #expect(SimSnapRule.driverFailed.verdict == .blocked)
    #expect(SimSnapRule.environment.verdict == .blocked)

    let failure = SimSnapFailure(rule: .sessionGone, message: "device is gone", runID: "r1")
    let object = try Self.object(failure.json())
    #expect(object["ruleID"] as? String == "sim.session-gone")
    #expect(object["verdict"] as? String == Verdict.red.rawValue)
    #expect(object["runID"] as? String == "r1")
    #expect(failure.text.contains("sim.session-gone"))
    #expect(failure.text.contains("device is gone"))
  }

  @Test(
    "a snap's JSON names the step and its files under the run's sim folder — catches a calling skill that can't find the screenshot to look at"
  )
  func snappedJSON() throws {
    let snapped = SimSnapped(
      runID: "r1", step: Self.step(4, assert: "Saved"), simDirectory: "/repo/.harness/runs/r1/sim")
    let object = try Self.object(snapped.json())
    #expect(object["verdict"] as? String == Verdict.green.rawValue)
    #expect(object["n"] as? Int == 4)
    #expect(object["screenshot"] as? String == "/repo/.harness/runs/r1/sim/steps/004.png")
    #expect(object["tree"] as? String == "/repo/.harness/runs/r1/sim/steps/004.tree.json")
    #expect(object["settled"] as? Bool == true)
    #expect(snapped.text.contains("004"))
  }

  @Test(
    "a step's app state round-trips, an unknown state fails naming it, and only a not-running step may omit its tree — catches an open app state or a dropped tree passing as an exit"
  )
  func appState() throws {
    var running = Self.step(1)
    running.appState = .runningForeground
    #expect(try Self.object(running.line())["appState"] as? String == "runningForeground")
    #expect(try SimStep.decode(line: running.line()) == running)

    var exited = Self.step(2)
    exited.tree = nil
    exited.appState = .notRunning
    let line = try Self.object(exited.line())
    #expect(line["tree"] == nil)
    #expect(line["appState"] as? String == "notRunning")
    #expect(try SimStep.decode(line: exited.line()) == exited)

    var object = try Self.object(running.line())
    object["appState"] = "crashed"
    #expect(throws: SimStepDecodingError.invalidValue(line: 1, key: "appState", value: "crashed")) {
      try SimStep.decode(line: try JSONSerialization.data(withJSONObject: object))
    }
    object = try Self.object(running.line())
    object.removeValue(forKey: "tree")
    #expect(throws: SimStepDecodingError.missingKey(line: 1, "tree")) {
      try SimStep.decode(line: try JSONSerialization.data(withJSONObject: object))
    }
  }
}
