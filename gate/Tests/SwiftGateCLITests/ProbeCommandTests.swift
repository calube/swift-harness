import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

/// `swiftgate probe` end to end. Real builds use the host-only fixture package; every file lands
/// in a temp root, never in this checkout.
@Suite("swiftgate probe")
struct ProbeCommandTests {
  static let design = "docs/designs/probe-host.md"
  static let fixtures = Fixture.gateDirectory.appending(
    path: "Fixtures/probe", directoryHint: .isDirectory)

  static func withTempRoot(_ body: (URL) async throws -> Void) async throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "swiftgate-probe-cli-\(UUID().uuidString)", directoryHint: .isDirectory)
      .resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try await body(root)
  }

  static func options(root: URL) -> ProbeCommandRun.Options {
    ProbeCommandRun.Options(
      design: design, package: fixtures.appending(path: "HostTarget").path,
      target: "HostTarget", sdk: nil, cacheHome: root.appending(path: "home"))
  }

  @Test(
    "a failing probe makes the run RED with a verdict file per snippet, and a rerun is served from the cache — catches a fabricated API exiting 0"
  )
  func hostRunIsRedThenCached() async throws {
    try await Self.withTempRoot { root in
      let probes = root.appending(path: "docs/designs/probe-host.evidence/probes")
      try FileManager.default.createDirectory(at: probes, withIntermediateDirectories: true)
      let snippets = Self.fixtures.appending(path: "host-snippets")
      for name in try FileManager.default.contentsOfDirectory(atPath: snippets.path) {
        try FileManager.default.copyItem(
          at: snippets.appending(path: name), to: probes.appending(path: name))
      }

      let report = await ProbeCommandRun.run(
        options: Self.options(root: root), root: root, runner: LiveProcessRunner())
      #expect(report.verdict == .red)
      #expect(report.verdict.exitCode == 1)
      #expect(report.built == true)
      #expect(
        Dictionary(uniqueKeysWithValues: report.probes.map { ($0.claimId, $0.verdict) }) == [
          "ev-string-has-prefix-exists": .pass, "ev-string-has-fabricated-prefix": .fail,
          "ev-string-has-prefix-int": .fail,
        ])
      for line in report.probes {
        let data = try Data(
          contentsOf: root.appending(path: "docs/designs/probe-host.evidence/\(line.verdictFile)"))
        let record = try JSONDecoder().decode(ProbeVerdictRecord.self, from: data)
        #expect(record.claimId == line.claimId)
        #expect(record.verdict == line.verdict)
      }

      let rerun = await ProbeCommandRun.run(
        options: Self.options(root: root), root: root, runner: LiveProcessRunner())
      #expect(rerun.verdict == .red)
      #expect(rerun.built == false)
      #expect(rerun.probes.map(\.cached) == [true, true, true])
    }
  }

  @Test(
    "the recorded iOS simulator run passes the real TCA API and fails the fabricated one with exit 1 — catches a report shape the design skill can't read"
  )
  func recordedIOSRunParses() throws {
    let report = try JSONDecoder().decode(
      ProbeReport.self, from: try Fixture.data("Probe/ios-sampleapp.stdout"))
    let status = try Fixture.text("Probe/ios-sampleapp.status")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(status == String(report.verdict.exitCode))
    #expect(report.verdict == .red)
    #expect(report.platform == .iOSSimulator)
    #expect(report.built == true)
    #expect(
      Dictionary(uniqueKeysWithValues: report.probes.map { ($0.claimId, $0.verdict) }) == [
        "ev-tca-reducer-macro-builds": .pass, "ev-tca-effect-teleport-exists": .fail,
      ])
    let fabricated = try #require(
      report.probes.first { $0.claimId == "ev-tca-effect-teleport-exists" })
    #expect(fabricated.wrapper == "probes/Probe_ev_tca_effect_teleport_exists.swift")
    #expect(
      fabricated.diagnostics.contains {
        $0.level == .error && $0.file == fabricated.wrapper && $0.message.contains("teleport")
      })
  }

  @Test(
    "a design path outside docs/**/designs is BLOCKED before anything runs — catches probes written into an arbitrary directory"
  )
  func badDesignPathBlocks() async throws {
    try await Self.withTempRoot { root in
      var options = Self.options(root: root)
      options.design = "../elsewhere.md"
      let runner = FakeProcessRunner { _ in ProcessOutput(status: .exited(0)) }
      let report = await ProbeCommandRun.run(options: options, root: root, runner: runner)
      #expect(report.verdict == .blocked)
      #expect(report.verdict.exitCode == 2)
      #expect(runner.invocations.isEmpty)
    }
  }

  @Test(
    "a design with no snippets is BLOCKED, not GREEN — catches an empty probe run passing the gate"
  )
  func noSnippetsBlocks() async throws {
    try await Self.withTempRoot { root in
      let report = await ProbeCommandRun.run(
        options: Self.options(root: root), root: root, runner: LiveProcessRunner())
      #expect(report.verdict == .blocked)
      #expect(report.message.contains("snippet.swift"))
    }
  }
}
