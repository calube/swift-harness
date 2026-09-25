import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@Suite("doctor")
struct DoctorTests {
  private static let base = SimulatorDevice(
    udid: "B", name: "iPhone 17", runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-26-2",
    state: "Shutdown", isAvailable: true)

  private func facts(
    xcode: String? = nil, swift: String? = nil, devices: [SimulatorDevice]? = [base],
    freeBytes: Int64? = 500_000_000_000, shim: ShimStatus = .current,
    swiftLint: Bool = true, packages: [PackageManifest] = [],
    resolved: [String: String] = [:], architecture: [Finding] = []
  ) throws -> DoctorFacts {
    DoctorFacts(
      config: try SampleGraph.config(modules: []),
      xcodeVersionOutput: try xcode ?? Fixture.text("Doctor/xcodebuild-version.txt"),
      swiftVersionOutput: try swift ?? Fixture.text("Doctor/swift-version.txt"),
      devices: devices.map { .success($0) } ?? .failure("simctl could not run"),
      freeBytes: freeBytes, shim: shim, swiftLintInstalled: swiftLint, packages: packages,
      resolvedVersions: resolved, architectureFindings: architecture)
  }

  private func ids(_ result: DoctorResult) -> [String] { result.findings.map(\.ruleID) }

  @Test(
    "the installed Xcode and toolchain versions are read from real tool output — catches a pin check comparing against a misparsed version"
  )
  func parsesVersions() throws {
    #expect(Doctor.xcodeVersion(from: try Fixture.text("Doctor/xcodebuild-version.txt")) == "26.2")
    #expect(
      Doctor.swiftVersion(from: try Fixture.text("Doctor/swift-version.txt"))
        == ToolVersion("6.2"))
  }

  @Test("a healthy machine is GREEN with no findings — catches doctor crying wolf")
  func healthy() throws {
    let result = Doctor.evaluate(try facts())
    #expect(result.verdict == .green)
    #expect(result.findings.isEmpty)
  }

  @Test(
    "an Xcode other than the pin, a missing simulator runtime, or low disk is BLOCKED — catches Claude editing code to fix the machine"
  )
  func environment() throws {
    let result = Doctor.evaluate(
      try facts(xcode: "Xcode 26.4\nBuild version 17E192\n", devices: [], freeBytes: 1_000_000))

    #expect(result.verdict == .blocked)
    #expect(Set(ids(result)) == [Doctor.xcodePinRuleID, Doctor.simulatorRuleID, Doctor.diskRuleID])
    #expect(result.findings.allSatisfy { !$0.severity.failsGate })
  }

  @Test(
    "an Xcode that cannot run or a simctl failure is BLOCKED, not GREEN — catches doctor passing a machine it could not inspect"
  )
  func unreadable() throws {
    let result = Doctor.evaluate(try facts(xcode: "", devices: nil, freeBytes: nil))
    #expect(result.verdict == .blocked)
    #expect(Set(ids(result)) == [Doctor.xcodePinRuleID, Doctor.simulatorRuleID, Doctor.diskRuleID])
  }

  @Test(
    "a direct swift-issue-reporting dependency is RED below Swift 6.4 and fine from 6.4 — catches the conflicting-target build failure on 6.2"
  )
  func issueReporting() throws {
    let package = PackageManifest(
      name: "Feature", path: "Packages/Feature", remoteDependencies: ["swift-issue-reporting"],
      targets: [])

    let old = Doctor.evaluate(try facts(packages: [package]))
    #expect(old.verdict == .red)
    #expect(ids(old) == [Doctor.issueReportingRuleID])
    #expect(old.findings.first?.file == "Packages/Feature/Package.swift")

    let new = Doctor.evaluate(
      try facts(
        swift: "Apple Swift version 6.4 (swiftlang-6.4.0.1.1 clang-1800.0.1)\n",
        packages: [package]))
    #expect(!ids(new).contains(Doctor.issueReportingRuleID))
  }

  @Test(
    "architecture findings such as MainActor default isolation in Core are carried as RED — catches doctor passing TCA #3768"
  )
  func architecture() throws {
    let finding = try Finding(
      ruleID: "arch.core-main-actor-isolation", severity: .major, file: "P/Package.swift",
      line: nil, message: "m", failureScenario: nil)
    let result = Doctor.evaluate(try facts(architecture: [finding]))
    #expect(result.verdict == .red)
    #expect(ids(result) == ["arch.core-main-actor-isolation"])
  }

  @Test(
    "SwiftLint absence, a stale shim, and upgrade hazards warn without failing — catches advisory checks flipping the verdict"
  )
  func warnings() throws {
    let result = Doctor.evaluate(
      try facts(
        shim: .elsewhere(
          path: "~/.local/bin/swiftgate", target: "/old/bin/swiftgate",
          expected: "/new/bin/swiftgate"),
        swiftLint: false,
        resolved: ["swift-composable-architecture": "1.23.0", "swift-sharing": "2.10.1"]))

    #expect(result.verdict == .green)
    #expect(result.findings.allSatisfy { !$0.severity.failsGate })
    #expect(ids(result).contains(Doctor.swiftLintRuleID))
    #expect(ids(result).contains(Doctor.shimRuleID))
    let hazards = result.findings.filter { $0.ruleID == Doctor.upgradeHazardRuleID }
    #expect(hazards.contains { $0.message.contains("26.4") && $0.message.contains("1.24") })
    #expect(hazards.contains { $0.message.contains("27") && $0.message.contains("1.26") })
    #expect(hazards.contains { $0.message.contains("@Shared") })
  }

  @Test(
    "a hazard for an Xcode at or below the pin is not reported — catches doctor nagging about an upgrade already made"
  )
  func pastHazards() throws {
    let result = Doctor.evaluate(
      try facts(resolved: ["swift-composable-architecture": "1.26.2", "swift-sharing": "2.10.1"]))
    let hazards = result.findings.filter { $0.ruleID == Doctor.upgradeHazardRuleID }
    #expect(!hazards.contains { $0.message.contains("needs") })
  }

  @Test(
    "Package.resolved pins are read by identity — catches hazards judged against the wrong version"
  )
  func resolvedPins() throws {
    let pins = try ResolvedPins.parse(Fixture.data("Doctor/Package.resolved-CounterFeature.json"))
    #expect(pins["swift-composable-architecture"] == "1.26.2")
    #expect(pins["swift-case-paths"] == "1.10.0")
  }

  @Test("versions compare numerically — catches 1.9 sorting above 1.24")
  func versions() {
    #expect(ToolVersion("1.9.0") < ToolVersion("1.24"))
    #expect(ToolVersion("6.2") < ToolVersion("6.4"))
    #expect(!(ToolVersion("26.2") < ToolVersion("26.2.0")))
  }
}
