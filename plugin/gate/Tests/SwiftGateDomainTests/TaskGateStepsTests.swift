import SwiftGateDomain
import Testing

@Suite("task gate steps")
struct TaskGateStepsTests {
  @Test(
    "a gate run's missing steps come from its tier and recorded steps only: ready and push still miss app-build, fast misses all three, a non-check run ran none — catches a tier credited with a step it never runs"
  )
  func missingStepsFollowTierAndRecord() {
    let required: [CheckExtraStep] = [.impact, .coverage, .appBuild]
    func missing(_ tier: CheckTier?, _ steps: [String]) -> [CheckExtraStep] {
      TaskReturnEvidence.GateRun(tier: tier, verdict: .green, steps: steps)
        .missingSteps(of: required)
    }

    #expect(missing(.ready, []) == [.appBuild])
    #expect(missing(.push, []) == [.appBuild])
    #expect(missing(.fast, []) == [.impact, .coverage, .appBuild])
    #expect(missing(.fast, ["impact", "app-build"]) == [.coverage])
    #expect(missing(.fast, ["impact", "coverage", "app-build"]) == [])
    #expect(missing(nil, ["impact", "coverage", "app-build"]) == [.impact, .coverage, .appBuild])
  }
}
