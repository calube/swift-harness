import Foundation

/// 1 area test step's totals, as a gate run's `report.json` keeps them, so how many tests each
/// area ran outlives the step's JUnit report and result bundle, which the next run overwrites.
/// `ran` counts the cases that executed: `passed` plus `failed`, never `skipped`.
public struct AreaTestCounts: Sendable, Equatable, Codable {
  public let area: String
  public let step: AreaStep
  public let ran: Int
  public let passed: Int
  public let failed: Int
  public let skipped: Int

  public init(area: String, step: AreaStep, counts: JUnitCounts) {
    self.area = area
    self.step = step
    failed = counts.failures
    skipped = counts.skipped
    passed = max(0, counts.tests - counts.failures - counts.skipped)
    ran = passed + failed
  }
}
