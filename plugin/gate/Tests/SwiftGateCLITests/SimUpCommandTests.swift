import ArgumentParser
import Foundation
import SwiftGateDomain
import Testing

@testable import SwiftGateCLI

@Suite("sim up command")
struct SimUpCommandTests {
  @Test(
    "sim up builds into this worktree's own derived-data/sim-up folder — catches a build sharing the gate's DerivedData and racing it"
  )
  func derivedData() {
    let root = URL(filePath: "/repos/app-a", directoryHint: .isDirectory)
    let path = SimUpCommand.derivedDataDirectory(root: root).path
    #expect(path.hasSuffix("/derived-data/sim-up"))
    #expect(path != AppBuildCheck.derivedDataDirectory(root: root).path)
  }

  @Test(
    "sim up parses --scenario and --json, and prints a failure as JSON with --json and as text without — catches a scenario flag dropped or a failure a calling skill can't parse"
  )
  func printsFailure() throws {
    let parsed = try SwiftGate.parseAsRoot(["sim", "up", "--scenario", "fixed-fact", "--json"])
    let command = try #require(parsed as? SimUpCommand)
    #expect(command.scenario == "fixed-fact")
    #expect(command.json)
    let live = try #require(try SwiftGate.parseAsRoot(["sim", "up"]) as? SimUpCommand)
    #expect(live.scenario == nil && !live.json)
    let failure = SimUpFailure(rule: .scenarioUnknown, message: "no such scenario")
    let json = SimUpCommand.output(.failure(failure), json: true)
    let object = try #require(
      try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    #expect(object["ruleID"] as? String == "sim.scenario-unknown")
    #expect(SimUpCommand.output(.failure(failure), json: false) == failure.text)
  }
}
