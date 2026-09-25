import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

/// A throwaway repository with real git commits, so `PushDocGates`' `evidence check --at HEAD`
/// reads what git itself has at that ref — never this checkout, whose git common dir every
/// sibling worktree shares. `withPackage` also lays down the minimal package and `.swiftgate.toml`
/// `ProbeRepository` (`TestCommandTests.swift`) uses, so a full `CheckRun.run` still finds T0/T1
/// inputs when a test drives the whole tier rather than `PushDocGates` alone.
private struct DocGatesRepo {
  static let environment: [String: String] = [
    "PATH": "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin",
    "HOME": FileManager.default.temporaryDirectory.path,
    "GIT_CONFIG_NOSYSTEM": "1",
    "GIT_CONFIG_GLOBAL": "/dev/null",
    "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.com",
    "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.com",
  ]

  static let design = "docs/ordering/designs/queue.md"
  static let layout = EvidenceLayout(designDocPath: design)
  static let source = "Sources/Queue/Queue.swift"
  static let quote = "public func enqueue(_ order: Order) async throws"
  static let original = """
    import Foundation

    public struct Queue {
      \(quote)
    }

    """

  static let packageConfig = """
    schema = 1
    xcode = "26.2"
    app_scheme = "Probe"
    packages = ["XUnitProbe"]

    [simulator]
    device = "iPhone 17"
    os = "26.2"
    """

  let root: URL
  let runner = LiveProcessRunner(baseEnvironment: Self.environment)

  init(withPackage: Bool = false) async throws {
    root = FileManager.default.temporaryDirectory
      .appending(
        path: "swiftgate-push-doc-gates-\(UUID().uuidString)", directoryHint: .isDirectory
      )
      .resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    if withPackage {
      let package = root.appending(path: "XUnitProbe", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
      try Data("// swift-tools-version: 6.2\n".utf8).write(
        to: package.appending(path: "Package.swift"))
      try Data(Self.packageConfig.utf8).write(to: root.appending(path: ConfigLoader.fileName))
    }
    try await git("init", "-q", "-b", "main")
    try await git("config", "commit.gpgsign", "false")
  }

  func remove() { try? FileManager.default.removeItem(at: root) }

  func git(_ arguments: String...) async throws {
    let output = try await runner.run(
      ProcessInvocation(
        executable: "git", arguments: arguments, workingDirectory: root.path,
        timeout: .seconds(30)))
    guard output.status.isSuccess else {
      struct GitFailure: Error { let message: String }
      throw GitFailure(message: "git \(arguments): \(output.stderr.text)")
    }
  }

  func commitAll(_ message: String) async throws {
    try await git("add", "-A")
    try await git("commit", "-q", "-m", message)
  }

  func write(_ path: String, _ text: String) throws {
    let url = root.appending(path: path)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
  }

  func writeDesign(status: String) throws {
    try write(
      Self.design,
      """
      ---
      status: \(status)
      area: ordering
      tier: standard
      ---

      # Queue

      """)
  }

  func writeClaim() throws {
    let claim = Claim(
      id: "ev-queue-enqueue-is-async", lane: "codebase", text: "Enqueue is async.",
      citation: Citation(kind: .file, loc: "\(Self.source):L4", pin: "HEAD", quote: Self.quote),
      status: .quoteOk)
    try write(
      Self.layout.claimsFile, String(decoding: try ClaimJSON.encodeLine(claim), as: UTF8.self))
  }

  /// Commits the design, its claim and the cited source, then drops the cited line in a later
  /// commit: the shape every "stale at HEAD" scenario shares.
  func commitApprovedDesignThenStaleItsClaim(status: String) async throws {
    try write(Self.source, Self.original)
    try writeClaim()
    try writeDesign(status: status)
    try await commitAll("add queue")
    try write(Self.source, Self.original.replacingOccurrences(of: Self.quote, with: "// gone"))
    try await commitAll("drop enqueue")
  }

  func context() -> GateRun.Context {
    GateRun.Context(runID: "r", directory: root.appending(path: ".harness/runs/r"))
  }
}

@Suite("push tier: evidence check over approved and built designs")
struct PushTierDocGatesTests {
  @Test(
    "a stale claim in an approved design fails evidence-check.stale-claim at HEAD — catches an approved design's citation drifting unnoticed"
  )
  func staleClaimInApprovedDesignFails() async throws {
    let repo = try await DocGatesRepo()
    defer { repo.remove() }
    try await repo.commitApprovedDesignThenStaleItsClaim(status: "approved")

    let findings = try await PushDocGates.run(root: repo.root, runner: repo.runner)

    let stale = try #require(findings.first { $0.ruleID == PushDocGates.staleClaimRuleID })
    #expect(stale.severity == .major)
    #expect(stale.message.contains("ev-queue-enqueue-is-async"))
    let summary = try #require(findings.first { $0.ruleID == PushDocGates.summaryRuleID })
    #expect(summary.message.contains("1 design doc(s) found, 1 approved or built"))
  }

  @Test(
    "a built design with the same stale claim also fails — catches the check only covering approved"
  )
  func staleClaimInBuiltDesignFails() async throws {
    let repo = try await DocGatesRepo()
    defer { repo.remove() }
    try await repo.commitApprovedDesignThenStaleItsClaim(status: "built")

    let findings = try await PushDocGates.run(root: repo.root, runner: repo.runner)

    #expect(findings.contains { $0.ruleID == PushDocGates.staleClaimRuleID })
  }

  @Test(
    "the same stale claim in a proposed design is never checked — catches every design gated regardless of lifecycle status"
  )
  func proposedDesignNotChecked() async throws {
    let repo = try await DocGatesRepo()
    defer { repo.remove() }
    try await repo.commitApprovedDesignThenStaleItsClaim(status: "proposed")

    let findings = try await PushDocGates.run(root: repo.root, runner: repo.runner)

    #expect(!findings.contains { $0.ruleID == PushDocGates.staleClaimRuleID })
    #expect(!findings.contains { $0.ruleID == PushDocGates.blockedRuleID })
    let summary = try #require(findings.first { $0.ruleID == PushDocGates.summaryRuleID })
    #expect(summary.message.contains("1 design doc(s) found, 0 approved or built"))
  }

  @Test(
    "an unknown frontmatter status is surfaced rather than silently skipped — catches a malformed status hiding a design from evidence check"
  )
  func unknownStatusIsSurfaced() async throws {
    let repo = try await DocGatesRepo()
    defer { repo.remove() }
    try repo.writeDesign(status: "under-review")
    try await repo.commitAll("add queue")

    let findings = try await PushDocGates.run(root: repo.root, runner: repo.runner)

    let finding = try #require(findings.first { $0.ruleID == PushDocGates.statusUnknownRuleID })
    #expect(finding.severity == .major)
    #expect(finding.message.contains("under-review"))
  }

  @Test(
    "no designs in the repository runs the check over zero of them, not just green — catches a check that silently ran nothing"
  )
  func noDesignsRunsOverZero() async throws {
    let repo = try await DocGatesRepo()
    defer { repo.remove() }
    try await repo.git("commit", "--allow-empty", "-q", "-m", "empty")

    let findings = try await PushDocGates.run(root: repo.root, runner: repo.runner)

    #expect(!findings.contains { $0.severity.failsGate })
    let summary = try #require(findings.first { $0.ruleID == PushDocGates.summaryRuleID })
    #expect(summary.message.contains("0 design doc(s) found, 0 approved or built"))
  }

  @Test(
    "fast never runs the design-evidence gate, even over a stale approved design — catches push's own check leaking into fast"
  )
  func fastTierDoesNotRunIt() async throws {
    let repo = try await DocGatesRepo(withPackage: true)
    defer { repo.remove() }
    try await repo.commitApprovedDesignThenStaleItsClaim(status: "approved")
    let swiftPM = try ProbeRepository.swiftPM(replaying: "pass")
    let git = FakeGit(changed: [], mergeBase: "base")

    func run(_ tier: CheckTier) async throws -> GateRunParts {
      try await CheckRun.run(
        root: repo.root, tier: tier, base: "origin/main", context: repo.context(),
        dependencies: CheckRun.Dependencies(
          root: repo.root, swiftPM: swiftPM, git: git, formatter: FakeSwiftFormatter(),
          simulator: .fake, runner: repo.runner))
    }

    let fast = try await run(.fast)
    let push = try await run(.push)

    #expect(!fast.findings.contains { $0.ruleID.hasPrefix("evidence-check.") })
    #expect(push.findings.contains { $0.ruleID == PushDocGates.staleClaimRuleID })
  }
}
