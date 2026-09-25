import SwiftGateTestSupport

@testable import SwiftGateCLI

extension SimulatorTestCheck.Dependencies {
  /// Simulator tiers that pass without a device, for check tests about other steps.
  static let fake = SimulatorTestCheck.Dependencies(
    makeDevices: { _ in FakeDevices() }, xcodebuild: FakeXcodebuild(),
    reader: FakeXcresultReader(scenario: "pass"))
}
