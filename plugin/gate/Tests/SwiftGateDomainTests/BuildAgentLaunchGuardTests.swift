import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@Suite("the build loop's agents launch in the background")
struct BuildAgentLaunchGuardTests {
  struct Launch: Decodable {
    let subagent_type: String
    let run_in_background: Bool?
  }

  /// The 2 merge fixers a brownfield trial's orchestrator launched, in order.
  static func trialLaunches() throws -> [Launch] {
    try JSONDecoder().decode(
      [Launch].self, from: Data(try Fixture.text("Hooks/trial-orchestrator-agent-launches.json").utf8))
  }

  @Test(
    "the trial's foreground merge fixer is denied with guard.build-agent-foreground and its background one passes — catches the 481 s fixer that held every merge and start"
  )
  func trialFixersAreJudged() throws {
    let launches = try Self.trialLaunches()
    #expect(launches.map(\.run_in_background) == [false, true])
    let verdicts = launches.map {
      BuildAgentLaunchGuard.evaluate(
        subagentType: $0.subagent_type, runInBackground: $0.run_in_background)
    }
    #expect(verdicts[0]?.ruleID == BuildAgentLaunchGuard.ruleID)
    #expect(verdicts[0]?.reason.contains("run_in_background: true") == true)
    #expect(verdicts[1] == nil)
  }

  @Test(
    "a build worker or fixer launch that leaves run_in_background out is denied too — catches a launch that runs in the foreground by default"
  )
  func omittedFlagIsDenied() {
    for agent in BuildAgentLaunchGuard.agentTypes {
      #expect(
        BuildAgentLaunchGuard.evaluate(subagentType: agent, runInBackground: nil)?.ruleID
          == BuildAgentLaunchGuard.ruleID, "\(agent)")
    }
  }

  @Test(
    "every other agent runs however it is launched — catches the guard holding up a decomposer or an explorer the caller waits on"
  )
  func otherAgentsAreUntouched() {
    for agent in [
      "general-purpose", "swift-harness:design-decomposer", "swift-harness:brownfield-explorer",
    ] {
      #expect(BuildAgentLaunchGuard.evaluate(subagentType: agent, runInBackground: false) == nil)
    }
    #expect(BuildAgentLaunchGuard.evaluate(subagentType: nil, runInBackground: nil) == nil)
  }
}
