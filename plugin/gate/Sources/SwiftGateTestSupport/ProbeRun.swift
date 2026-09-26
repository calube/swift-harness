import Foundation
import SwiftGateDomain

/// Recorded `swift test` runs of `gate/Fixtures/swifttest/XUnitProbe` (see
/// `gate/Tests/Fixtures/README.md`), and the probe's tests as ``ChangedTest``s.
public enum ProbeRun {
  public static let package = "gate/Fixtures/swifttest/XUnitProbe"
  public static let testDirectory = "\(package)/Tests/ProbeTests"
  public static let target = TestTargetReference(name: "ProbeTests", path: testDirectory)

  public static let passXCTest = ChangedTest(
    framework: .xcTest, target: "ProbeTests", suites: ["PassXCTests"], function: "testDoubles",
    file: "\(testDirectory)/PassTests.swift", line: 6, lastLine: 8)
  public static let passSwiftTesting = ChangedTest(
    framework: .swiftTesting, target: "ProbeTests", suites: ["PassSwiftTests"],
    function: "doubles()", file: "\(testDirectory)/PassTests.swift", line: 12, lastLine: 14)
  public static let failSwiftTesting = ChangedTest(
    framework: .swiftTesting, target: "ProbeTests", suites: ["FailSwiftTests"],
    function: "doublesWrong()", file: "\(testDirectory)/FailTests.swift", line: 12,
    lastLine: 14)

  /// The evidence of the recorded `scenario`.
  public static func evidence(_ scenario: String) throws -> HostTestEvidence {
    let directory = Fixture.directory.appending(path: "SwiftTest")
    func optional(_ name: String) -> Data? {
      try? Data(contentsOf: directory.appending(path: name))
    }
    let status = try Fixture.text("SwiftTest/\(scenario).status")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return HostTestEvidence(
      packagePath: package, testTargets: [target], succeeded: status == "0",
      xctestReport: optional("\(scenario).xml"),
      swiftTestingReport: optional("\(scenario)-swift-testing.xml"),
      stdout: try Fixture.text("SwiftTest/\(scenario).stdout"),
      stderr: try Fixture.text("SwiftTest/\(scenario).stderr"),
      testSourceFiles: ["Crash", "Fail", "Pass", "Skip"].map {
        "\(testDirectory)/\($0)Tests.swift"
      },
      repositoryRoot: Fixture.repositoryRoot)
  }
}
