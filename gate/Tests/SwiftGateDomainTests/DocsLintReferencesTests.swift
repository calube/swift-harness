import Foundation
import SwiftGateDomain
import Testing

@Suite("Docs lint — reference integrity, relative links, router reachability")
struct DocsLintReferencesTests {
  static func file(_ path: String, _ text: String) -> DocsLintReferences.DocFile {
    DocsLintReferences.DocFile(path: path, rawText: text, markdown: .parse(text))
  }

  /// `repoPaths` defaults to exactly the given files' own paths — every fixture doc counts as a
  /// tracked file unless a test names a different set (to add non-doc tracked files, or to test a
  /// file the corpus mentions but doesn't itself carry).
  static func check(
    _ files: [DocsLintReferences.DocFile], claims: [Claim] = [], repoPaths: Set<String>? = nil
  ) throws -> [Finding] {
    try DocsLintReferences.check(
      files: files, claims: claims, repoPaths: repoPaths ?? Set(files.map { $0.path }))
  }

  static func claim(_ id: String) -> Claim {
    Claim(
      id: id, lane: "test-lane", text: "some evidence",
      citation: Citation(kind: .file, loc: "docs/example.md#L1-L1", pin: "abc123", quote: "text"),
      status: .new)
  }

  // MARK: - Reference integrity: dangling ids

  @Test("a dangling ev- id is flagged — catches a claim tag with no matching claim")
  func danglingEvIDIsFlagged() throws {
    let doc = Self.file(
      "docs/designs/x.md",
      """
      ## Evidence

      - Evidence: something is true [ev-nothing-backs-this]
      """)
    let findings = try Self.check([doc], claims: [])
    #expect(findings.contains { $0.ruleID == "docs-lint.dangling-id" && $0.file == doc.path })
  }

  @Test(
    "an ev- id defined in a claims input is not dangling — catches the check reading claims.jsonl instead of the doc"
  )
  func evIDBackedByAClaimIsNotDangling() throws {
    let doc = Self.file(
      "docs/designs/x.md",
      """
      ## Evidence

      - Evidence: something is true [ev-backed-by-a-claim]
      """)
    let findings = try Self.check([doc], claims: [Self.claim("ev-backed-by-a-claim")])
    #expect(findings.filter { $0.ruleID == "docs-lint.dangling-id" } == [])
  }

  @Test("a dangling req- id is flagged — catches a citation of a requirement nobody defined")
  func danglingRequirementIDIsFlagged() throws {
    let doc = Self.file(
      "docs/designs/x.md",
      """
      ## Covers

      Also touches req-never-defined-anywhere.
      """)
    let findings = try Self.check([doc])
    #expect(findings.contains { $0.ruleID == "docs-lint.dangling-id" })
  }

  @Test("a req- id defined by a bullet elsewhere in the corpus is not dangling")
  func requirementDefinedElsewhereIsNotDangling() throws {
    let defining = Self.file(
      "docs/designs/a.md",
      """
      ## Requirements

      - req-offline-queue-drains: the queue drains on reconnect.
      """)
    let citing = Self.file(
      "docs/plans/b.md",
      """
      ## Coverage

      Covers req-offline-queue-drains.
      """)
    let findings = try Self.check([defining, citing])
    #expect(findings.filter { $0.ruleID == "docs-lint.dangling-id" } == [])
  }

  // MARK: - Reference integrity: bare ADR mentions

  @Test("a bare ADR NNNN mention is flagged — catches an ADR referenced without a link")
  func bareADRMentionIsFlagged() throws {
    let doc = Self.file(
      "docs/index.md",
      """
      ## Status

      See ADR 0004 for the reasoning.
      """)
    let findings = try Self.check([doc])
    #expect(findings.contains { $0.ruleID == "docs-lint.bare-adr-reference" })
  }

  @Test("a linked ADR NNNN mention is not flagged")
  func linkedADRMentionIsNotFlagged() throws {
    let doc = Self.file(
      "docs/index.md",
      """
      ## Status

      See [ADR 0004](adrs/0004-some-decision.md) for the reasoning.
      """)
    let adr = Self.file("docs/adrs/0004-some-decision.md", "# 0004. Some decision\n")
    let findings = try Self.check([doc, adr])
    #expect(findings.filter { $0.ruleID == "docs-lint.bare-adr-reference" } == [])
  }

  // MARK: - Reference integrity: requirement cited nowhere else

  @Test(
    "a requirement cited only inside its own defining design is flagged — catches a requirement no plan or design ever covers"
  )
  func requirementCitedOnlyInItsOwnDesignIsFlagged() throws {
    let design = Self.file(
      "docs/designs/a.md",
      """
      ## Requirements

      - req-only-mentioned-here: the thing must happen.

      ## Notes

      req-only-mentioned-here again, still the same doc.
      """)
    let findings = try Self.check([design])
    let uncited = findings.filter { $0.ruleID == "docs-lint.requirement-uncited" }
    #expect(uncited.count == 1)
    #expect(uncited.first?.file == design.path)
  }

  @Test("a requirement cited in another doc is not flagged")
  func requirementCitedElsewhereIsNotFlagged() throws {
    let design = Self.file(
      "docs/designs/a.md",
      """
      ## Requirements

      - req-covered-by-the-plan: the thing must happen.
      """)
    let plan = Self.file(
      "docs/plans/a-plan.md",
      """
      ## Coverage

      covers: req-covered-by-the-plan
      """)
    let findings = try Self.check([design, plan])
    #expect(findings.filter { $0.ruleID == "docs-lint.requirement-uncited" } == [])
  }

  // MARK: - Relative links: the risky part

  @Test("a link climbing out of a subdir with ../ resolves against the corpus")
  func relativeLinkClimbsOutOfSubdirCorrectly() throws {
    let handoff = Self.file(
      "docs/handoffs/note.md",
      """
      See [the design](../designs/target.md).
      """)
    let target = Self.file("docs/designs/target.md", "# Target\n")
    let findings = try Self.check([handoff, target])
    #expect(findings.filter { $0.ruleID == "docs-lint.broken-relative-link" } == [])
  }

  @Test(
    "a repo-root-absolute link (leading /) resolves from the repo root, not the doc's directory"
  )
  func repoRootAbsoluteLinkResolvesFromRoot() throws {
    let handoff = Self.file(
      "docs/handoffs/note.md",
      """
      See [the target](/docs/designs/target.md).
      """)
    let target = Self.file("docs/designs/target.md", "# Target\n")
    let findings = try Self.check([handoff, target])
    #expect(findings.filter { $0.ruleID == "docs-lint.broken-relative-link" } == [])
  }

  @Test(
    "a link with a #anchor resolves when the file exists, and the anchor itself is never checked"
  )
  func linkWithAnchorChecksOnlyTheFile() throws {
    let doc = Self.file(
      "docs/index.md",
      """
      See [standards](standards.md#a-heading-that-does-not-exist).
      """)
    let target = Self.file("docs/standards.md", "# Standards\n\nNo such heading here.\n")
    let findings = try Self.check([doc, target])
    // The file resolves; a nonexistent #anchor never produces a finding — the documented scope.
    #expect(findings.filter { $0.ruleID == "docs-lint.broken-relative-link" } == [])
  }

  @Test("a URL-encoded space in a link destination decodes before resolution")
  func percentEncodedSpaceDecodesBeforeResolving() throws {
    let doc = Self.file(
      "docs/index.md",
      """
      See [notes](handoffs/My%20Notes.md).
      """)
    let target = Self.file("docs/handoffs/My Notes.md", "# My Notes\n")
    let findings = try Self.check([doc, target])
    #expect(findings.filter { $0.ruleID == "docs-lint.broken-relative-link" } == [])
  }

  @Test("an absolute https:// link is ignored, even when it would never resolve")
  func absoluteHTTPSLinkIsIgnored() throws {
    let doc = Self.file(
      "docs/index.md",
      """
      See [external](https://example.com/nonexistent.md).
      """)
    let findings = try Self.check([doc])
    #expect(findings.filter { $0.ruleID == "docs-lint.broken-relative-link" } == [])
  }

  @Test("a mailto: link is ignored")
  func mailtoLinkIsIgnored() throws {
    let doc = Self.file(
      "docs/index.md",
      """
      Contact [us](mailto:team@example.com).
      """)
    let findings = try Self.check([doc])
    #expect(findings.filter { $0.ruleID == "docs-lint.broken-relative-link" } == [])
  }

  @Test("a link inside a fenced code block is ignored")
  func linkInsideFenceIsIgnored() throws {
    let doc = Self.file(
      "docs/index.md",
      """
      ```markdown
      [broken](does-not-exist.md)
      ```
      """)
    let findings = try Self.check([doc])
    #expect(findings.filter { $0.ruleID == "docs-lint.broken-relative-link" } == [])
  }

  @Test("a link inside inline code is ignored")
  func linkInsideInlineCodeIsIgnored() throws {
    let doc = Self.file(
      "docs/index.md",
      """
      Write it as `[broken](does-not-exist.md)` in the doc.
      """)
    let findings = try Self.check([doc])
    #expect(findings.filter { $0.ruleID == "docs-lint.broken-relative-link" } == [])
  }

  @Test(
    "a link that climbs above the repo root is flagged and never resolved outside the corpus"
  )
  func linkClimbingAboveRepoRootIsFlagged() throws {
    let doc = Self.file(
      "docs/index.md",
      """
      See [escape](../../outside.md).
      """)
    let findings = try Self.check([doc])
    let broken = findings.filter { $0.ruleID == "docs-lint.broken-relative-link" }
    #expect(broken.count == 1)
    #expect(broken.first?.message.contains("climbs above the repo root") == true)
  }

  @Test("a relative link to a file missing from the corpus is flagged")
  func brokenRelativeLinkIsFlagged() throws {
    let doc = Self.file(
      "docs/index.md",
      """
      See [missing](designs/does-not-exist.md).
      """)
    let findings = try Self.check([doc])
    #expect(findings.contains { $0.ruleID == "docs-lint.broken-relative-link" })
  }

  // MARK: - Relative links: every extension, resolved against every tracked file

  @Test("a relative link to an untracked source file is flagged")
  func brokenSourceFileLinkIsFlagged() throws {
    let doc = Self.file(
      "docs/handoffs/note.md",
      """
      See [the rule](../../gate/Sources/SwiftGateDomain/Docs/Missing.swift).
      """)
    let findings = try Self.check(
      [doc], repoPaths: ["gate/Sources/SwiftGateDomain/Docs/DocsLintReferences.swift"])
    #expect(findings.contains { $0.ruleID == "docs-lint.broken-relative-link" })
  }

  @Test("a relative link to a tracked source file passes")
  func validSourceFileLinkPasses() throws {
    let doc = Self.file(
      "docs/handoffs/note.md",
      """
      See [the rule](../../gate/Sources/SwiftGateDomain/Docs/DocsLintReferences.swift).
      """)
    let findings = try Self.check(
      [doc], repoPaths: ["gate/Sources/SwiftGateDomain/Docs/DocsLintReferences.swift"])
    #expect(findings.filter { $0.ruleID == "docs-lint.broken-relative-link" } == [])
  }

  @Test("a relative link to a tracked directory (trailing /) passes")
  func validDirectoryLinkPasses() throws {
    let doc = Self.file(
      "docs/designs/x.md",
      """
      See [the ADRs](../adrs/).
      """)
    let findings = try Self.check(
      [doc], repoPaths: ["docs/adrs/0001-something.md", "docs/designs/x.md"])
    #expect(findings.filter { $0.ruleID == "docs-lint.broken-relative-link" } == [])
  }

  @Test("a relative link to an untracked directory is flagged")
  func missingDirectoryLinkIsFlagged() throws {
    let doc = Self.file(
      "docs/designs/x.md",
      """
      See [nothing here](../nonexistent-dir/).
      """)
    let findings = try Self.check([doc], repoPaths: ["docs/designs/x.md"])
    #expect(findings.contains { $0.ruleID == "docs-lint.broken-relative-link" })
  }

  @Test("an image link resolves when the image is tracked and is flagged when it isn't")
  func imageLinkBothWays() throws {
    let doc = Self.file(
      "docs/index.md",
      """
      ![valid](img/x.png)
      ![broken](img/missing.png)
      """)
    let findings = try Self.check([doc], repoPaths: ["docs/img/x.png"])
    let broken = findings.filter { $0.ruleID == "docs-lint.broken-relative-link" }
    #expect(broken.count == 1)
    #expect(broken.first?.message.contains("docs/img/missing.png") == true)
  }

  @Test(
    "a link whose path is only a string prefix of a tracked file's name, not its directory, is flagged"
  )
  func pathThatOnlyPrefixesAFileNameIsFlagged() throws {
    let doc = Self.file(
      "docs/handoffs/note.md",
      """
      See [not a directory](../../gate/Sour).
      """)
    let findings = try Self.check(
      [doc], repoPaths: ["gate/Sources/SwiftGateDomain/Docs/DocsLintReferences.swift"])
    #expect(findings.contains { $0.ruleID == "docs-lint.broken-relative-link" })
  }

  // MARK: - Router reachability

  @Test("every doc reachable from docs/index.md is not flagged, including through a cycle")
  func reachableDocsIncludingACycleAreNotFlagged() throws {
    let index = Self.file(
      "docs/index.md",
      """
      See [a](a.md).
      """)
    // a.md and b.md link to each other — a cycle. Both are still reachable through `a`, and the
    // walk must terminate rather than loop forever chasing the cycle.
    let a = Self.file(
      "docs/a.md",
      """
      See [b](b.md).
      """)
    let b = Self.file(
      "docs/b.md",
      """
      See [a](a.md).
      """)
    let findings = try Self.check([index, a, b])
    #expect(findings.filter { $0.ruleID == "docs-lint.unreachable-doc" } == [])
  }

  @Test(
    "an orphan pair that only link to each other is flagged, both docs, even though neither is unreachable from the other"
  )
  func orphanPairLinkingOnlyToEachOtherIsFlagged() throws {
    let index = Self.file(
      "docs/index.md",
      """
      No links out of here.
      """)
    let orphanA = Self.file(
      "docs/orphan-a.md",
      """
      See [b](orphan-b.md).
      """)
    let orphanB = Self.file(
      "docs/orphan-b.md",
      """
      See [a](orphan-a.md).
      """)
    let findings = try Self.check([index, orphanA, orphanB])
    let unreachable = Set(
      findings.filter { $0.ruleID == "docs-lint.unreachable-doc" }.map { $0.file })
    #expect(unreachable == ["docs/orphan-a.md", "docs/orphan-b.md"])
  }

  // MARK: - Findings name a real line

  @Test("a dangling id finding names the line it's first mentioned on")
  func danglingIDFindingNamesItsLine() throws {
    let doc = Self.file(
      "docs/designs/x.md",
      """
      ## Evidence

      - Evidence: something is true [ev-nothing-backs-this]
      """)
    let findings = try Self.check([doc], claims: [])
    let finding = try #require(findings.first { $0.ruleID == "docs-lint.dangling-id" })
    #expect(finding.line == 3)
  }

  @Test("a bare ADR mention finding names the line it appears on")
  func bareADRMentionFindingNamesItsLine() throws {
    let doc = Self.file(
      "docs/index.md",
      """
      ## Status

      See ADR 0004 for the reasoning.
      """)
    let findings = try Self.check([doc])
    let finding = try #require(findings.first { $0.ruleID == "docs-lint.bare-adr-reference" })
    #expect(finding.line == 3)
  }

  @Test("a requirement-uncited finding names the line where the requirement is defined")
  func requirementUncitedFindingNamesItsLine() throws {
    let design = Self.file(
      "docs/designs/a.md",
      """
      ## Requirements

      - req-only-mentioned-here: the thing must happen.
      """)
    let findings = try Self.check([design])
    let finding = try #require(findings.first { $0.ruleID == "docs-lint.requirement-uncited" })
    #expect(finding.line == 3)
  }

  @Test("a broken relative link finding names the line the link appears on")
  func brokenRelativeLinkFindingNamesItsLine() throws {
    let doc = Self.file(
      "docs/index.md",
      """
      Intro line.

      See [missing](designs/does-not-exist.md).
      """)
    let findings = try Self.check([doc])
    let finding = try #require(findings.first { $0.ruleID == "docs-lint.broken-relative-link" })
    #expect(finding.line == 3)
  }

  @Test(
    "a broken relative link after a fenced code block still names the right line — catches the scan dropping fenced lines instead of blanking them"
  )
  func brokenRelativeLinkAfterAFenceNamesTheRightLine() throws {
    let doc = Self.file(
      "docs/index.md",
      """
      ```swift
      let x = 1
      ```

      See [missing](designs/does-not-exist.md).
      """)
    let findings = try Self.check([doc])
    let finding = try #require(findings.first { $0.ruleID == "docs-lint.broken-relative-link" })
    #expect(finding.line == 5)
  }
}
