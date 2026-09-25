import Foundation
import SwiftGateDomain
import Testing

@Suite("Design lint — diagrams and budgets")
struct DesignLintDiagramsTests {
  static let fixturesRoot = URL(filePath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "Fixtures/design/diagrams", directoryHint: .isDirectory)

  static func fixture(_ name: String) throws -> DesignDocument {
    let text = try String(contentsOf: fixturesRoot.appending(path: name), encoding: .utf8)
    return DesignDocument(markdown: MarkdownDocument.parse(text))
  }

  static func parse(_ text: String) -> DesignDocument {
    DesignDocument(markdown: MarkdownDocument.parse(text))
  }

  static func check(
    _ document: DesignDocument, budgets: DocsBudgets = DocsBudgets()
  ) throws -> [Finding] {
    try DesignLintDiagrams.check(
      document: document, docPath: "docs/example/designs/x.md", budgets: budgets)
  }

  /// An Architecture section with two known-type diagrams (so only the word-budget rule can fire)
  /// and exactly `words` prose words after them.
  static func architectureSection(words: Int) -> String {
    let prose = Array(repeating: "word", count: words).joined(separator: " ")
    return """
      ## Architecture

      ```mermaid
      flowchart TD
        A --> B
      ```

      ```mermaid
      sequenceDiagram
        A->>B: submit
      ```

      \(prose)
      """
  }

  static func loadValidDesign() throws -> DesignDocument {
    let text = try String(
      contentsOf: fixturesRoot.deletingLastPathComponent().appending(path: "valid.md"),
      encoding: .utf8)
    return DesignDocument(markdown: MarkdownDocument.parse(text))
  }

  // MARK: - D22: Architecture's Mermaid diagrams

  @Test(
    "an Architecture section with no Mermaid fences is flagged — catches a design doc that never draws its module graph"
  )
  func architectureWithoutMermaidIsFlagged() throws {
    let findings = try Self.check(try Self.fixture("missing-diagrams.md"))
    #expect(findings.contains { $0.ruleID == "design-lint.architecture-diagram-count" })
  }

  @Test(
    "a fenced mermaid block with an unrecognised diagram type is flagged — catches a typo'd or invented diagram grammar reaching the Artifact unvalidated"
  )
  func unknownDiagramTypeIsFlagged() throws {
    let findings = try Self.check(try Self.fixture("unknown-type.md"))
    let unknown = findings.filter { $0.ruleID == "design-lint.architecture-diagram-unknown-type" }
    #expect(unknown.count == 1)
    #expect(unknown.first?.message.contains("banana") == true)
    // Only one of the two fences is of a known type, so the count rule also fires.
    #expect(findings.contains { $0.ruleID == "design-lint.architecture-diagram-count" })
  }

  @Test(
    "a mermaid fence whose declaration is blank or a '%%' comment is unknown — catches a diagram design-lint would otherwise wave through unvalidated"
  )
  func blankOrCommentFirstLineIsUnknown() throws {
    let findings = try Self.check(try Self.fixture("blank-and-comment-fences.md"))
    let unknown = findings.filter { $0.ruleID == "design-lint.architecture-diagram-unknown-type" }
    #expect(unknown.count == 2)
    #expect(findings.contains { $0.ruleID == "design-lint.architecture-diagram-count" })
  }

  @Test(
    "a diagram type with a trailing direction is recognised — catches 'flowchart LR' and 'graph TD' being read as unknown types"
  )
  func trailingDirectionDoesNotDefeatKnownType() throws {
    let findings = try Self.check(try Self.fixture("known-types-with-direction.md"))
    #expect(findings.isEmpty)
  }

  @Test(
    "two known-type diagrams in Architecture pass — catches the spec-compliant fixture regressing to a violation"
  )
  func validArchitectureIsClean() throws {
    let findings = try Self.check(try Self.loadValidDesign())
    #expect(findings.filter { $0.ruleID.hasPrefix("design-lint.architecture-diagram") } == [])
  }

  @Test(
    "a mermaid fence outside Architecture doesn't count toward Architecture's two — catches an Options diagram masking a missing Architecture diagram"
  )
  func mermaidOutsideArchitectureDoesNotCount() throws {
    let text = """
      ## Options

      ### Option 1: Client-side queue

      ```mermaid
      flowchart TD
        A --> B
      ```

      ## Architecture

      ```mermaid
      flowchart TD
        A --> B
      ```
      """
    let findings = try Self.check(Self.parse(text))
    #expect(findings.contains { $0.ruleID == "design-lint.architecture-diagram-count" })
  }

  @Test(
    "a mermaid fence nested in a list item still counts — catches an indented diagram being missed"
  )
  func fenceNestedInListItemCounts() throws {
    let text = """
      ## Architecture

      - the module graph:
        ```mermaid
        flowchart TD
          A --> B
        ```
      - the data flow:
        ```mermaid
        sequenceDiagram
          A->>B: submit
        ```
      """
    let findings = try Self.check(Self.parse(text))
    #expect(findings.filter { $0.ruleID.hasPrefix("design-lint.architecture-diagram") } == [])
  }

  @Test(
    "a '~~~' fence is read the same as a '```' fence — catches the alternate fence marker being ignored"
  )
  func tildeFenceIsRecognised() throws {
    let text = """
      ## Architecture

      ~~~mermaid
      flowchart TD
        A --> B
      ~~~

      ~~~mermaid
      sequenceDiagram
        A->>B: submit
      ~~~
      """
    let findings = try Self.check(Self.parse(text))
    #expect(findings.filter { $0.ruleID.hasPrefix("design-lint.architecture-diagram") } == [])
  }

  @Test(
    "a heading-shaped line inside a fenced block doesn't split Architecture — catches a diagram label named like a heading truncating the section"
  )
  func headingInsideFenceIsNotASectionBoundary() throws {
    let text = """
      ## Architecture

      ```mermaid
      flowchart TD
        A[## Module kinds] --> B
      ```

      ```mermaid
      sequenceDiagram
        A->>B: submit
      ```
      """
    let findings = try Self.check(Self.parse(text))
    #expect(findings.filter { $0.ruleID.hasPrefix("design-lint.architecture-diagram") } == [])
  }

  // MARK: - D23: prose word budgets

  @Test(
    "a section over its configured word budget is flagged, naming the section, the count and the limit — catches a budget finding an engineer can't act on"
  )
  func sectionOverBudgetIsFlagged() throws {
    let text = """
      ## Problem

      One two three four five.
      """
    let budgets = DocsBudgets(sections: ["problem": 3])
    let findings = try Self.check(Self.parse(text), budgets: budgets)
    let finding = try #require(findings.first { $0.ruleID == "design-lint.section-word-budget" })
    #expect(finding.message.contains("Problem"))
    #expect(finding.message.contains("5"))
    #expect(finding.message.contains("3"))
    #expect(finding.severity == .major)
    #expect(finding.severity.failsGate)
  }

  @Test(
    "a section at or under its configured budget is not flagged — catches an off-by-one on the budget boundary"
  )
  func sectionAtBudgetIsNotFlagged() throws {
    let text = """
      ## Problem

      One two three.
      """
    let budgets = DocsBudgets(sections: ["problem": 3])
    let findings = try Self.check(Self.parse(text), budgets: budgets)
    #expect(findings.filter { $0.ruleID == "design-lint.section-word-budget" } == [])
  }

  @Test(
    "a section with no configured budget is never flagged — catches every unbudgeted section defaulting to a false positive"
  )
  func sectionWithoutConfiguredBudgetIsNotFlagged() throws {
    let text = """
      ## Problem

      One two three four five six seven eight nine ten.
      """
    let findings = try Self.check(Self.parse(text), budgets: DocsBudgets())
    #expect(findings.filter { $0.ruleID == "design-lint.section-word-budget" } == [])
  }

  // MARK: - Architecture's default 80-word budget (spec §5.3's own table entry)

  @Test(
    "Architecture over its default 80-word budget is flagged, major and gate-failing, with no config — catches the spec's own limit going unenforced by default"
  )
  func architectureOver80WordsIsFlaggedByDefault() throws {
    let findings = try Self.check(
      Self.parse(Self.architectureSection(words: 81)), budgets: DocsBudgets())
    let finding = try #require(findings.first { $0.ruleID == "design-lint.section-word-budget" })
    #expect(finding.message.contains("Architecture"))
    #expect(finding.message.contains("81"))
    #expect(finding.message.contains("80"))
    #expect(finding.severity == .major)
    #expect(finding.severity.failsGate)
  }

  @Test(
    "Architecture at exactly its default 80-word budget is not flagged — catches an off-by-one on the spec's own limit"
  )
  func architectureAt80WordsIsNotFlaggedByDefault() throws {
    let findings = try Self.check(
      Self.parse(Self.architectureSection(words: 80)), budgets: DocsBudgets())
    #expect(findings.filter { $0.ruleID == "design-lint.section-word-budget" } == [])
  }

  @Test(
    "a configured architecture budget overrides the default — catches an override being ignored")
  func architectureBudgetOverrideLiftsTheDefaultLimit() throws {
    let budgets = DocsBudgets(sections: ["architecture": 120])
    let findings = try Self.check(
      Self.parse(Self.architectureSection(words: 81)), budgets: budgets)
    #expect(findings.filter { $0.ruleID == "design-lint.section-word-budget" } == [])
  }

  @Test(
    "an unrelated section key in config keeps the Architecture default — catches one section's override erasing every other section's default"
  )
  func unrelatedSectionKeyKeepsArchitectureDefault() throws {
    // Simulates what ConfigSchema.readDocsBudgets merges: a repo-configured section (here
    // "risks") adds to, rather than replaces, DocsBudgets.defaultSectionWords.
    let budgets = DocsBudgets(
      sections: DocsBudgets.defaultSectionWords.merging(["risks": 50]) { _, configured in
        configured
      })
    let findings = try Self.check(
      Self.parse(Self.architectureSection(words: 81)), budgets: budgets)
    #expect(findings.contains { $0.ruleID == "design-lint.section-word-budget" })
  }

  @Test(
    "the whole document over its word budget is flagged, naming the total and the limit — catches a design that only trips per-section checks"
  )
  func documentOverBudgetIsFlagged() throws {
    let text = """
      ## Problem

      One two three.

      ## Risks

      Four five six.
      """
    let budgets = DocsBudgets(design: 5)
    let findings = try Self.check(Self.parse(text), budgets: budgets)
    let finding = try #require(findings.first { $0.ruleID == "design-lint.document-word-budget" })
    #expect(finding.message.contains("6"))
    #expect(finding.message.contains("5"))
    #expect(finding.severity == .major)
    #expect(finding.severity.failsGate)
  }

  @Test(
    "a long table costs no budget — catches table cells being charged as prose words"
  )
  func longTableCostsNoBudget() throws {
    let text = """
      ## Module kinds

      One word.

      | Module | Kind | Reason |
      |---|---|---|
      | OrderQueueFeature | feature | owns the reducer and the queue state end to end |
      | OrderQueueCore | core | pure queue model with no IO and no side effects at all |
      """
    let budgets = DocsBudgets(sections: ["module-kinds": 2])
    let findings = try Self.check(Self.parse(text), budgets: budgets)
    #expect(findings.filter { $0.ruleID == "design-lint.section-word-budget" } == [])
  }

  @Test("prose inside any code fence costs no words — catches fenced code being charged as prose")
  func fencedCodeCostsNoWords() throws {
    let text = """
      ## Observability

      One word.

      ```swift
      let queue = OrderQueue(capacity: 5, retryPolicy: .exponentialBackoff, logger: LogClient.live)
      ```
      """
    let budgets = DocsBudgets(sections: ["observability": 2])
    let findings = try Self.check(Self.parse(text), budgets: budgets)
    #expect(findings.filter { $0.ruleID == "design-lint.section-word-budget" } == [])
  }

  // MARK: - Word counting (shared by the section and document budget checks)

  @Test("a hyphenated word counts as one word — catches a hyphen splitting one word into two")
  func hyphenatedWordCountsAsOne() throws {
    let text = """
      ## Problem

      A well-known issue.
      """
    // 3 words if "well-known" counts once; a budget of 3 must not fire.
    let budgets = DocsBudgets(sections: ["problem": 3])
    let findings = try Self.check(Self.parse(text), budgets: budgets)
    #expect(findings.filter { $0.ruleID == "design-lint.section-word-budget" } == [])
  }

  @Test(
    "inline code counts toward prose like any other word — catches an undercount from silently dropping code spans"
  )
  func inlineCodeCountsAsProse() throws {
    let text = """
      ## Problem

      Call `foo bar` now.
      """
    // "Call", "`foo", "bar`", "now." = 4 words.
    let budgets = DocsBudgets(sections: ["problem": 3])
    let findings = try Self.check(Self.parse(text), budgets: budgets)
    let finding = try #require(findings.first { $0.ruleID == "design-lint.section-word-budget" })
    #expect(finding.message.contains("4"))
  }

  @Test(
    "a link counts its text only, not its destination — catches a long URL inflating the word count"
  )
  func linkCountsTextOnly() throws {
    let text = """
      ## Risks

      See [Foo Bar](https://example.com/a/very/long/path/that/would/blow/the/budget/if/counted).
      """
    // "See" + "Foo" + "Bar" = 3 words once the destination itself is excluded.
    let budgets = DocsBudgets(sections: ["risks": 3])
    let findings = try Self.check(Self.parse(text), budgets: budgets)
    #expect(findings.filter { $0.ruleID == "design-lint.section-word-budget" } == [])
  }

  @Test("non-ASCII words count like any other word — catches multi-byte characters being mis-split")
  func nonASCIIWordsCount() throws {
    let text = """
      ## Problem

      café résumé façade.
      """
    let budgets = DocsBudgets(sections: ["problem": 3])
    let findingsAtBudget = try Self.check(Self.parse(text), budgets: budgets)
    #expect(findingsAtBudget.filter { $0.ruleID == "design-lint.section-word-budget" } == [])

    let tighterBudgets = DocsBudgets(sections: ["problem": 2])
    let findingsOverBudget = try Self.check(Self.parse(text), budgets: tighterBudgets)
    let finding = try #require(
      findingsOverBudget.first { $0.ruleID == "design-lint.section-word-budget" })
    #expect(finding.message.contains("3"))
  }

  // MARK: - Findings carry rule ids and a locatable file

  @Test("every finding names its rule id and the design doc's path")
  func findingsCarryRuleIDAndPath() throws {
    let findings = try Self.check(try Self.fixture("missing-diagrams.md"))
    for finding in findings {
      #expect(!finding.ruleID.isEmpty)
      #expect(finding.file == "docs/example/designs/x.md")
    }
  }
}
