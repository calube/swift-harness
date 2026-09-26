import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

/// A real dependency package (its own git repo, tagged `1.0.0`) and a real main package that
/// depends on it over `file://`, so `swift package resolve`/`swift build`/`swift test` do a real
/// resolve with no network. Mirrors ``TemporaryGitRepository`` (`LiveGitTests.swift`), duplicated
/// here because it runs the built `swiftgate` binary against these two repos, not `LiveGit` alone.
private struct ResolvedFileRewriteRepo {
  static let environment: [String: String] = [
    "PATH": "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin",
    "HOME": FileManager.default.temporaryDirectory.path,
    "GIT_CONFIG_NOSYSTEM": "1",
    "GIT_CONFIG_GLOBAL": "/dev/null",
    "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.com",
    "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.com",
  ]

  static let config = """
    schema = 1
    xcode = "26.2"
    app_scheme = "MainPkg"
    packages = ["MainPkg"]

    [simulator]
    device = "iPhone 17"
    os = "26.2"
    """

  let dependencyRoot: URL
  let root: URL
  let runner = LiveProcessRunner(baseEnvironment: Self.environment)

  /// `Package.resolved`'s real, correctly-resolved content, kept so a test can restore it to
  /// prove the run changed it, or compare a run's output against it unchanged.
  private(set) var resolvedBeforeCorruption = ""

  init() async throws {
    let base = FileManager.default.temporaryDirectory
      .appending(
        path: "swiftgate-resolved-rewrite-\(UUID().uuidString)", directoryHint: .isDirectory
      )
      .resolvingSymlinksInPath()
    dependencyRoot = base.appending(path: "DepPkg", directoryHint: .isDirectory)
    root = base.appending(path: "MainPkg", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: dependencyRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    try await git(dependencyRoot, "init", "-q", "-b", "main")
    try await git(dependencyRoot, "config", "commit.gpgsign", "false")
    try write(
      dependencyRoot, "Package.swift",
      """
      // swift-tools-version:5.9
      import PackageDescription
      let package = Package(
        name: "DepPkg",
        products: [.library(name: "DepPkg", targets: ["DepPkg"])],
        targets: [.target(name: "DepPkg")]
      )
      """)
    try write(
      dependencyRoot, "Sources/DepPkg/DepPkg.swift",
      #"public func depHello() -> String { "hello from dep" }"# + "\n")
    try await commit(dependencyRoot, "v1")
    try await git(dependencyRoot, "tag", "1.0.0")

    try await git(root, "init", "-q", "-b", "main")
    try await git(root, "config", "commit.gpgsign", "false")
    try write(root, ConfigLoader.fileName, Self.config)
    try write(
      root, "MainPkg/Package.swift",
      """
      // swift-tools-version:5.9
      import PackageDescription
      let package = Package(
        name: "MainPkg",
        dependencies: [.package(url: "file://\(dependencyRoot.path)", exact: "1.0.0")],
        targets: [
          .target(name: "MainPkg", dependencies: [.product(name: "DepPkg", package: "DepPkg")]),
          .testTarget(name: "MainPkgTests", dependencies: ["MainPkg"]),
        ]
      )
      """)
    try write(
      root, "MainPkg/Sources/MainPkg/MainPkg.swift",
      """
      import DepPkg
      public func greeting() -> String { depHello() }
      """)
    try write(
      root, "MainPkg/Tests/MainPkgTests/MainPkgTests.swift",
      """
      import Testing
      @testable import MainPkg

      @Test func dependencyResolves() { #expect(MainPkg.greeting() == "hello from dep") }
      """)
    try await run(root, ["package", "resolve"], in: root.appending(path: "MainPkg"), tool: "swift")
    resolvedBeforeCorruption = try String(
      contentsOf: resolvedFile, encoding: .utf8)
    try await commit(root, "baseline, resolved")
  }

  func remove() {
    try? FileManager.default.removeItem(at: dependencyRoot.deletingLastPathComponent())
  }

  var resolvedFile: URL { root.appending(path: "MainPkg/Package.resolved") }

  /// Rewrites the committed `Package.resolved` so its dependency's revision doesn't exist, keeping
  /// its version so the pin still looks satisfiable by version alone, and commits it: the exact
  /// shape of the defect (a committed lockfile naming a missing revision).
  func commitUnresolvablePin() async throws {
    let resolved = try String(contentsOf: resolvedFile, encoding: .utf8)
    let revision = try #require(
      try Regex(#""revision" : "([0-9a-f]{40})""#).firstMatch(in: resolved)?[1].substring)
    let corrupted = resolved.replacingOccurrences(
      of: String(revision), with: String(repeating: "d", count: 40))
    try Data(corrupted.utf8).write(to: resolvedFile)
    try await commit(root, "commit with an unresolvable pin")
  }

  func write(_ base: URL, _ path: String, _ content: String) throws {
    let url = base.appending(path: path)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data((content + "\n").utf8).write(to: url)
  }

  func git(_ base: URL, _ arguments: String...) async throws { try await run(base, arguments) }

  func run(_ base: URL, _ arguments: [String], in directory: URL? = nil, tool: String = "git")
    async throws
  {
    let output = try await runner.run(
      ProcessInvocation(
        executable: tool, arguments: arguments, workingDirectory: (directory ?? base).path,
        timeout: .seconds(120)))
    guard output.status.isSuccess else {
      struct Failure: Error { let message: String }
      throw Failure(message: "\(tool) \(arguments): \(output.stderr.text)\n\(output.stdout.text)")
    }
  }

  func commit(_ base: URL, _ message: String) async throws {
    try await git(base, "add", "-A")
    try await git(base, "commit", "-q", "-m", message)
  }

  /// Runs the built `swiftgate test --tier t1 --json` here, as an agent would, with
  /// `LLVM_PROFILE_FILE` set so coverage from this test run lands in a temp dir, never this
  /// checkout.
  func runTestTierBinary() async throws -> RunReport {
    let binary = Fixture.gateDirectory.appending(path: ".build/debug/swiftgate").path
    let output = try await runner.run(
      ProcessInvocation(
        executable: binary, arguments: ["test", "--tier", "t1", "--json"],
        environmentOverlay: [
          "LLVM_PROFILE_FILE": root.appending(path: "swiftgate-%p.profraw").path
        ],
        workingDirectory: root.path, timeout: .seconds(300)))
    return try RunReportJSON.decode(output.stdout.bytes)
  }
}

@Suite("a committed Package.resolved naming a missing revision")
struct ResolvedFileRewriteTests {
  @Test(
    "test --tier t1 never ends GREEN on an unresolvable pin, and never rewrites the committed Package.resolved — catches SwiftPM silently re-resolving and passing"
  )
  func unresolvablePinNeverEndsGreen() async throws {
    let repo = try await ResolvedFileRewriteRepo()
    defer { repo.remove() }
    try await repo.commitUnresolvablePin()
    let corrupted = try String(contentsOf: repo.resolvedFile, encoding: .utf8)
    #expect(corrupted != repo.resolvedBeforeCorruption)

    let report = try await repo.runTestTierBinary()

    #expect(report.verdict != .green)
    #expect(!report.findings.isEmpty, "an unresolvable pin must name a finding, not end quietly")
    let onDisk = try String(contentsOf: repo.resolvedFile, encoding: .utf8)
    #expect(
      onDisk == corrupted,
      "swiftgate must never rewrite a committed Package.resolved, the same edit a hook denies by hand"
    )
  }
}
