import ArgumentParser
import Foundation
import SwiftGateDomain
import Testing

@testable import SwiftGateCLI

@Suite("sim snap command")
struct SimSnapCommandTests {
  @Test(
    "sim snap parses a label, --assert, a run id and --json in any order, and the run id is optional — catches an assertion or run id dropped on the way to the step line"
  )
  func parses() throws {
    let full = try #require(
      try SwiftGate.parseAsRoot([
        "sim", "snap", "after tap", "--assert", "Counter: 1", "20261004T120000Z-1a2b3c4d", "--json",
      ]) as? SimSnapCommand)
    #expect(full.label == "after tap")
    #expect(full.assert == "Counter: 1")
    #expect(full.runID == "20261004T120000Z-1a2b3c4d")
    #expect(full.json)

    let bare = try #require(try SwiftGate.parseAsRoot(["sim", "snap", "home"]) as? SimSnapCommand)
    #expect(bare.label == "home" && bare.assert == nil && bare.runID == nil && !bare.json)
    #expect(throws: (any Error).self) { try SwiftGate.parseAsRoot(["sim", "snap", "  "]) }
    #expect(throws: (any Error).self) {
      try SwiftGate.parseAsRoot(["sim", "snap", "home", "../escape"])
    }
  }

  @Test(
    "sim snap takes an --assert value that starts with a dash, such as -2, before or after the run id — catches a negative count parsed as an unknown flag"
  )
  func dashValueAssert() throws {
    let before = try #require(
      try SwiftGate.parseAsRoot([
        "sim", "snap", "after decrement", "--assert", "-2", "20261004T120000Z-1a2b3c4d",
      ]) as? SimSnapCommand)
    let after = try #require(
      try SwiftGate.parseAsRoot([
        "sim", "snap", "after decrement", "20261004T120000Z-1a2b3c4d", "--assert", "-2", "--json",
      ]) as? SimSnapCommand)

    #expect(before.assert == "-2")
    #expect(before.runID == "20261004T120000Z-1a2b3c4d")
    #expect(after.assert == "-2")
    #expect(after.json)
  }

  @Test(
    "sim snap prints a failure as JSON with --json and as text without — catches a refusal a calling skill can't parse"
  )
  func printsFailure() throws {
    let failure = SimSnapFailure(rule: .notOwner, message: "run belongs to /repos/other")
    let json = SimSnapCommand.output(.failure(failure), json: true)
    let object = try #require(
      try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    #expect(object["ruleID"] as? String == "sim.not-owner")
    #expect(SimSnapCommand.output(.failure(failure), json: false) == failure.text)
  }
}
