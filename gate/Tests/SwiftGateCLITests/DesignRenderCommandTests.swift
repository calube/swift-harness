import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

/// Every test runs against a temp repository root with ``FakeGit`` and a `PATH` that can't
/// resolve `mmdc` or `xcrun`, so nothing reads or writes this checkout's docs or git state.
@Suite("swiftgate design-render")
struct DesignRenderCommandTests {
  static let fixturesRoot = URL(filePath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "Fixtures/design", directoryHint: .isDirectory)

  static let runner = LiveProcessRunner(
    baseEnvironment: ["PATH": "/swiftgate-test-path-with-no-tools"])
  static let docPath = "docs/checkout/designs/offline-order-queue.md"

  struct Repository {
    let root: URL

    init(doc: String, claims: String?) throws {
      root = FileManager.default.temporaryDirectory
        .appending(
          path: "swiftgate-design-render-\(UUID().uuidString)", directoryHint: .isDirectory
        )
        .resolvingSymlinksInPath()
      try write(DesignRenderCommandTests.docPath, doc)
      if let claims {
        try write("docs/checkout/designs/offline-order-queue.evidence/claims.jsonl", claims)
      }
    }

    func write(_ path: String, _ text: String) throws {
      let url = root.appending(path: path)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(text.utf8).write(to: url)
    }

    var outputURL: URL { root.appending(path: DesignRenderRun.outputPath(for: docPath)) }

    func run() async -> DesignRenderRun.Outcome {
      await DesignRenderRun.run(
        options: .init(design: docPath, packageResolved: "Package.resolved", sdk: nil),
        root: root, git: FakeGit(), runner: runner)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
  }

  static func validDoc() throws -> String {
    try String(contentsOf: fixturesRoot.appending(path: "valid.md"), encoding: .utf8)
  }

  static func validClaims() throws -> String {
    try String(
      contentsOf: fixturesRoot.appending(path: "valid.evidence/claims.jsonl"), encoding: .utf8)
  }

  @Test(
    "a lint-clean doc is written to .harness/design-render/<slug>.html with its checked evidence — catches a render that skips the evidence check"
  )
  func writesPage() async throws {
    let repository = try Repository(doc: try Self.validDoc(), claims: try Self.validClaims())
    defer { repository.remove() }
    let outcome = await repository.run()
    let sha = DesignSha.of(try Self.validDoc())
    #expect(
      outcome
        == .written(
          path: ".harness/design-render/offline-order-queue.html", designSha: sha,
          capabilities: "{\"comments\":{},\"db\":{}}", notes: []))
    #expect(DesignRenderRun.exitCode(outcome) == 0)
    let html = try String(contentsOf: repository.outputURL, encoding: .utf8)
    #expect(html.contains("data-design-sha=\"\(sha)\""))
    // The cited .build checkout doesn't exist in the temp repo, so the check fails the quote.
    #expect(html.contains("class=\"badge\" data-status=\"quote-fail\""))
  }

  @Test(
    "a lint-failing doc exits 1 and writes no HTML — catches an unlinted design reaching approval")
  func refusesLintFailure() async throws {
    let broken = try Self.validDoc().replacingOccurrences(of: "## Problem", with: "## Problems")
    let repository = try Repository(doc: broken, claims: try Self.validClaims())
    defer { repository.remove() }
    let outcome = await repository.run()
    guard case .lintFailed(let findings) = outcome else {
      Issue.record("expected lintFailed, got \(outcome)")
      return
    }
    #expect(findings.contains { $0.ruleID == "design-lint.section-missing" })
    #expect(DesignRenderRun.exitCode(outcome) == 1)
    #expect(!FileManager.default.fileExists(atPath: repository.outputURL.path))
  }

  @Test(
    "a malformed claims file blocks with exit 2 and writes no HTML — catches badges drawn from evidence that couldn't be read"
  )
  func blocksOnUnreadableEvidence() async throws {
    let claims = try Self.validClaims() + "{not json\n"
    let repository = try Repository(doc: try Self.validDoc(), claims: claims)
    defer { repository.remove() }
    let outcome = await repository.run()
    guard case .blocked(let message) = outcome else {
      Issue.record("expected blocked, got \(outcome)")
      return
    }
    #expect(message.contains("claims.jsonl:2"))
    #expect(DesignRenderRun.exitCode(outcome) == 2)
    #expect(!FileManager.default.fileExists(atPath: repository.outputURL.path))
  }
}
