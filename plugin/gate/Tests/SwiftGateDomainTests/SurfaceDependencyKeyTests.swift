import SwiftGateDomain
import Testing

@Suite("surface-check dependency key findings")
struct SurfaceDependencyKeyTests {
  @Test(
    "a wired accessor on an undeclared key names the key and where it must be declared — catches a finding that tells the author to stub an accessor whose only fault is its key"
  )
  func undeclaredKeyNamesTheKey() throws {
    let surface = SurfaceCommit(commit: "c", parent: "p", changes: [], otherPaths: [])
    let findings = try SurfaceCheck.findings(
      surface,
      judgements: [
        SurfaceJudgement(
          file: "Sources/App/Dependencies.swift", line: 4,
          declaration: "DependencyValues.feedClient.get",
          outcome: .behaviour(.undeclaredDependencyKey(key: "FeedClient")))
      ])

    #expect(findings.map(\.ruleID) == [SurfaceCheck.behaviourRuleID, SurfaceCheck.summaryRuleID])
    #expect(
      findings.first?.message
        == "`DependencyValues.feedClient.get` keys on `FeedClient`, which neither the commit nor "
        + "its parent declares: a wired accessor reads and writes the slot of a key type the "
        + "surface or the code before it declares")
  }
}
