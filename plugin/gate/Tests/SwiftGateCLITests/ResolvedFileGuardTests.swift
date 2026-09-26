import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

@Suite("resolved-file guard")
struct ResolvedFileGuardTests {
  @Test(
    "an unchanged snapshot has no finding — catches a healthy run flagged as if it rewrote the lockfile"
  )
  func unchanged() throws {
    let before = ["Package.resolved": "abc"]

    let finding = try ResolvedFileGuard.finding(before: before, after: before)

    #expect(finding == nil)
  }

  @Test(
    "a rewritten Package.resolved is a major, gate-failing finding naming the path — catches SwiftPM's silent rewrite reported GREEN"
  )
  func rewritten() throws {
    let before = ["Package.resolved": "abc"]
    let after = ["Package.resolved": "def"]

    let finding = try #require(try ResolvedFileGuard.finding(before: before, after: after))

    #expect(finding.ruleID == ResolvedFileGuard.rewrittenRuleID)
    #expect(finding.severity == .major)
    #expect(finding.severity.failsGate)
    #expect(finding.file == "Package.resolved")
    #expect(finding.message.contains("Package.resolved"))
  }

  @Test(
    "a Package.resolved the run deleted is also flagged — catches a rewrite-to-nothing missed by an equality check on present keys only"
  )
  func deleted() throws {
    let before = ["Package.resolved": "abc"]
    let after: [String: String] = [:]

    let finding = try #require(try ResolvedFileGuard.finding(before: before, after: after))

    #expect(finding.ruleID == ResolvedFileGuard.rewrittenRuleID)
  }

  @Test(
    "a snapshot before git can answer is empty, not thrown — catches a broken snapshot blocking every run instead of just skipping its backstop"
  )
  func snapshotToleratesGitFailure() async {
    let git = FakeGit(failure: .invalidRef(""))

    let snapshot = await ResolvedFileGuard.snapshot(git: git)

    #expect(snapshot.isEmpty)
  }
}
