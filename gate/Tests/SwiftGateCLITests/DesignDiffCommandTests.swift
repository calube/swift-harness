import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

/// A real repository with three committed revisions of one design doc: the approved draft, a
/// clarify edit, then an amend. Revisions named `<ref>:<path>` resolve through real git here, so
/// a bad ref or a missing path is git's own answer, not a canned one.
private struct DesignHistoryRepo {
  static let environment: [String: String] = [
    "PATH": "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin",
    "HOME": FileManager.default.temporaryDirectory.path,
    "GIT_CONFIG_NOSYSTEM": "1",
    "GIT_CONFIG_GLOBAL": "/dev/null",
    "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.com",
    "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.com",
  ]

  static let design = "docs/designs/queue.md"

  static let approved = """
    ---
    status: approved
    area: ordering
    ---
    # Queue

    ## Problem

    Orders are lost offline.

    ## Requirements

    - req-orders-survive-app-kill: a queued order survives relaunch

    ## Decision

    Persist the queue in a file.

    """
  static let clarified = approved.replacingOccurrences(
    of: "lost offline", with: "lost when offline")
  static let amended = clarified.replacingOccurrences(of: "in a file", with: "in SQLite")

  let root: URL
  let runner = LiveProcessRunner(baseEnvironment: Self.environment)

  var git: LiveGit { LiveGit(runner: runner, repositoryRoot: root.path) }

  init() async throws {
    root = FileManager.default.temporaryDirectory
      .appending(path: "swiftgate-design-diff-\(UUID().uuidString)", directoryHint: .isDirectory)
      .resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try await run("init", "-q", "-b", "main")
    try await run("config", "commit.gpgsign", "false")
    for (message, text) in [
      ("approved", Self.approved), ("clarified", Self.clarified), ("amended", Self.amended),
    ] {
      try write(Self.design, text)
      try await run("add", "-A")
      try await run("commit", "-q", "-m", message)
    }
    // Present in the working tree only, so a lookup at a commit must not find it here.
    try write("docs/designs/extra.md", Self.approved)
  }

  func remove() { try? FileManager.default.removeItem(at: root) }

  func run(_ arguments: String...) async throws {
    let output = try await runner.run(
      ProcessInvocation(
        executable: "git", arguments: arguments, workingDirectory: root.path,
        timeout: .seconds(30)))
    guard output.status.isSuccess else {
      struct GitFailure: Error { let message: String }
      throw GitFailure(message: "git \(arguments): \(output.stderr.text)")
    }
  }

  func write(_ path: String, _ content: String) throws {
    let url = root.appending(path: path)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(content.utf8).write(to: url)
  }

  func writePlan(approvedSha: String?, links: [(String, String)]) throws -> String {
    let at = Date(timeIntervalSince1970: 1_790_000_000)
    let plan = PlanFile(
      schemaVersion: 1, slug: "queue", design: Self.design, designSha: nil,
      approval: approvedSha.map { .init(decision: "approve", designSha: $0, at: at) },
      clarifyChain: links.map { .init(fromSha: $0.0, toSha: $0.1, at: at) }, tier: "standard",
      resume: "planned")
    let url = root.appending(path: "plan.json")
    try PlanFileJSON.encode(plan).write(to: url)
    return url.path
  }

  func diff(_ old: String, _ new: String) async -> DesignDiffReport {
    await DesignDiffRun.diff(old: old, new: new, workingDirectory: root, git: git)
  }
}

@Suite("swiftgate design-diff")
struct DesignDiffCommandTests {
  @Test(
    "two committed revisions classify through real git — catches <ref>:<path> read from the wrong place"
  )
  func classifiesCommittedRevisions() async throws {
    let repo = try await DesignHistoryRepo()
    defer { repo.remove() }
    let design = DesignHistoryRepo.design

    let clarify = await repo.diff("HEAD~2:\(design)", "HEAD~1:\(design)")
    #expect(clarify.status == .classified)
    #expect(clarify.changeClass == .clarify)
    #expect(clarify.oldSha == DesignSha.of(DesignHistoryRepo.approved))
    #expect(clarify.newSha == DesignSha.of(DesignHistoryRepo.clarified))
    #expect(clarify.verdict.exitCode == 0)

    let amend = await repo.diff("HEAD~1:\(design)", repo.root.appending(path: design).path)
    #expect(amend.changeClass == .amend)
    #expect(amend.triggers == [.decision])
    #expect(amend.verdict.exitCode == 0)
  }

  @Test(
    "a ref git can't resolve fails with unknown-ref and exit 2 — catches a silent fall back to the working-tree file"
  )
  func unknownRefIsBlocked() async throws {
    let repo = try await DesignHistoryRepo()
    defer { repo.remove() }
    let report = await repo.diff(
      "no-such-branch:\(DesignHistoryRepo.design)", "HEAD:\(DesignHistoryRepo.design)")
    #expect(report.status == .unknownRef)
    #expect(report.verdict.exitCode == 2)
    #expect(report.changeClass == nil)
    #expect(report.message.contains("no-such-branch"))
  }

  @Test(
    "a path absent at a real ref fails with missing-path and exit 2, even when the working tree has it — catches a working-tree fallback"
  )
  func missingPathIsBlocked() async throws {
    let repo = try await DesignHistoryRepo()
    defer { repo.remove() }
    let report = await repo.diff("HEAD:docs/designs/extra.md", "HEAD:\(DesignHistoryRepo.design)")
    #expect(report.status == .missingPath)
    #expect(report.verdict.exitCode == 2)
    #expect(report.oldSha == nil)
    #expect(report.message.contains("docs/designs/extra.md"))
  }

  @Test(
    "an unreadable working-tree file fails with unreadable and exit 2 — catches a missing doc read as empty"
  )
  func unreadableFileIsBlocked() async throws {
    let repo = try await DesignHistoryRepo()
    defer { repo.remove() }
    let report = await repo.diff("docs/designs/nope.md", "HEAD:\(DesignHistoryRepo.design)")
    #expect(report.status == .unreadable)
    #expect(report.verdict.exitCode == 2)
  }

  @Test(
    "a chain of committed clarify links verifies with exit 0 — catches a valid approval chain rejected"
  )
  func validChainFromPlan() async throws {
    let repo = try await DesignHistoryRepo()
    defer { repo.remove() }
    let approved = DesignSha.of(DesignHistoryRepo.approved)
    let clarified = DesignSha.of(DesignHistoryRepo.clarified)
    let plan = try repo.writePlan(approvedSha: approved, links: [(approved, clarified)])
    let report = await DesignDiffRun.chain(
      planPath: plan, workingDirectory: repo.root, git: repo.git)
    #expect(report.status == .valid)
    #expect(report.endSha == clarified)
    #expect(report.verdict.exitCode == 0)
  }

  @Test(
    "a committed link that is really an amend breaks the chain with exit 1 and names it — catches approval surviving an amend"
  )
  func amendLinkBreaksChain() async throws {
    let repo = try await DesignHistoryRepo()
    defer { repo.remove() }
    let approved = DesignSha.of(DesignHistoryRepo.approved)
    let clarified = DesignSha.of(DesignHistoryRepo.clarified)
    let amended = DesignSha.of(DesignHistoryRepo.amended)
    let plan = try repo.writePlan(
      approvedSha: approved, links: [(approved, clarified), (clarified, amended)])
    let report = await DesignDiffRun.chain(
      planPath: plan, workingDirectory: repo.root, git: repo.git)
    #expect(report.status == .broken)
    #expect(report.verdict.exitCode == 1)
    #expect(report.brokenLink?.index == 1)
    #expect(report.brokenLink?.problem == .amend)
    #expect(report.brokenLink?.triggers == [.decision])
    #expect(report.message.contains("link 1"))

    let json = DesignDiffRun.render(report, format: .json)
    #expect(json.contains(#""problem" : "amend""#))
    #expect(json.contains(#""status" : "broken""#))
  }

  @Test(
    "a plan with no approval can't anchor a chain: exit 2 — catches an unapproved plan read as a valid chain"
  )
  func noApprovalIsBlocked() async throws {
    let repo = try await DesignHistoryRepo()
    defer { repo.remove() }
    let plan = try repo.writePlan(approvedSha: nil, links: [])
    let report = await DesignDiffRun.chain(
      planPath: plan, workingDirectory: repo.root, git: repo.git)
    #expect(report.status == .noApproval)
    #expect(report.verdict.exitCode == 2)
  }

  @Test(
    "the JSON report carries the class and ids under fixed keys — catches a renamed key breaking the design skill"
  )
  func jsonKeys() async throws {
    let repo = try await DesignHistoryRepo()
    defer { repo.remove() }
    let report = await repo.diff(
      "HEAD~1:\(DesignHistoryRepo.design)", "HEAD:\(DesignHistoryRepo.design)")
    let object = try #require(
      try JSONSerialization.jsonObject(with: Data(DesignDiffRun.render(report, format: .json).utf8))
        as? [String: Any])
    #expect(object["command"] as? String == "design-diff")
    #expect(object["mode"] as? String == "diff")
    #expect(object["class"] as? String == "amend")
    #expect(object["triggers"] as? [String] == ["decision"])
    #expect(object["changedIds"] as? [String] == [])
    #expect(object["verdict"] as? String == "GREEN")
    #expect(object["newSha"] as? String == DesignSha.of(DesignHistoryRepo.amended))
  }
}
