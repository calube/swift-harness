import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

/// A throwaway repository holding the probe package (as `XUnitProbe/`), a config naming it, and a
/// SwiftPM that describes it from the recorded manifest and replays recorded `swift test` runs.
struct ProbeRepository {
  let root: URL

  static let config = """
    schema = 1
    xcode = "26.2"
    app_scheme = "Probe"
    packages = ["XUnitProbe"]

    [simulator]
    device = "iPhone 17"
    os = "26.2"
    """

  init(config: String? = Self.config) throws {
    root = FileManager.default.temporaryDirectory
      .appending(path: "swiftgate-probe-\(UUID().uuidString)", directoryHint: .isDirectory)
      .resolvingSymlinksInPath()
    let package = root.appending(path: "XUnitProbe", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
    try Data("// swift-tools-version: 6.2\n".utf8).write(
      to: package.appending(path: "Package.swift"))
    if let config {
      try Data(config.utf8).write(to: root.appending(path: ConfigLoader.fileName))
    }
  }

  func remove() { try? FileManager.default.removeItem(at: root) }

  func write(_ path: String, _ content: String) throws {
    let url = root.appending(path: path)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(content.utf8).write(to: url)
  }

  static func manifest() throws -> PackageManifest {
    try PackageManifest(
      describeJSON: Fixture.data("SwiftPM/describe-XUnitProbe.json"),
      repositoryRoot: "\(Fixture.repositoryRoot)/gate/Fixtures/swifttest")
  }

  /// Replays `scenario`'s recorded reports and console output for every `swift test`.
  static func swiftPM(
    replaying scenario: String, coveragePaths: [String: String] = [:],
    manifest served: PackageManifest? = nil
  ) throws -> FakeSwiftPM {
    FakeSwiftPM(serving: [try served ?? manifest()], coveragePaths: coveragePaths) {
      request throws(SwiftPMError) in
      let swiftTesting = LiveSwiftPM.swiftTestingReportPath(for: request.xunitOutputPath)
      for (name, destination) in [
        ("\(scenario).xml", request.xunitOutputPath),
        ("\(scenario)-swift-testing.xml", swiftTesting),
      ] {
        try? Fixture.data("SwiftTest/\(name)").write(to: URL(filePath: destination))
      }
      let status = (try? Fixture.text("SwiftTest/\(scenario).status")) ?? "1"
      return SwiftTestRun(
        output: ProcessOutput(
          status: .exited(Int32(status.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 1),
          stdout: (try? Fixture.text("SwiftTest/\(scenario).stdout")) ?? "",
          stderr: (try? Fixture.text("SwiftTest/\(scenario).stderr")) ?? ""),
        xctestReportPath: request.xunitOutputPath, swiftTestingReportPath: swiftTesting)
    }
  }

  func context() -> GateRun.Context {
    GateRun.Context(runID: "r", directory: root.appending(path: ".harness/runs/r"))
  }
}

@Suite("swiftgate test")
struct TestCommandTests {
  @Test(
    "with no ref every T1 target runs and failures make the tier RED — catches T1 passing on failing tests"
  )
  func allTargets() async throws {
    let repository = try ProbeRepository()
    defer { repository.remove() }
    let swiftPM = try ProbeRepository.swiftPM(replaying: "fail")

    let parts = try await TestCheck.run(
      root: repository.root, swiftPM: swiftPM, git: FakeGit(), affectedSince: nil,
      context: repository.context())

    #expect(swiftPM.testRequests.map(\.filters) == [[#"^(EmptyTests|ProbeTests)\."#]])
    #expect(parts.tiers.map(\.tier) == [.t1])
    #expect(parts.tiers.first?.verdict == .red)
    #expect(parts.findings.filter { $0.ruleID == "t1.test-failed" }.count == 2)
  }

  @Test(
    "--affected-since runs nothing for a change outside every package — catches a doc edit paying for the test suite"
  )
  func unaffected() async throws {
    let repository = try ProbeRepository()
    defer { repository.remove() }
    let swiftPM = try ProbeRepository.swiftPM(replaying: "pass")
    let git = FakeGit(changed: ["docs/notes.md"])

    let parts = try await TestCheck.run(
      root: repository.root, swiftPM: swiftPM, git: git, affectedSince: "HEAD",
      context: repository.context())

    #expect(swiftPM.testRequests.isEmpty)
    #expect(git.changedSinceRefs == ["HEAD"])
    #expect(parts.tiers.first?.verdict == .green)
    #expect(parts.tiers.first?.testCounts == (try TestCounts(passed: 0, failed: 0, skipped: 0)))
  }

  @Test(
    "--affected-since runs the package a changed source belongs to — catches a changed module's tests skipped"
  )
  func affected() async throws {
    let repository = try ProbeRepository()
    defer { repository.remove() }
    let swiftPM = try ProbeRepository.swiftPM(replaying: "pass")
    let git = FakeGit(changed: ["XUnitProbe/Sources/Probe/Probe.swift"])

    let parts = try await TestCheck.run(
      root: repository.root, swiftPM: swiftPM, git: git, affectedSince: "main",
      context: repository.context())

    #expect(swiftPM.testRequests.count == 1)
    #expect(parts.tiers.first?.testCounts?.passed == 2)
  }

  @Test(
    "no config is RED and a git failure is BLOCKED — catches T1 claiming GREEN when it could not plan"
  )
  func cannotPlan() async throws {
    let bare = try ProbeRepository(config: nil)
    defer { bare.remove() }
    let missing = try await TestCheck.run(
      root: bare.root, swiftPM: try ProbeRepository.swiftPM(replaying: "pass"), git: FakeGit(),
      affectedSince: nil, context: bare.context())
    #expect(missing.tiers.first?.verdict == .red)
    #expect(missing.findings.first?.file == ConfigLoader.fileName)

    let repository = try ProbeRepository()
    defer { repository.remove() }
    let gitDown = try await TestCheck.run(
      root: repository.root, swiftPM: try ProbeRepository.swiftPM(replaying: "pass"),
      git: FakeGit(failure: .invalidRef("-x")), affectedSince: "-x",
      context: repository.context())
    #expect(gitDown.tiers.first?.verdict == .blocked)
  }

  @Test("--affected-since is parsed for t1 — catches the scope flag being dropped")
  func tierValidation() throws {
    let command = try #require(
      try SwiftGate.parseAsRoot(["test", "--tier", "t1", "--affected-since", "main"])
        as? TestCommand)
    #expect(command.affectedSince == "main")
  }
}
