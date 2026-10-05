import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@Suite("a GREEN brownfield gate answers again for identical inputs")
struct GateReuseTests {
  /// 1 captured `gate.run`: what a reuse key and a history line are built from.
  struct GateRunEvent {
    let runID: String
    let tier: CheckTier
    let command: String
    let base: String
    let head: String
    let treeHash: String
    let sourceHash: String
    let verdict: Verdict
    let dirty: Bool

    var inputs: GateReuse.Inputs {
      GateReuse.Inputs(
        tier: tier, treeHash: treeHash, mergeBase: base, sourceHash: sourceHash, stateFiles: [:])
    }

    func record(key: String?) throws -> RunHistoryRecord {
      let report = try RunReport(
        runID: runID, durationMilliseconds: 1,
        tiers: [TierResult(tier: .t1, verdict: verdict, durationMilliseconds: 1, testCounts: nil)],
        findings: [])
      return RunHistoryRecord(
        report: report, finishedAt: Date(timeIntervalSince1970: 1_790_000_000), command: command,
        headCommit: head, base: base, dirty: dirty, reuseKey: key)
    }
  }

  struct FixtureShape: Error {
    let line: String
  }

  /// The 2 merge gates a brownfield trial's orchestrator ran back to back on 1 commit.
  static func trialGates() throws -> [GateRunEvent] {
    try Fixture.text("BrownfieldTrial/trial-duplicate-merge-gates.jsonl").split(separator: "\n")
      .map { line in
        let event = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        let payload = event?["payload"] as? [String: Any]
        let source = event?["source"] as? [String: Any]
        let binary = source?["binary"] as? [String: Any]
        let tier = (source?["tier"] as? String).flatMap(CheckTier.init(rawValue:))
        let verdict = (payload?["verdict"] as? String).flatMap(Verdict.init(rawValue:))
        guard let runID = event?["runID"] as? String, let tier,
          let command = payload?["command"] as? String, let base = event?["base"] as? String,
          let head = event?["head"] as? String, let treeHash = payload?["treeHash"] as? String,
          let sourceHash = binary?["sourceHash"] as? String, let verdict,
          let dirty = payload?["dirty"] as? Bool
        else { throw FixtureShape(line: String(line)) }
        return GateRunEvent(
          runID: runID, tier: tier, command: command, base: base, head: head, treeHash: treeHash,
          sourceHash: sourceHash, verdict: verdict, dirty: dirty)
      }
  }

  @Test(
    "the trial's second merge gate on an unchanged commit has the first one's key and reuses it — catches the 38 s gate that re-ran a GREEN verdict"
  )
  func trialDuplicateIsReused() throws {
    let gates = try Self.trialGates()
    try #require(gates.count == 2)
    let key = GateReuse.key(gates[0].inputs)
    #expect(key.count == 64)
    #expect(GateReuse.key(gates[1].inputs) == key)
    let first = try gates[0].record(key: key)
    #expect(GateReuse.reusable([first], command: gates[1].command, key: key) == first)
  }

  @Test(
    "the key changes with the tier, the tree, the merge base, the binary and each state file, present or not — catches a reuse across a config, baseline or binary change"
  )
  func keyCoversEveryInput() {
    let base = GateReuse.Inputs(
      tier: .merge, treeHash: "t", mergeBase: "m", sourceHash: "s",
      stateFiles: ["config.toml": "c", "baseline": nil])
    let variants = [
      GateReuse.Inputs(
        tier: .final, treeHash: "t", mergeBase: "m", sourceHash: "s", stateFiles: base.stateFiles),
      GateReuse.Inputs(
        tier: .merge, treeHash: "u", mergeBase: "m", sourceHash: "s", stateFiles: base.stateFiles),
      GateReuse.Inputs(
        tier: .merge, treeHash: "t", mergeBase: "n", sourceHash: "s", stateFiles: base.stateFiles),
      GateReuse.Inputs(
        tier: .merge, treeHash: "t", mergeBase: "m", sourceHash: "x", stateFiles: base.stateFiles),
      GateReuse.Inputs(
        tier: .merge, treeHash: "t", mergeBase: "m", sourceHash: "s",
        stateFiles: ["config.toml": "d", "baseline": nil]),
      GateReuse.Inputs(
        tier: .merge, treeHash: "t", mergeBase: "m", sourceHash: "s",
        stateFiles: ["config.toml": "c", "baseline": "b"]),
      GateReuse.Inputs(
        tier: .merge, treeHash: "t", mergeBase: "m", sourceHash: "s",
        stateFiles: ["config.toml": "c"]),
    ]
    let key = GateReuse.key(base)
    #expect(!key.isEmpty)
    #expect(Set(variants.map(GateReuse.key)).count == variants.count)
    #expect(!variants.map(GateReuse.key).contains(key))
  }

  @Test(
    "only the newest clean run of the same command and key answers, and only when GREEN — catches a RED, dirty, other-tier or other-input run answering for this one, or an older GREEN hiding a newer RED"
  )
  func onlyAMatchingGreenRunIsReused() throws {
    let gate = try #require(try Self.trialGates().first)
    let key = GateReuse.key(gate.inputs)
    func run(_ id: String, verdict: Verdict = .green, dirty: Bool = false, key: String?) throws
      -> RunHistoryRecord
    {
      try GateRunEvent(
        runID: id, tier: gate.tier, command: gate.command, base: gate.base, head: gate.head,
        treeHash: gate.treeHash, sourceHash: gate.sourceHash, verdict: verdict, dirty: dirty
      ).record(key: key)
    }
    let red = try run("r1", verdict: .red, key: key)
    let dirty = try run("r2", dirty: true, key: key)
    let other = try run("r3", key: "other")
    let none = try run("r4", key: nil)
    #expect(GateReuse.reusable([red, dirty, other, none], command: gate.command, key: key) == nil)
    #expect(
      GateReuse.reusable([try run("r5", key: key)], command: "check final", key: key) == nil)
    let older = try run("r6", key: key)
    let newer = try run("r7", key: key)
    #expect(GateReuse.reusable([older, newer], command: gate.command, key: key)?.runID == "r7")
    #expect(GateReuse.reusable([newer, red], command: gate.command, key: key) == nil)
  }
}
