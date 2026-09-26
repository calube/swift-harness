import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

/// `swiftgate probe`'s scratch-package builder. Real builds run against the host-only fixture
/// package in `gate/Fixtures/probe/`; everything else replays captured `swift build` output
/// (`gate/Tests/Fixtures/Probe/`) through a fake runner. Every file lands in a temp root, never in
/// this checkout.
@Suite("probe builder")
struct ProbeBuilderTests {
  static let fixtures = Fixture.gateDirectory.appending(
    path: "Fixtures/probe", directoryHint: .isDirectory)

  struct Sandbox {
    let root: URL
    var evidenceRoot: URL { root.appending(path: "docs/designs/probe.evidence") }
    var probesDirectory: URL { evidenceRoot.appending(path: "probes") }
    var scratch: ProbeScratchLayout { ProbeScratchLayout(worktreeRoot: root) }
    var cache: EvidenceCacheStore { EvidenceCacheStore(home: root.appending(path: "home")) }

    func builder(_ runner: any ProcessRunner) -> ProbeBuilder {
      ProbeBuilder(runner: runner, cache: cache, scratch: scratch)
    }

    func writeSnippet(_ claimID: String, _ source: String) throws {
      try FileManager.default.createDirectory(
        at: probesDirectory, withIntermediateDirectories: true)
      try Data(source.utf8).write(
        to: probesDirectory.appending(path: "\(claimID).snippet.swift"))
    }

    func copySnippets(from directory: String) throws {
      try FileManager.default.createDirectory(
        at: probesDirectory, withIntermediateDirectories: true)
      let source = ProbeBuilderTests.fixtures.appending(path: directory)
      for name in try FileManager.default.contentsOfDirectory(atPath: source.path) {
        try FileManager.default.copyItem(
          at: source.appending(path: name), to: probesDirectory.appending(path: name))
      }
    }

    func record(_ claimID: String) throws -> ProbeVerdictRecord {
      let data = try Data(
        contentsOf: evidenceRoot.appending(path: ProbeVerdictRecord.path(forClaimID: claimID)))
      return try JSONDecoder().decode(ProbeVerdictRecord.self, from: data)
    }

    func exists(_ evidenceRelative: String) -> Bool {
      FileManager.default.fileExists(atPath: evidenceRoot.appending(path: evidenceRelative).path)
    }
  }

  static func withSandbox(_ body: (Sandbox) async throws -> Void) async throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "swiftgate-probe-\(UUID().uuidString)", directoryHint: .isDirectory)
      .resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try await body(Sandbox(root: root))
  }

  static func hostTarget(sdk: String = "26.2", pins: [String: String] = [:]) -> ProbeTarget {
    ProbeTarget(
      platform: .host, sdkVersion: sdk,
      platforms: [ProbePlatformRequirement(name: "macOS", version: "15.0")], dependencies: [],
      pins: pins, packageResolved: nil)
  }

  static let composableArchitecture = ProbeDependency(
    identity: "swift-composable-architecture",
    url: "https://github.com/pointfreeco/swift-composable-architecture", version: "1.26.2",
    traits: [], products: ["ComposableArchitecture"])

  static func iOSTarget(sdk: String = "26.2") -> ProbeTarget {
    ProbeTarget(
      platform: .iOSSimulator, sdkVersion: sdk,
      platforms: [ProbePlatformRequirement(name: "iOS", version: "18.0")],
      dependencies: [composableArchitecture],
      pins: ["swift-composable-architecture": "1.26.2"], packageResolved: nil)
  }

  /// Answers every build with a captured `swift build` run.
  static func replaying(_ scenario: String) throws -> FakeProcessRunner {
    let stdout = try Fixture.text("Probe/\(scenario).stdout")
    let status = try #require(
      Int32(
        try Fixture.text("Probe/\(scenario).status")
          .trimmingCharacters(in: .whitespacesAndNewlines)))
    return FakeProcessRunner { _ in ProcessOutput(status: .exited(status), stdout: stdout) }
  }

  static func isBuild(_ invocation: ProcessInvocation) -> Bool {
    invocation.arguments.first == "build"
      || invocation.arguments.prefix(2) == ["xcodebuild", "build"]
  }

  // MARK: real host builds

  @Test(
    "a real API passes while a fabricated API and a real API with the wrong signature fail — catches a hallucinated API reaching Decision"
  )
  func hostFixtureVerdicts() async throws {
    try await Self.withSandbox { sandbox in
      try sandbox.copySnippets(from: "host-snippets")
      let load = try await ProbeTargetLoader.load(
        packageDirectory: Self.fixtures.appending(path: "HostTarget"), target: "HostTarget",
        runner: LiveProcessRunner())
      #expect(load.target.platform == .host)

      let outcome = await sandbox.builder(LiveProcessRunner()).run(
        evidenceRoot: sandbox.evidenceRoot, target: load.target)

      guard case .judged(let results, let built, _) = outcome else {
        Issue.record("expected verdicts, got \(outcome)")
        return
      }
      #expect(built)
      #expect(
        results.map(\.record.claimId).sorted() == [
          "ev-string-has-fabricated-prefix", "ev-string-has-prefix-exists",
          "ev-string-has-prefix-int",
        ])

      let real = try sandbox.record("ev-string-has-prefix-exists")
      #expect(real.verdict == .pass)
      #expect(real.diagnostics.allSatisfy { $0.level != .error })

      let fabricated = try sandbox.record("ev-string-has-fabricated-prefix")
      #expect(fabricated.verdict == .fail)
      #expect(fabricated.diagnostics.contains { $0.message.contains("hasFabricatedPrefix") })
      #expect(
        fabricated.diagnostics.allSatisfy {
          $0.file == "probes/Probe_ev_string_has_fabricated_prefix.swift"
        })

      let wrongSignature = try sandbox.record("ev-string-has-prefix-int")
      #expect(wrongSignature.verdict == .fail)
      #expect(
        wrongSignature.diagnostics.contains { $0.level == .error && $0.message.contains("Int") })
    }
  }

  // MARK: file contract

  @Test(
    "each snippet yields its wrapper and a verdict file in the contract's shape — catches evidence check reading a format probe never writes"
  )
  func fileContract() async throws {
    try await Self.withSandbox { sandbox in
      for id in [
        "ev-good-effect-cancel", "ev-warns-but-compiles", "ev-fabricated-symbol",
        "ev-wrong-signature",
      ] {
        try sandbox.writeSnippet(id, "import Foundation\n\nstatic func run() -> Int { 1 }\n")
      }
      let target = Self.hostTarget(pins: ["swift-collections": "1.7.0"])
      let outcome = await sandbox.builder(try Self.replaying("mixed")).run(
        evidenceRoot: sandbox.evidenceRoot, target: target)
      guard case .judged = outcome else {
        Issue.record("expected verdicts, got \(outcome)")
        return
      }

      let wrapper = try String(
        contentsOf: sandbox.probesDirectory.appending(path: "Probe_ev_wrong_signature.swift"),
        encoding: .utf8)
      #expect(wrapper.hasPrefix("import Foundation\n"))
      #expect(wrapper.contains("enum Probe_ev_wrong_signature {\n"))
      #expect(wrapper.contains("  static func run() -> Int { 1 }\n"))

      let raw = try Data(
        contentsOf: sandbox.evidenceRoot.appending(
          path: ProbeVerdictRecord.path(forClaimID: "ev-wrong-signature")))
      let object = try #require(try JSONSerialization.jsonObject(with: raw) as? [String: Any])
      #expect(
        Set(object.keys) == [
          "claimId", "verdict", "diagnostics", "pins", "sdk", "snippetSha256", "sourceSha256",
        ])

      let failing = try sandbox.record("ev-wrong-signature")
      #expect(failing.verdict == .fail)
      #expect(failing.sdk == "26.2")
      #expect(failing.pins == ["swift-collections": "1.7.0"])
      #expect(
        failing.diagnostics == [
          ProbeVerdictRecord.Diagnostic(
            file: "probes/Probe_ev_wrong_signature.swift", line: 3, column: 21, level: .error,
            message: "cannot convert value of type 'Int' to expected argument type 'String'")
        ])
      let snippetBytes = try Data(
        contentsOf: sandbox.probesDirectory.appending(path: "ev-wrong-signature.snippet.swift"))
      #expect(object["snippetSha256"] as? String == CaptureDigest.sha256Hex(snippetBytes))
      #expect(object["sourceSha256"] as? String == CaptureDigest.sha256Hex(Data(wrapper.utf8)))
      #expect(try sandbox.record("ev-fabricated-symbol").verdict == .fail)
      #expect(try sandbox.record("ev-good-effect-cancel").verdict == .pass)
      let warns = try sandbox.record("ev-warns-but-compiles")
      #expect(warns.verdict == .pass)
      #expect(warns.diagnostics.map(\.level) == [.warning])
    }
  }

  @Test(
    "an error in a file that is no probe blocks the run and writes no verdict — catches an unrelated build break read as probes passing"
  )
  func unattributedErrorBlocks() async throws {
    try await Self.withSandbox { sandbox in
      for id in [
        "ev-good-effect-cancel", "ev-warns-but-compiles", "ev-fabricated-symbol",
        "ev-wrong-signature",
      ] {
        try sandbox.writeSnippet(id, "static func run() -> Int { 1 }\n")
      }
      let outcome = await sandbox.builder(try Self.replaying("unattributed")).run(
        evidenceRoot: sandbox.evidenceRoot, target: Self.hostTarget())
      guard case .blocked(let message, _) = outcome else {
        Issue.record("expected blocked, got \(outcome)")
        return
      }
      #expect(message.contains("Extra.swift"))
      #expect(!sandbox.exists(ProbeVerdictRecord.path(forClaimID: "ev-good-effect-cancel")))
    }
  }

  @Test(
    "a failed build with no diagnostic blocks instead of passing every probe — catches a resolution failure read as green"
  )
  func failedBuildWithoutDiagnosticsBlocks() async throws {
    try await Self.withSandbox { sandbox in
      try sandbox.writeSnippet("ev-good-effect-cancel", "static func run() -> Int { 1 }\n")
      let runner = FakeProcessRunner { _ in
        ProcessOutput(status: .exited(1), stderr: "error: Could not resolve package dependencies")
      }
      let outcome = await sandbox.builder(runner).run(
        evidenceRoot: sandbox.evidenceRoot, target: Self.hostTarget())
      guard case .blocked(let message, _) = outcome else {
        Issue.record("expected blocked, got \(outcome)")
        return
      }
      #expect(message.contains("Could not resolve"))
      #expect(!sandbox.exists(ProbeVerdictRecord.path(forClaimID: "ev-good-effect-cancel")))
    }
  }

  // MARK: argv

  @Test(
    "the iOS build is xcodebuild with -skipMacroValidation and DerivedData under the worktree's .harness/probe — catches a headless macro failure or a shared DerivedData"
  )
  func xcodebuildArguments() async throws {
    try await Self.withSandbox { sandbox in
      try sandbox.writeSnippet("ev-tca-effect-run-exists", "static func run() {}\n")
      let runner = FakeProcessRunner { _ in ProcessOutput(status: .exited(0)) }
      _ = await sandbox.builder(runner).run(
        evidenceRoot: sandbox.evidenceRoot, target: Self.iOSTarget())

      let build = try #require(runner.invocations.first(where: Self.isBuild))
      #expect(build.executable == "/usr/bin/xcrun")
      #expect(
        build.arguments == [
          "xcodebuild", "build", "-quiet", "-scheme", "ProbeScratch",
          "-destination", "generic/platform=iOS Simulator",
          "-derivedDataPath", sandbox.root.appending(path: ".harness/probe/DerivedData").path,
          "-skipMacroValidation", "-onlyUsePackageVersionsFromResolvedFile",
        ])
      #expect(
        build.workingDirectory
          == sandbox.root.appending(path: ".harness/probe/ProbeScratch").path)
    }
  }

  @Test(
    "a host-only target builds with swift build inside the scratch package — catches a host package sent through xcodebuild"
  )
  func hostBuildArguments() async throws {
    try await Self.withSandbox { sandbox in
      try sandbox.writeSnippet("ev-string-has-prefix-exists", "static func run() {}\n")
      let runner = FakeProcessRunner { _ in ProcessOutput(status: .exited(0)) }
      _ = await sandbox.builder(runner).run(
        evidenceRoot: sandbox.evidenceRoot, target: Self.hostTarget())
      let build = try #require(runner.invocations.first(where: Self.isBuild))
      #expect(build.executable == "swift")
      #expect(build.arguments == ["build", "--only-use-versions-from-resolved-file"])
      #expect(
        build.workingDirectory
          == sandbox.root.appending(path: ".harness/probe/ProbeScratch").path)
    }
  }

  @Test(
    "a probe no longer on disk is removed from the scratch package — catches a stale probe file breaking every later build"
  )
  func staleScratchFilesRemoved() async throws {
    try await Self.withSandbox { sandbox in
      try sandbox.writeSnippet("ev-first-probe-file", "static func a() {}\n")
      try sandbox.writeSnippet("ev-second-probe-file", "static func b() {}\n")
      let runner = FakeProcessRunner { _ in ProcessOutput(status: .exited(0)) }
      _ = await sandbox.builder(runner).run(
        evidenceRoot: sandbox.evidenceRoot, target: Self.hostTarget())
      try FileManager.default.removeItem(
        at: sandbox.probesDirectory.appending(path: "ev-second-probe-file.snippet.swift"))
      _ = await sandbox.builder(runner).run(
        evidenceRoot: sandbox.evidenceRoot, target: Self.hostTarget(sdk: "26.3"))

      let sources = sandbox.scratch.package.appending(path: "Sources/ProbeScratch")
      #expect(
        try FileManager.default.contentsOfDirectory(atPath: sources.path).sorted() == [
          "Probe_ev_first_probe_file.swift"
        ])
    }
  }

  // MARK: cache

  @Test(
    "same pins and SDK hit the cache with no build; a changed SDK or pin builds again — catches a stale verdict served across toolchains"
  )
  func cacheHitsSkipTheBuild() async throws {
    try await Self.withSandbox { sandbox in
      for id in [
        "ev-good-effect-cancel", "ev-warns-but-compiles", "ev-fabricated-symbol",
        "ev-wrong-signature",
      ] {
        try sandbox.writeSnippet(id, "static func run() -> String { \"\(id)\" }\n")
      }
      let pins = ["swift-collections": "1.7.0"]

      let first = try Self.replaying("mixed")
      _ = await sandbox.builder(first).run(
        evidenceRoot: sandbox.evidenceRoot, target: Self.hostTarget(pins: pins))
      #expect(first.invocations.filter(Self.isBuild).count == 1)

      let second = FakeProcessRunner { invocation in
        Issue.record("cache hit still ran \(invocation.executable) \(invocation.arguments)")
        return ProcessOutput(status: .exited(0))
      }
      let hit = await sandbox.builder(second).run(
        evidenceRoot: sandbox.evidenceRoot, target: Self.hostTarget(pins: pins))
      #expect(second.invocations.isEmpty)
      guard case .judged(let results, let built, _) = hit else {
        Issue.record("expected verdicts, got \(hit)")
        return
      }
      #expect(!built)
      #expect(results.map(\.cached) == [true, true, true, true])
      let cached = try sandbox.record("ev-fabricated-symbol")
      #expect(cached.verdict == .fail)
      #expect(
        cached.diagnostics == [
          ProbeVerdictRecord.Diagnostic(
            file: "probes/Probe_ev_fabricated_symbol.swift", line: 3, column: 5, level: .error,
            message: "cannot find 'fabricatedAPIThatDoesNotExist' in scope")
        ])
      #expect(try sandbox.record("ev-good-effect-cancel").verdict == .pass)

      let otherSDK = FakeProcessRunner { _ in ProcessOutput(status: .exited(0)) }
      _ = await sandbox.builder(otherSDK).run(
        evidenceRoot: sandbox.evidenceRoot, target: Self.hostTarget(sdk: "26.4", pins: pins))
      #expect(otherSDK.invocations.filter(Self.isBuild).count == 1)

      let otherPin = FakeProcessRunner { _ in ProcessOutput(status: .exited(0)) }
      _ = await sandbox.builder(otherPin).run(
        evidenceRoot: sandbox.evidenceRoot,
        target: Self.hostTarget(pins: ["swift-collections": "1.8.0"]))
      #expect(otherPin.invocations.filter(Self.isBuild).count == 1)

      let contents = try sandbox.cache.contents(of: .sdk(pin: "macosx26.2"))
      // Four entries for the first pins, reused once each; four more for the changed pin.
      #expect(
        contents.claims.filter { $0.origin == .probe }.map(\.reuseCount) == [
          1, 1, 1, 1, 0, 0, 0, 0,
        ])
    }
  }

  // MARK: manifest

  @Test(
    "the scratch manifest keeps only the target's remote products and never lists swift-issue-reporting or a MainActor default — catches a direct issue-reporting dependency or a changed isolation"
  )
  func scratchManifestExcludesIssueReporting() async throws {
    let load = try await ProbeTargetLoader.load(
      packageDirectory: Self.fixtures.appending(path: "IssueReportingTarget"),
      target: "IssueReportingTarget", runner: LiveProcessRunner(), sdkVersion: "26.2")
    #expect(load.target.platform == .iOSSimulator)
    #expect(load.target.dependencies.map(\.identity) == ["swift-composable-architecture"])
    #expect(load.target.pins["swift-composable-architecture"] == "1.26.2")
    #expect(load.notes.contains { $0.contains("IssueReporting") })
    #expect(load.notes.contains { $0.contains("HostTarget") })

    let manifest = ProbeScratchManifest.render(load.target)
    #expect(!manifest.contains("issue-reporting"))
    #expect(!manifest.contains("IssueReporting"))
    #expect(!manifest.contains("xctest-dynamic-overlay"))
    #expect(!manifest.contains("MainActor"))
    #expect(!manifest.contains("defaultIsolation"))
    #expect(!manifest.contains("path:"))
    #expect(
      manifest.contains(
        #".package(url: "https://github.com/pointfreeco/swift-composable-architecture", exact: "1.26.2", traits: ["ComposableArchitecture2Deprecations"])"#
      ))
    #expect(
      manifest.contains(
        #".product(name: "ComposableArchitecture", package: "swift-composable-architecture")"#))
    #expect(manifest.contains(#".iOS("18.0")"#))
  }

  @Test(
    "a remote dependency with no version in Package.resolved is refused — catches a probe built against an unpinned package"
  )
  func unpinnedDependencyRefused() async throws {
    try await Self.withSandbox { sandbox in
      let package = sandbox.root.appending(path: "IssueReportingTarget")
      try FileManager.default.copyItem(
        at: Self.fixtures.appending(path: "IssueReportingTarget"), to: package)
      try Data(#"{"pins": [], "version": 3}"#.utf8).write(
        to: package.appending(path: "Package.resolved"))
      await #expect(throws: ProbeError.unpinned(identity: "swift-composable-architecture")) {
        _ = try await ProbeTargetLoader.load(
          packageDirectory: package, target: "IssueReportingTarget", runner: LiveProcessRunner(),
          sdkVersion: "26.2")
      }
    }
  }

  @Test(
    "the wrapper hoists the snippet's imports and names the enum after the claim — catches a diagnostic that can't be attributed back"
  )
  func wrapperShape() {
    let source = ProbeWrapper.source(
      claimID: "ev-tca-effect-run-exists",
      snippet: "// why\nimport ComposableArchitecture\n\nstatic func run() {}\n")
    #expect(
      source
        == "import ComposableArchitecture\n\nenum Probe_ev_tca_effect_run_exists {\n  // why\n\n  static func run() {}\n}\n"
    )
  }
}
