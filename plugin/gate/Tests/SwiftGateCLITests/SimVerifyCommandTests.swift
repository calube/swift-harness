import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import Testing

@testable import SwiftGateCLI

@Suite("sim verify command")
struct SimVerifyCommandTests {
  @Test(
    "sim verify takes an optional run id and --json, and refuses a run id that could leave the runs folder"
  )
  func parses() throws {
    let full = try #require(
      try SwiftGate.parseAsRoot(["sim", "verify", "20261004T120000Z-1a2b3c4d", "--json"])
        as? SimVerifyCommand)
    #expect(full.runID == "20261004T120000Z-1a2b3c4d")
    #expect(full.json)
    let bare = try #require(try SwiftGate.parseAsRoot(["sim", "verify"]) as? SimVerifyCommand)
    #expect(bare.runID == nil && !bare.json)
    #expect(throws: (any Error).self) {
      try SwiftGate.parseAsRoot(["sim", "verify", "../escape"])
    }
  }

  @Test(
    "sim verify prints the report as JSON with --json and as text without, and a refusal the same way — catches a verdict a calling skill can't parse"
  )
  func prints() throws {
    let report = SimVerifyReport(
      runID: "r1", stepCount: 0, headCommit: "abc", checkoutHead: "abc",
      findings: [
        SimEvidenceFinding(rule: .noSteps, step: nil, path: "steps.ndjson", message: "no step")
      ], blocked: nil)
    let verified = SimVerified(report: report, unrecorded: [])
    let json = SimVerifyCommand.output(.success(verified), json: true)
    let object = try #require(
      try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    #expect(object["verdict"] as? String == "RED")
    #expect(SimVerifyCommand.output(.success(verified), json: false) == report.text)

    let failure = SimVerifyFailure(rule: .notOwner, message: "run r1 belongs to /repos/other")
    let refused = try #require(
      try JSONSerialization.jsonObject(
        with: Data(SimVerifyCommand.output(.failure(failure), json: true).utf8))
        as? [String: Any])
    #expect(refused["ruleID"] as? String == "sim.not-owner")
    #expect(SimVerifyCommand.output(.failure(failure), json: false) == failure.text)
  }

  @Test(
    "standalone sim verify audits every control in an owned repository and none in a brownfield clone, saying why — catches a brownfield run failing on controls no flow named"
  )
  func standaloneAuditFollowsTheProfile() throws {
    let brownfield = FileManager.default.temporaryDirectory.appending(
      path: "sim-verify-audit-\(UUID().uuidString)", directoryHint: .isDirectory)
    let owned = FileManager.default.temporaryDirectory.appending(
      path: "sim-verify-audit-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer {
      try? FileManager.default.removeItem(at: brownfield)
      try? FileManager.default.removeItem(at: owned)
    }
    let common = brownfield.appending(path: ".git/\(StateRootResolver.commonConfigFile)")
    try FileManager.default.createDirectory(
      at: common.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data().write(to: common)
    try FileManager.default.createDirectory(at: owned, withIntermediateDirectories: true)
    try Data().write(to: owned.appending(path: Config.fileName))

    #expect(SimVerifyCommand.audit(root: owned) == .everyControl)
    #expect(
      SimVerifyCommand.audit(root: brownfield)
        == .unaudited(reason: SimAuditScope.noFlowReason))
  }
}
