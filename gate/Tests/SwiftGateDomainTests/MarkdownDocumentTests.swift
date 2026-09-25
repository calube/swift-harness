import Foundation
import SwiftGateDomain
import Testing

@Suite("Markdown document")
struct MarkdownDocumentTests {
  static let fixturesRoot = URL(filePath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "Fixtures/design", directoryHint: .isDirectory)

  static func loadValidFixture() throws -> String {
    try String(contentsOf: fixturesRoot.appending(path: "valid.md"), encoding: .utf8)
  }

  @Test(
    "a section is found by its GitHub-style anchor — catches slug drift breaking every named lookup"
  )
  func sectionByAnchor() throws {
    let text = try Self.loadValidFixture()
    let document = MarkdownDocument.parse(text)
    let problem = try #require(document.section(anchor: "problem"))
    #expect(problem.heading == "Problem")
    let perfAndScale = try #require(document.section(anchor: "perf--scale"))
    #expect(perfAndScale.heading == "Perf & scale")
    #expect(document.section(anchor: "not-a-real-section") == nil)
  }

  @Test(
    "mermaid fence reports its diagram type — catches design-lint losing flowchart vs sequenceDiagram"
  )
  func mermaidDiagramTypeDetected() throws {
    let text = try Self.loadValidFixture()
    let architecture = try #require(MarkdownDocument.parse(text).section(anchor: "architecture"))
    let mermaidFences = architecture.fences.filter { $0.language == "mermaid" }
    #expect(mermaidFences.count == 2)
    #expect(mermaidFences.map(\.mermaidDiagramType) == ["flowchart", "sequenceDiagram"])
  }

  @Test(
    "prose word count skips tables, code and diagrams — catches a budget charging diagram syntax as prose"
  )
  func proseWordCountSkipsNonProse() throws {
    let text = """
      ## Module kinds

      Two words here.

      | Module | Kind |
      |---|---|
      | Foo | core |

      ```mermaid
      flowchart TD
        A --> B --> C --> D --> E
      ```
      """
    let section = try #require(MarkdownDocument.parse(text).section(anchor: "module-kinds"))
    #expect(section.proseWordCount == 3)
    #expect(section.tables.count == 1)
    #expect(section.fences.count == 1)
  }

  @Test(
    "a '#' inside a fenced block is not read as a heading — catches shell comments splitting a section"
  )
  func hashInsideFenceIsNotAHeading() throws {
    let text = """
      ## Observability

      ```bash
      # this looks like a heading but is fenced code
      echo hi
      ```

      ## Risks

      - none
      """
    let document = MarkdownDocument.parse(text)
    let observability = try #require(document.section(anchor: "observability"))
    #expect(
      observability.fences.first?.body == [
        "# this looks like a heading but is fenced code", "echo hi",
      ])
    #expect(document.section(anchor: "this-looks-like-a-heading-but-is-fenced-code") == nil)
    #expect(document.section(anchor: "risks") != nil)
  }

  @Test(
    "a requirement bullet yields its id and any bracketed tags — catches design-lint losing both together"
  )
  func requirementBulletYieldsIdAndTags() throws {
    let text = """
      ## Requirements

      - req-offline-queue-drains-on-reconnect: Queued orders submit once online [ev-queue-drains-online]
      - Not an id, just prose.
      """
    let requirements = try #require(MarkdownDocument.parse(text).section(anchor: "requirements"))
    #expect(requirements.bullets.count == 2)
    let tagged = requirements.bullets[0]
    #expect(tagged.id == "req-offline-queue-drains-on-reconnect")
    #expect(tagged.remainder == "Queued orders submit once online [ev-queue-drains-online]")
    #expect(tagged.tags == ["ev-queue-drains-online"])
    let untagged = requirements.bullets[1]
    #expect(untagged.id == nil)
    #expect(untagged.tags.isEmpty)
  }

  @Test(
    "frontmatter fields parse as key/value pairs — catches design-doc status becoming unreadable")
  func frontmatterParses() throws {
    let text = try Self.loadValidFixture()
    let document = MarkdownDocument.parse(text)
    #expect(document.frontmatter["status"] == "approved")
    #expect(document.frontmatter["area"] == "checkout")
    #expect(document.frontmatter["tier"] == "standard")
  }

  @Test(
    "a trailing '# comment' on a frontmatter value is stripped — catches the template's own status comment leaking into the value"
  )
  func frontmatterStripsTrailingComment() {
    let text = """
      ---
      status: approved # proposed | approved | built | superseded-by: <slug>
      ---

      # Doc
      """
    #expect(MarkdownDocument.parse(text).frontmatter["status"] == "approved")
  }

  @Test(
    "a bullet ending in a bare id and colon still yields that id — catches an empty-statement bullet losing its id"
  )
  func bulletEndingInBareColonYieldsId() throws {
    let text = """
      ## Requirements

      - req-empty-statement:
      """
    let requirements = try #require(MarkdownDocument.parse(text).section(anchor: "requirements"))
    #expect(requirements.bullets.first?.id == "req-empty-statement")
    #expect(requirements.bullets.first?.remainder == "")
  }

  @Test(
    "options nest as subsections of the Options heading — catches option count being unreadable")
  func optionsNestUnderOptionsHeading() throws {
    let text = try Self.loadValidFixture()
    let options = try #require(MarkdownDocument.parse(text).section(anchor: "options"))
    #expect(
      options.subsections.map(\.heading) == [
        "Option 1: Client-side queue with a TCA reducer",
        "Option 2: Server-side draft orders",
      ])
  }

  @Test(
    "a relative link is distinguished from an absolute URL — catches docs-lint treating a web link as a repo path"
  )
  func relativeVsAbsoluteLinks() throws {
    let text = """
      ## Risks

      See [the playbook](../playbook.md) and [RFC 9110](https://www.rfc-editor.org/rfc/rfc9110).
      """
    let risks = try #require(MarkdownDocument.parse(text).section(anchor: "risks"))
    #expect(risks.links.count == 2)
    #expect(risks.links[0].destination == "../playbook.md")
    #expect(risks.links[0].isRelative)
    #expect(risks.links[1].destination == "https://www.rfc-editor.org/rfc/rfc9110")
    #expect(!risks.links[1].isRelative)
  }
}

@Suite("Design document")
struct DesignDocumentTests {
  static func loadValidFixture() throws -> String {
    try MarkdownDocumentTests.loadValidFixture()
  }

  @Test(
    "a design doc reads typed status, requirements, evidence and test plan from the valid fixture")
  func typedSectionsFromValidFixture() throws {
    let text = try Self.loadValidFixture()
    let design = DesignDocument(markdown: MarkdownDocument.parse(text))

    #expect(design.status == .approved)
    #expect(design.area == "checkout")
    #expect(design.tier == "standard")

    #expect(
      design.requirements.map(\.id) == [
        "req-offline-queue-drains-on-reconnect", "req-queue-survives-app-relaunch",
      ])
    #expect(
      design.evidence.map(\.tag) == ["ev-tca-effect-run-supports-cancellation", "UNVERIFIED"])
    #expect(design.options.count == 2)

    #expect(
      design.testPlan.map(\.id) == [
        "test-queued-orders-replay-in-submit-order", "test-queue-persists-across-relaunch",
      ])
    #expect(design.testPlan.map(\.tier) == ["T1", "T2"])

    let moduleKinds = try #require(design.moduleKinds)
    #expect(moduleKinds.header == ["Module", "Kind", "Reason"])
    #expect(moduleKinds.rows.count == 2)
  }

  @Test("a 'superseded-by' status frontmatter value round-trips the target slug")
  func supersededByStatusParses() {
    let text = """
      ---
      status: superseded-by: checkout-v2
      area: checkout
      tier: quick
      ---

      # Old design
      """
    let design = DesignDocument(markdown: MarkdownDocument.parse(text))
    #expect(design.status == .supersededBy("checkout-v2"))
  }

  @Test("a status value outside the spec's four forms reads as unknown, not a silent default")
  func unrecognisedStatusReadsAsUnknown() {
    let text = """
      ---
      status: draft
      ---

      # Doc
      """
    let design = DesignDocument(markdown: MarkdownDocument.parse(text))
    #expect(design.status == .unknown("draft"))
  }

  @Test("a test-plan bullet with no tier still yields its id and behaviour, with an empty tier")
  func testPlanBulletWithoutTierHasEmptyTier() {
    let text = """
      ## Test plan by tier

      - test-missing-tier-field: behaviour with no tier annotation
      """
    let design = DesignDocument(markdown: MarkdownDocument.parse(text))
    let item = design.testPlan.first
    #expect(item?.id == "test-missing-tier-field")
    #expect(item?.behaviour == "behaviour with no tier annotation")
    #expect(item?.tier == "")
  }
}
