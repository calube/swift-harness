import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

/// What `sim up` opens a flow row's app with: the launch arguments of the flow's first `open`.
@Suite("flow steps: the launch arguments a row opens the app with")
struct FlowLaunchArgumentsTests {
  static func steps(_ path: String) throws -> [FlowStep] {
    try FlowSteps.parse(try Fixture.data(path))
  }

  @Test(
    "a trial flow that relaunches in a scenario gives that scenario's arguments — catches a row's app opened on its live dependencies before step 1"
  )
  func scenarioFlow() throws {
    #expect(
      FlowSteps.launchArguments(
        try Self.steps("BrownfieldTrial/price-tracker-6-refresh-row/flow.json"))
        == ["-harness-scenario", "success"])
    #expect(
      FlowSteps.launchArguments(try Self.steps("BrownfieldTrial/send-money-7-send-success.flow.json"))
        == ["-harness-scenario", "success"])
  }

  @Test(
    "a flow that opens nothing first, or opens with no launchArgs, gives none — catches an argument taken from a later step or a step's other input"
  )
  func noLeadingOpen() throws {
    #expect(
      FlowSteps.launchArguments(try Self.steps("BrownfieldTrial/aidoku-setting-flow/flow.json"))
        .isEmpty)
    let plain = try FlowSteps.parse(
      Data(
        #"[{"command": "open", "input": {"app": "com.example.App", "relaunch": true}}, {"command": "open", "input": {"app": "com.example.App", "launchArgs": ["-later"]}}]"#
          .utf8))
    #expect(FlowSteps.launchArguments(plain).isEmpty)
  }
}
