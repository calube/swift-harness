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
    swiftLint: Bool = true, mmdc: Bool = true, packages: [PackageManifest] = [],
    resolved: [String: String] = [:], architecture: [Finding] = [], config: Config? = nil,
    judgeKeysSet: Set<String>? = nil
  ) throws -> DoctorFacts {
    DoctorFacts(
      config: try config ?? SampleGraph.config(modules: []),
      xcodeVersionOutput: try xcode ?? Fixture.text("Doctor/xcodebuild-version.txt"),
      swiftVersionOutput: try swift ?? Fixture.text("Doctor/swift-version.txt"),
      devices: devices.map { .success($0) } ?? .failure("simctl could not run"),
      freeBytes: freeBytes, shim: shim, swiftLintInstalled: swiftLint, packages: packages,
      resolvedVersions: resolved, architectureFindings: architecture, mermaidCLIInstalled: mmdc,
      judgeKeysSet: judgeKeysSet)
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

  @Test(
    "a machine without mmdc gets a doctor.mmdc nit and stays GREEN — catches design-lint quietly skipping Mermaid syntax checks with nothing in doctor saying why"
  )
  func missingMermaidCLIIsANit() throws {
    let result = Doctor.evaluate(try facts(mmdc: false))
    let finding = try #require(result.findings.first { $0.ruleID == Doctor.mermaidCLIRuleID })
    #expect(finding.severity == .nit)
    #expect(finding.message.contains("design-lint"))
    #expect(result.verdict == .green)
  }

  @Test(
    "a jev judge with TYPESAFE_API_KEY unset is a RED doctor.judge-key finding naming it, while a set key or a claude judge is clean — catches a judge silently off for a missing key"
  )
  func jevWithoutKeyIsAnIssue() throws {
    func config(_ backend: JudgeBackend) throws -> Config {
      try Config(
        xcode: "26.2", appScheme: "App", packages: ["Packages/*"],
        simulator: SimulatorConfig(device: "iPhone 17", os: "26.2"),
        judge: .enabled(
          backend: backend, thresholds: JudgeThresholds(advisory: 0.6, block: 0.9)))
    }

    let missing = Doctor.evaluate(try facts(config: config(.jev), judgeKeysSet: []))
    let present = Doctor.evaluate(
      try facts(config: config(.jev), judgeKeysSet: ["TYPESAFE_API_KEY"]))
    let claude = Doctor.evaluate(try facts(config: config(.claude), judgeKeysSet: []))

    let finding = try #require(missing.findings.first { $0.ruleID == Doctor.judgeKeyRuleID })
    #expect(finding.severity == .major)
    #expect(finding.file == Config.fileName)
    #expect(finding.message.contains("TYPESAFE_API_KEY"))
    #expect(missing.verdict == .red)
    #expect(!ids(present).contains(Doctor.judgeKeyRuleID))
    #expect(!ids(claude).contains(Doctor.judgeKeyRuleID))
  }

  @Test(
    "a [harness] profile naming no build preset is a RED doctor.profile issue naming the profile and the missing preset, while a defined or absent profile is clean — catches a profile that silently falls back to another preset"
  )
  func profileNamingNoPresetIsAnIssue() throws {
    let preset = BuildPreset(
      designTier: .standard, maxParallel: 3, review: .full, taskGate: .ledger, mergeGate: .push,
      workerModel: .tagged, timeBudgetMin: 0, stopStartsBeforeMin: 0, onDesignConflict: .amend,
      taskProof: .perTask)
    func config(profile: String?) throws -> Config {
      try Config(
        xcode: "26.2", appScheme: "App", packages: ["Packages/*"],
        simulator: SimulatorConfig(device: "iPhone 17", os: "26.2"),
        buildPresets: ["default": preset, "fast": preset], profile: profile)
    }

    let result = Doctor.evaluate(try facts(config: config(profile: "interview")))
    let finding = try #require(result.findings.first { $0.ruleID == Doctor.profileRuleID })
    #expect(finding.severity == .major)
    #expect(result.verdict == .red)
    #expect(finding.file == Config.fileName)
    #expect(finding.message.contains("profile \"interview\""))
    #expect(finding.message.contains("[build.presets.interview]"))
    #expect(finding.message.contains("default, fast"))

    for profile in ["fast", nil] {
      let clean = Doctor.evaluate(try facts(config: config(profile: profile)))
      #expect(!ids(clean).contains(Doctor.profileRuleID))
    }
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

@Suite("doctor: the session's plugin")
struct DoctorPluginSessionTests {
  private static let recordedHash = String(repeating: "a", count: 64)
  private static let changedHash = String(repeating: "b", count: 64)

  private func record(_ id: String = "session-a") throws -> SessionRecord {
    try SessionRecord(
      sessionId: id, recordedAt: Date(timeIntervalSince1970: 1_000), pluginRoot: "/plugins/harness",
      pluginVersion: "0.1.0", treeHash: Self.recordedHash, transcriptPath: nil)
  }

  private func evaluate(_ session: PluginSessionFacts) throws -> DoctorResult {
    let device = SimulatorDevice(
      udid: "B", name: "iPhone 17",
      runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-26-2", state: "Shutdown",
      isAvailable: true)
    return Doctor.evaluate(
      DoctorFacts(
        config: try SampleGraph.config(modules: []),
        xcodeVersionOutput: try Fixture.text("Doctor/xcodebuild-version.txt"),
        swiftVersionOutput: try Fixture.text("Doctor/swift-version.txt"),
        devices: .success([device]), freeBytes: 500_000_000_000, shim: .current,
        swiftLintInstalled: true, packages: [], resolvedVersions: [:], architectureFindings: [],
        mermaidCLIInstalled: true, pluginSession: session))
  }

  private func facts(
    sessionID: String? = nil, recorded: RecordedPluginSession?,
    unreadable: [UnreadableSessionRecord] = []
  ) -> PluginSessionFacts {
    PluginSessionFacts(
      sessionID: sessionID, recorded: recorded, unreadable: unreadable,
      directory: ".harness/hook-state/sessions")
  }

  private func sessionFindings(_ result: DoctorResult) -> [Finding] {
    result.findings.filter {
      [Doctor.pluginChangedRuleID, Doctor.sessionRecordRuleID].contains($0.ruleID)
    }
  }

  @Test(
    "a record whose tree hash differs from the plugin on disk is a major doctor.plugin-changed naming both hashes and versions and saying to start a fresh session, and a matching one stays GREEN — catches a session running stale prompts with nothing to stop it, or a check failing every session"
  )
  func changedTreeFailsAndMatchingPasses() throws {
    let matching = try evaluate(
      facts(
        recorded: RecordedPluginSession(
          record: try record(), current: .tree(version: "0.1.0", hash: Self.recordedHash))))
    #expect(sessionFindings(matching).isEmpty)
    #expect(matching.verdict == .green)

    let result = try evaluate(
      facts(
        recorded: RecordedPluginSession(
          record: try record(), current: .tree(version: "0.2.0", hash: Self.changedHash))))
    let finding = try #require(sessionFindings(result).first)
    #expect(sessionFindings(result).count == 1)
    #expect(finding.ruleID == Doctor.pluginChangedRuleID)
    #expect(finding.severity == .major)
    #expect(result.verdict == .red)
    for part in [Self.recordedHash, Self.changedHash, "0.1.0", "0.2.0", "start a fresh session"] {
      #expect(finding.message.contains(part), "message lacks \(part): \(finding.message)")
    }
  }

  @Test(
    "no record, or none for the named session, is a doctor.session-record nit that never gates — catches a repository bootstrapped before the hook failing doctor"
  )
  func noRecordIsANote() throws {
    for sessionID in [nil, "session-b"] {
      let result = try evaluate(facts(sessionID: sessionID, recorded: nil))
      let finding = try #require(sessionFindings(result).first)
      #expect(sessionFindings(result).count == 1)
      #expect(finding.ruleID == Doctor.sessionRecordRuleID)
      #expect(finding.severity == .nit)
      #expect(result.verdict == .green)
      #expect(finding.message.contains(".harness/hook-state/sessions"))
      if let sessionID { #expect(finding.message.contains(sessionID)) }
    }
  }

  @Test(
    "a plugin root that no longer exists, or a tree there that can't be hashed, is a major doctor.plugin-changed naming the root — catches a moved plugin passing as unchanged"
  )
  func missingOrUnreadableRootFails() throws {
    for current in [PluginTreeState.rootMissing, .unreadable(reason: "no string \"version\"")] {
      let result = try evaluate(
        facts(recorded: RecordedPluginSession(record: try record(), current: current)))
      let finding = try #require(sessionFindings(result).first)
      #expect(finding.ruleID == Doctor.pluginChangedRuleID)
      #expect(finding.severity == .major)
      #expect(finding.message.contains("/plugins/harness"))
      #expect(finding.message.contains("start a fresh session"))
      #expect(result.verdict == .red)
    }
  }

  @Test(
    "an unreadable record is a major doctor.session-record naming its path and reason, even beside a matching record — catches a corrupt or newer-schema record read as a match"
  )
  func unreadableRecordFails() throws {
    let unreadable = UnreadableSessionRecord(
      path: ".harness/hook-state/sessions/session-c.json",
      reason: "session record has schemaVersion 2; this swiftgate reads 1")
    for recorded in [
      nil,
      RecordedPluginSession(
        record: try record(), current: .tree(version: "0.1.0", hash: Self.recordedHash)),
    ] {
      let result = try evaluate(facts(recorded: recorded, unreadable: [unreadable]))
      let finding = try #require(sessionFindings(result).first)
      #expect(sessionFindings(result).count == 1)
      #expect(finding.ruleID == Doctor.sessionRecordRuleID)
      #expect(finding.severity == .major)
      #expect(finding.message.contains(unreadable.path))
      #expect(finding.message.contains("schemaVersion 2"))
      #expect(result.verdict == .red)
    }
  }
}
