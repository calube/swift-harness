import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

/// `hashes.txt` is `git hash-object --no-filters` output captured in a temp repo (recipe in
/// `gate/Tests/Fixtures/README.md`): `<sha> <file>` per line.
private enum CapturedHashes {
  static func load() throws -> [String: String] {
    let text = try Fixture.text("DesignSha/hashes.txt")
    var hashes: [String: String] = [:]
    for line in text.split(separator: "\n") {
      let parts = line.split(separator: " ", maxSplits: 1)
      hashes[String(parts[1])] = String(parts[0])
    }
    return hashes
  }

  /// Fixture bytes as UTF-8 text; a fixture that isn't valid UTF-8 fails the test loudly.
  static func text(_ name: String) throws -> String {
    let data = try Fixture.data("DesignSha/\(name)")
    return try #require(String(data: data, encoding: .utf8), "\(name) is not UTF-8")
  }
}

@Suite("designSha")
struct DesignShaTests {
  static let variants = ["lf", "crlf", "no-trailing-newline", "non-ascii", "fenced-status-edited"]

  @Test(
    "designSha equals the captured git hash-object of the hand-stripped doc — catches a sha no committed revision can match",
    arguments: variants)
  func matchesCapturedHash(variant: String) throws {
    let hashes = try CapturedHashes.load()
    let doc = try CapturedHashes.text("\(variant)-approved.md")
    let expected = try #require(hashes["\(variant).stripped.md"])
    #expect(DesignSha.of(doc) == expected)
    #expect(DesignSha.strippingStatus(doc) == (try CapturedHashes.text("\(variant).stripped.md")))
  }

  @Test(
    "the blob id of a whole fixture equals git's — catches a read or hash path that alters CRLF, a missing final newline or non-ASCII bytes",
    arguments: variants)
  func rawBlobMatchesGit(variant: String) throws {
    let hashes = try CapturedHashes.load()
    let name = "\(variant)-approved.md"
    #expect(GitBlobID.of(try CapturedHashes.text(name)) == hashes[name])
  }

  @Test("a status transition keeps the designSha — catches an approval lost when the doc merges")
  func statusChangeKeepsSha() throws {
    let hashes = try CapturedHashes.load()
    let approved = try CapturedHashes.text("lf-approved.md")
    let proposed = try CapturedHashes.text("lf-proposed.md")
    #expect(hashes["lf-approved.md"] != hashes["lf-proposed.md"])
    #expect(DesignSha.of(approved) == DesignSha.of(proposed))
    #expect(DesignSha.of(proposed) == hashes["lf.stripped.md"])
  }

  @Test(
    "a status: line in a fenced block of the body is hashed — catches body content escaping the approval"
  )
  func fencedBodyStatusIsHashed() throws {
    let base = try CapturedHashes.text("lf-approved.md")
    let edited = try CapturedHashes.text("fenced-status-edited-approved.md")
    #expect(DesignSha.strippingStatus(edited).contains("```yaml\nstatus: approved\n"))
    #expect(DesignSha.of(base) != DesignSha.of(edited))
  }

  @Test(
    "docs that differ outside the frontmatter status never share a designSha — catches stripping that swallows real content"
  )
  func strippingNeverCollides() throws {
    let base = try CapturedHashes.text("lf-approved.md")
    let variants = [
      base.replacingOccurrences(of: "area: ordering", with: "area: payments"),
      base.replacingOccurrences(of: "tier: standard\n", with: "tier: standard\nowner: kitchen\n"),
      base.replacingOccurrences(of: "## Problem\n", with: "## Problem\nstatus: approved\n"),
      base.replacingOccurrences(of: "status: approved\n", with: "status: approved\n  status: x\n"),
      base.replacingOccurrences(of: "lost", with: "dropped"),
      base + "\n",
      String(base.dropLast()),
      base.replacingOccurrences(of: "\n", with: "\r\n"),
    ]
    var seen = [DesignSha.of(base)]
    for variant in variants {
      let sha = DesignSha.of(variant)
      #expect(!seen.contains(sha), "collision for variant: \(variant.prefix(80))")
      seen.append(sha)
    }
  }

  @Test(
    "a doc without closed frontmatter keeps a leading status: line — catches a body line stripped as if it were frontmatter"
  )
  func unclosedFrontmatterStripsNothing() {
    let noFrontmatter = "status: approved\n# Title\n"
    let unclosed = "---\nstatus: approved\n# Title\n"
    #expect(DesignSha.strippingStatus(noFrontmatter) == noFrontmatter)
    #expect(DesignSha.strippingStatus(unclosed) == unclosed)
    #expect(DesignSha.of(unclosed) != DesignSha.of("---\nstatus: proposed\n# Title\n"))
  }
}

/// A small but complete design doc; each test edits one part of it.
private enum Doc {
  static let base = """
    ---
    status: approved
    area: ordering
    tier: standard
    ---
    # Offline order queue

    ## Problem

    Orders placed offline are lost when the app is killed.

    ## Requirements

    - req-offline-orders-survive-app-kill: a queued order is still queued after relaunch
    - req-queue-drains-on-reconnect: the queue drains once the network returns

    ## Decision

    Persist the queue with a file-backed store.

    ### Rationale

    A file survives process death.

    ## Module kinds

    | Module | Kind |
    |---|---|
    | OrderQueueCore | core |

    ## Test plan by tier

    - test-queued-order-survives-relaunch: relaunch keeps the order — tier T1

    ## Risks

    Disk full.

    """

  static func editing(_ target: String, _ replacement: String) -> String {
    precondition(base.contains(target), "fixture edit target missing: \(target)")
    return base.replacingOccurrences(of: target, with: replacement)
  }
}

@Suite("design-diff classification")
struct DesignDiffClassificationTests {
  @Test("a req- line edit is amend and names the id — catches an amend posing as clarify")
  func requirementEditIsAmend() {
    let new = Doc.editing("still queued after relaunch", "still queued after two relaunches")
    let diff = DesignDiff.compare(old: Doc.base, new: new)
    #expect(diff.changeClass == .amend)
    #expect(diff.triggers == [.requirementLine])
    #expect(diff.changedIds == ["req-offline-orders-survive-app-kill"])
  }

  @Test(
    "a typo fix in Problem is clarify with no ids — catches every edit being forced to re-approval")
  func problemTypoIsClarify() {
    let new = Doc.editing("Orders placed", "Orders placd")
    let diff = DesignDiff.compare(old: Doc.base, new: new)
    #expect(diff.changeClass == .clarify)
    #expect(diff.triggers.isEmpty)
    #expect(diff.changedIds.isEmpty)
    #expect(diff.oldSha != diff.newSha)
  }

  @Test(
    "an edit to Decision, its subsections, Module kinds or the Test plan is amend — catches a protected section edited as clarify",
    arguments: [
      ("file-backed store", "SQLite store", DesignDiff.Trigger.decision, [String]()),
      ("A file survives process death.", "A file usually survives.", .decision, []),
      ("| OrderQueueCore | core |", "| OrderQueueCore | live |", .moduleKinds, []),
      (
        "relaunch keeps the order — tier T1", "relaunch keeps the order — tier T2", .testPlan,
        ["test-queued-order-survives-relaunch"]
      ),
    ])
  func protectedSectionEditIsAmend(
    target: String, replacement: String, trigger: DesignDiff.Trigger, ids: [String]
  ) {
    let diff = DesignDiff.compare(old: Doc.base, new: Doc.editing(target, replacement))
    #expect(diff.changeClass == .amend)
    #expect(diff.triggers == [trigger])
    #expect(diff.changedIds == ids)
  }

  @Test("renaming the Decision heading is amend — catches a protected section escaping by rename")
  func decisionRenameIsAmend() {
    let diff = DesignDiff.compare(
      old: Doc.base, new: Doc.editing("## Decision\n", "## Choice\n"))
    #expect(diff.changeClass == .amend)
    #expect(diff.triggers.contains(.decision))
  }

  @Test(
    "a req- bullet moved out of Requirements is still amend — catches a requirement dropped by relocation"
  )
  func requirementRemovedIsAmend() {
    let line = "- req-queue-drains-on-reconnect: the queue drains once the network returns\n"
    let diff = DesignDiff.compare(old: Doc.base, new: Doc.editing(line, ""))
    #expect(diff.changeClass == .amend)
    #expect(diff.changedIds == ["req-queue-drains-on-reconnect"])
  }

  @Test(
    "a req- bullet moved unchanged from Requirements into Risks is amend naming the id — catches a requirement dropped by relocation posing as clarify"
  )
  func requirementRelocatedOutOfRequirementsIsAmend() {
    let line = "- req-queue-drains-on-reconnect: the queue drains once the network returns\n"
    let moved = Doc.editing(line, "").replacingOccurrences(
      of: "Disk full.\n", with: "Disk full.\n\n\(line)")
    let diff = DesignDiff.compare(old: Doc.base, new: moved)
    #expect(diff.changeClass == .amend)
    #expect(diff.triggers == [.requirementLine])
    #expect(diff.changedIds == ["req-queue-drains-on-reconnect"])
  }

  static let changelogBase =
    Doc.base + "\n## Changelog\n\n- 2026-09-25: drafted\n- 2026-09-26: clarified Risks\n"

  @Test(
    "editing or removing an existing Changelog entry is amend while a pure append stays clarify — catches history rewritten under a clarify",
    arguments: [
      ("- 2026-09-25: drafted\n", "- 2026-09-25: drafted and approved\n"),
      ("- 2026-09-26: clarified Risks\n", ""),
    ])
  func changelogRewriteIsAmend(target: String, replacement: String) {
    let new = Self.changelogBase.replacingOccurrences(of: target, with: replacement)
    let diff = DesignDiff.compare(old: Self.changelogBase, new: new)
    #expect(diff.changeClass == .amend)
    #expect(diff.triggers.map(\.rawValue) == ["changelog"])

    let append = DesignDiff.compare(
      old: Self.changelogBase, new: Self.changelogBase + "- 2026-09-27: clarified Problem\n")
    #expect(append.changeClass == .clarify)
    #expect(append.triggers.isEmpty)
  }

  @Test("a status-only edit is unchanged with equal shas — catches a status flip read as an edit")
  func statusOnlyIsUnchanged() {
    let diff = DesignDiff.compare(
      old: Doc.base, new: Doc.editing("status: approved", "status: built"))
    #expect(diff.changeClass == .unchanged)
    #expect(diff.oldSha == diff.newSha)
  }

  @Test(
    "converting line endings to CRLF is clarify with nothing protected — catches an editor's line endings forcing re-approval"
  )
  func lineEndingsOnlyIsClarify() {
    let crlf = Doc.base.replacingOccurrences(of: "\n", with: "\r\n")
    let diff = DesignDiff.compare(old: Doc.base, new: crlf)
    #expect(diff.changeClass == .clarify)
    #expect(diff.triggers.isEmpty)
  }

  @Test(
    "a heading inside a fence doesn't end the Decision section — catches Decision content hidden behind a fenced heading"
  )
  func fencedHeadingDoesNotSplitSection() {
    let old = Doc.editing(
      "Persist the queue with a file-backed store.\n",
      "Persist the queue with a file-backed store.\n\n```text\n## Risks\n```\n\nBatch size 20.\n")
    let new = old.replacingOccurrences(of: "Batch size 20.", with: "Batch size 50.")
    #expect(DesignDiff.compare(old: old, new: new).triggers == [.decision])
  }

  @Test("the change class is a closed set — catches a new class slipping past consumers")
  func classIsClosed() throws {
    #expect(DesignDiff.Class.allCases.map(\.rawValue) == ["unchanged", "clarify", "amend"])
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(DesignDiff.Class.self, from: Data("\"minor\"".utf8))
    }
  }
}

@Suite("clarify chain")
struct ClarifyChainTests {
  static let approved = Doc.base
  static let clarified = Doc.editing("Disk full.", "Disk full or quota exceeded.")
  static let clarifiedAgain = clarified.replacingOccurrences(of: "Orders placed", with: "Orders")
  static let amended = clarified.replacingOccurrences(
    of: "file-backed store", with: "SQLite store")

  static var history: [String: String] {
    Dictionary(
      [approved, clarified, clarifiedAgain, amended].map { (DesignSha.of($0), $0) },
      uniquingKeysWith: { first, _ in first })
  }

  static func link(_ from: String, _ to: String) -> ClarifyChain.Link {
    ClarifyChain.Link(fromSha: DesignSha.of(from), toSha: DesignSha.of(to))
  }

  @Test(
    "a chain whose every link is clarify is valid and ends at the last sha — catches a good chain rejected"
  )
  func validChain() {
    let result = ClarifyChain.verify(
      approvedSha: DesignSha.of(Self.approved),
      links: [
        Self.link(Self.approved, Self.clarified), Self.link(Self.clarified, Self.clarifiedAgain),
      ],
      revisions: Self.history)
    #expect(result == .valid(endSha: DesignSha.of(Self.clarifiedAgain)))
  }

  @Test("an empty chain ends at the approved sha — catches an empty chain read as broken")
  func emptyChain() {
    let sha = DesignSha.of(Self.approved)
    #expect(
      ClarifyChain.verify(approvedSha: sha, links: [], revisions: Self.history)
        == .valid(endSha: sha))
  }

  @Test(
    "a forged middle link to a sha no revision has is rejected, naming that link — catches approval carried to unreviewed content"
  )
  func forgedMiddleLink() throws {
    let forged = String(repeating: "f", count: 40)
    let result = ClarifyChain.verify(
      approvedSha: DesignSha.of(Self.approved),
      links: [
        Self.link(Self.approved, Self.clarified),
        ClarifyChain.Link(fromSha: DesignSha.of(Self.clarified), toSha: forged),
        ClarifyChain.Link(fromSha: forged, toSha: DesignSha.of(Self.clarifiedAgain)),
      ],
      revisions: Self.history)
    guard case .broken(let broken) = result else {
      Issue.record("expected a broken chain, got \(result)")
      return
    }
    #expect(broken.index == 1)
    #expect(broken.problem == .unknownToSha)
    #expect(broken.message.contains("link 1"))
    #expect(broken.message.contains(forged))
  }

  @Test(
    "a clarify link that hides an amend is rejected with its triggers — catches an amend laundered through the chain"
  )
  func hiddenAmendLink() {
    let result = ClarifyChain.verify(
      approvedSha: DesignSha.of(Self.approved),
      links: [Self.link(Self.approved, Self.clarified), Self.link(Self.clarified, Self.amended)],
      revisions: Self.history)
    guard case .broken(let broken) = result else {
      Issue.record("expected a broken chain, got \(result)")
      return
    }
    #expect(broken.index == 1)
    guard case .amend(let diff) = broken.problem else {
      Issue.record("expected an amend problem, got \(broken.problem)")
      return
    }
    #expect(diff.triggers == [.decision])
    #expect(broken.message.contains("decision"))
  }

  @Test(
    "a link that doesn't start where the previous one ended is rejected — catches a chain spliced from another approval"
  )
  func discontinuousLink() {
    let result = ClarifyChain.verify(
      approvedSha: DesignSha.of(Self.approved),
      links: [Self.link(Self.clarified, Self.clarifiedAgain)],
      revisions: Self.history)
    guard case .broken(let broken) = result else {
      Issue.record("expected a broken chain, got \(result)")
      return
    }
    #expect(broken.index == 0)
    #expect(broken.problem == .discontinuous(expectedFromSha: DesignSha.of(Self.approved)))
  }

  @Test("a link that changes nothing is rejected — catches a no-op link padding the chain")
  func noChangeLink() {
    let sha = DesignSha.of(Self.approved)
    let result = ClarifyChain.verify(
      approvedSha: sha, links: [ClarifyChain.Link(fromSha: sha, toSha: sha)],
      revisions: Self.history)
    guard case .broken(let broken) = result else {
      Issue.record("expected a broken chain, got \(result)")
      return
    }
    #expect(broken.problem == .noChange)
  }
}
