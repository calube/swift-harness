import SwiftGateTestSupport

@testable import SwiftGateCLI

extension SimulatorTestCheck.Dependencies {
  /// Simulator tiers that pass without a device, for check tests about other steps. The version
  /// output matches every fixture repository's "26.2" pin by prefix (a patch, not the exact
  /// string), so the Xcode pin gate never blocks a test that isn't about it.
  static let fake = SimulatorTestCheck.Dependencies(
    makeDevices: { _ in FakeDevices() },
    xcodebuild: FakeXcodebuild(versionOutput: "Xcode 26.2.1\nBuild version 17C48\n"),
    reader: FakeXcresultReader(scenario: "pass"))
}
