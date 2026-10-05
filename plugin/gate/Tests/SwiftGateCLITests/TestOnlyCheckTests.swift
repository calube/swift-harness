import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

@Suite("test-only: 1 test through an area's own command")
struct TestOnlyCheckTests {
  static let id = "AidokuTests/ConfirmLargeDownloadsSettingTests"

  /// The Aidoku trial's clone config under a temp common dir, and a run directory.
  private struct Clone {
    let base: URL
    var root: URL { base.appending(path: "repo", directoryHint: .isDirectory) }
    var run: URL { base.appending(path: "run", directoryHint: .isDirectory) }
    var layout: BrownfieldStateLayout {
      BrownfieldStateLayout(
        commonDir: base.appending(path: "common", directoryHint: .isDirectory),
        gitDir: base.appending(path: "gitdir", directoryHint: .isDirectory))
    }
    let config: String
    let areas: [BrownfieldArea]

    init() throws {
      base = TestTemporaryDirectory.root.appending(
        path: "swiftgate-test-only-\(UUID().uuidString)", directoryHint: .isDirectory)
      for directory in [base, base.appending(path: "repo"), base.appending(path: "run")] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      }
      config = try Fixture.text("BrownfieldTrial/aidoku-validation-config.toml")
      let layout = BrownfieldStateLayout(
        commonDir: base.appending(path: "common", directoryHint: .isDirectory),
        gitDir: base.appending(path: "gitdir", directoryHint: .isDirectory))
      let file = layout.commonDir.appending(path: StateRootResolver.commonConfigFile)
      try FileManager.default.createDirectory(
        at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(config.utf8).write(to: file)
      guard
        case .brownfield(let loaded)? = try ConfigLoader().loadProfile(
          repositoryRoot: base.appending(path: "repo"), commonDir: layout.commonDir)
      else {
        throw CocoaError(.fileReadCorruptFile)
      }
      areas = loaded.areas
    }

    /// The area's configured `test` command, as the config spells it.
    var configuredTest: String {
      get throws {
        try #require(
          config.split(separator: "\n").first { $0.hasPrefix("test = ") }
            .map { String($0.dropFirst("test = \"".count).dropLast()) })
      }
    }

    func run(
      _ test: String, area: String? = nil, runner: FakeAreaCommandRunner, xcresults: String
    ) async throws -> GateRunParts {
      try await TestOnlyCheck.run(
        root: root, test: test, area: area,
        context: GateRun.Context(runID: "run", directory: run),
        dependencies: TestOnlyCheck.Dependencies(
          areas: areas, layout: layout, trackedTree: TrackedTreeSnapshot(files: [:]),
          runner: runner, xcresults: FakeXcresultReader(scenario: xcresults),
          bound: { _, _ in AreaCommandBound(duration: .seconds(5), reason: "the flat 5 s") },
          changedTests: { _ in .success([]) }))
    }
  }

  private static func verdict(_ parts: GateRunParts) -> Verdict {
    Verdict.merged(
      parts.tiers.map(\.verdict)
        + (parts.findings.contains { $0.severity.failsGate } ? [.red] : []))
  }

  @Test(
    "the Aidoku trial's test that didn't compile reads RED from 1 run of the area's test command narrowed with -only-testing, quoting the compile errors, with no baseline or prove — catches the fixer finding each compile error through a 2-minute merge gate"
  )
  func compileFailureIsRedFromOneNarrowRun() async throws {
    let clone = try Clone()
    defer { try? FileManager.default.removeItem(at: clone.base) }
    let tail = try Fixture.text("BrownfieldTrial/aidoku-validation-3-test-compile.tail.txt")
    let runner = FakeAreaCommandRunner { _ in .failed(exit: 65, tail: tail, junit: nil) }

    let parts = try await clone.run(Self.id, runner: runner, xcresults: "build-error")

    #expect(Self.verdict(parts) == .red)
    #expect(runner.requests.count == 1, "no baseline, prove or second step ran")
    let request = try #require(runner.requests.first)
    let bundle = clone.run.appending(path: "test-only.xcresult").path
    #expect(
      request.command
        == "\(try clone.configuredTest) -only-testing:'\(Self.id)' -resultBundlePath '\(bundle)'",
      "\(request.command)")
    #expect(request.workingDirectory.hasPrefix(clone.root.path), "\(request.workingDirectory)")
    let finding = try #require(parts.findings.first { $0.severity.failsGate })
    #expect(finding.ruleID == BrownfieldRuleID.testFailed.rawValue)
    #expect(
      finding.message.contains("Member 'toggle' expects argument of type 'ToggleSetting'"),
      "\(finding.message)")
    #expect(finding.message.contains(Self.id))
  }

  @Test(
    "an exit 0 whose result bundle shows the test ran reads GREEN — catches a cheap loop that can't tell the fixer its fix compiled and passed"
  )
  func passingTestIsGreen() async throws {
    let clone = try Clone()
    defer { try? FileManager.default.removeItem(at: clone.base) }
    let runner = FakeAreaCommandRunner { _ in .passed }

    let parts = try await clone.run(Self.id, runner: runner, xcresults: "one-test")

    #expect(Self.verdict(parts) == .green, "\(parts.findings.map(\.message))")
    #expect(runner.requests.count == 1)
  }

  @Test(
    "an exit 0 whose result bundle shows no test ran reads RED, naming the id — catches a misspelt id passing as a green loop"
  )
  func noTestMatchedIsRed() async throws {
    let clone = try Clone()
    defer { try? FileManager.default.removeItem(at: clone.base) }
    let runner = FakeAreaCommandRunner { _ in .passed }

    let parts = try await clone.run(
      "AidokuTests/NoSuchTests", runner: runner, xcresults: "zero")

    #expect(Self.verdict(parts) == .red)
    let finding = try #require(parts.findings.first { $0.severity.failsGate })
    #expect(finding.message.contains("no test matched `AidokuTests/NoSuchTests`"), "\(finding.message)")
  }

  @Test(
    "an area the config doesn't hold is BLOCKED and runs nothing — catches a typo reading as a pass"
  )
  func unknownAreaIsBlocked() async throws {
    let clone = try Clone()
    defer { try? FileManager.default.removeItem(at: clone.base) }
    let runner = FakeAreaCommandRunner { _ in .passed }

    let parts = try await clone.run(Self.id, area: "Web", runner: runner, xcresults: "one-test")

    #expect(Self.verdict(parts) == .blocked)
    #expect(runner.requests.isEmpty)
    #expect(parts.findings.contains { $0.message.contains("`Web` is no area") })
  }
}
