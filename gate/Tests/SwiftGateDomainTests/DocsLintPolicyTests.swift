import SwiftGateDomain
import Testing

@Suite("Docs lint — policy and budgets")
struct DocsLintPolicyTests {
  static func doc(_ path: String, _ text: String) -> DocsLintPolicy.ScannedDocument {
    DocsLintPolicy.ScannedDocument(
      path: path, rawText: text, markdown: MarkdownDocument.parse(text))
  }

  static func check(
    _ documents: [DocsLintPolicy.ScannedDocument], config: DocsConfig = DocsConfig()
  ) throws -> [Finding] {
    try DocsLintPolicy.check(documents: documents, config: config)
  }

  // MARK: - Managed files

  @Test(
    "a managed_files entry that doesn't exist among the scanned docs is flagged — catches a stamped router silently deleted"
  )
  func missingManagedFileIsFlagged() throws {
    let config = DocsConfig(managedFiles: ["docs/index.md", "AGENTS.md"])
    let findings = try Self.check([Self.doc("AGENTS.md", "one two three")], config: config)
    let missing = findings.filter { $0.ruleID == "docs-lint.managed-file-missing" }
    #expect(missing.count == 1)
    #expect(missing.first?.message.contains("docs/index.md") == true)
  }

  @Test(
    "a router found on disk but absent from managed_files is flagged — catches config drifting behind a newly stamped area router"
  )
  func unlistedRouterFileIsFlagged() throws {
    let config = DocsConfig(managedFiles: ["docs/index.md", "AGENTS.md"])
    let findings = try Self.check(
      [
        Self.doc("docs/index.md", "one two"),
        Self.doc("AGENTS.md", "one two"),
        Self.doc("docs/area/index.md", "one two"),
      ], config: config)
    let unlisted = findings.filter { $0.ruleID == "docs-lint.managed-file-unlisted" }
    #expect(unlisted.count == 1)
    #expect(unlisted.first?.file == "docs/area/index.md")
  }

  @Test(
    "every managed_files entry present and every router listed produces no managed-file finding")
  func managedFilesInAgreementAreNotFlagged() throws {
    let config = DocsConfig(managedFiles: ["docs/index.md", "AGENTS.md"])
    let findings = try Self.check(
      [Self.doc("docs/index.md", "one two"), Self.doc("AGENTS.md", "one two")], config: config)
    #expect(findings.filter { $0.ruleID.hasPrefix("docs-lint.managed-file") } == [])
  }

  // MARK: - Non-vacuity: repo anchors

  @Test(
    "a configured anchor matching no heading anywhere is flagged — catches a vacuous rule protecting nothing"
  )
  func vacuousAnchorIsFlagged() throws {
    let config = DocsConfig(anchors: ["nonexistent-anchor"])
    let findings = try Self.check(
      [Self.doc("docs/topic.md", "## Real Heading\n\nprose")], config: config)
    let vacuous = findings.filter { $0.ruleID == "docs-lint.anchor-vacuous" }
    #expect(vacuous.count == 1)
    #expect(vacuous.first?.message.contains("nonexistent-anchor") == true)
  }

  @Test("a configured anchor matching a real heading anywhere in the corpus is not flagged")
  func anchorMatchingAHeadingIsNotFlagged() throws {
    let config = DocsConfig(anchors: ["custom-note"])
    let findings = try Self.check(
      [Self.doc("docs/topic.md", "## Custom Note\n\nprose")], config: config)
    #expect(findings.filter { $0.ruleID == "docs-lint.anchor-vacuous" } == [])
  }

  // MARK: - Banned phrases

  @Test("a banned phrase found in a doc is flagged with the reason that banned it")
  func bannedPhraseIsFlaggedWithItsReason() throws {
    let config = DocsConfig(
      bannedPhrases: [BannedPhrase(phrase: "leverage", reason: "vague business jargon")])
    let findings = try Self.check(
      [Self.doc("docs/topic.md", "we should leverage the existing client.")], config: config)
    let finding = try #require(findings.first { $0.ruleID == "docs-lint.banned-phrase" })
    #expect(finding.message.contains("leverage"))
    #expect(finding.message.contains("vague business jargon"))
  }

  @Test(
    "a banned phrase config entry without a reason is rejected at config-parse time, not waved through as a silent pass — the same enforcement DocsPlanConfigTests.bannedPhraseWithoutReasonRejected exercises through TOML"
  )
  func bannedPhraseWithoutReasonIsRejectedAtConstruction() {
    #expect {
      _ = try Config(
        xcode: "26.2", appScheme: "App", packages: ["Packages/*"],
        simulator: SimulatorConfig(device: "iPhone 17", os: "26.2"),
        docs: DocsConfig(bannedPhrases: [BannedPhrase(phrase: "leverage", reason: "")]))
    } throws: { error in
      (error as? ConfigValidationError)?.issues.contains {
        if case .emptyValue(let path) = $0 {
          path == "docs.banned_phrases[0].reason"
        } else {
          false
        }
      } == true
    }
  }

  // MARK: - Budgets

  @Test("AGENTS.md over its configured line budget is flagged")
  func agentsMdOverLineBudgetIsFlagged() throws {
    let text = Array(repeating: "line", count: 61).joined(separator: "\n")
    let findings = try Self.check([Self.doc("AGENTS.md", text)])
    let finding = try #require(findings.first { $0.ruleID == "docs-lint.agents-md-line-budget" })
    #expect(finding.message.contains("61"))
    #expect(finding.message.contains("60"))
    #expect(finding.severity == .major)
  }

  @Test(
    "AGENTS.md at exactly its line budget is not flagged — catches an off-by-one on the boundary")
  func agentsMdAtLineBudgetIsNotFlagged() throws {
    let text = Array(repeating: "line", count: 60).joined(separator: "\n")
    let findings = try Self.check([Self.doc("AGENTS.md", text)])
    #expect(findings.filter { $0.ruleID == "docs-lint.agents-md-line-budget" } == [])
  }

  @Test("a router doc over its configured word budget is flagged")
  func routerOverWordBudgetIsFlagged() throws {
    let config = DocsConfig(budgets: DocsBudgets(router: 3))
    let findings = try Self.check(
      [Self.doc("docs/index.md", "## Topics\n\none two three four")], config: config)
    let finding = try #require(findings.first { $0.ruleID == "docs-lint.router-word-budget" })
    #expect(finding.message.contains("4"))
    #expect(finding.message.contains("3"))
  }

  @Test(
    "a non-router topic doc over its configured word budget is flagged, using the topic budget, not the router one"
  )
  func topicOverWordBudgetIsFlagged() throws {
    let config = DocsConfig(budgets: DocsBudgets(topic: 3))
    let findings = try Self.check(
      [Self.doc("docs/handoffs/topic.md", "## Notes\n\none two three four")], config: config)
    let finding = try #require(findings.first { $0.ruleID == "docs-lint.topic-word-budget" })
    #expect(finding.message.contains("4"))
    #expect(finding.message.contains("3"))
  }

  @Test(
    "a design doc is never budgeted by docs-lint, however large — design-lint already governs its whole-doc and per-section budgets, so docs-lint doesn't double-govern the same prose"
  )
  func designDocIsExcludedFromDocsLintBudgets() throws {
    let hugeProse = Array(repeating: "word", count: 5_000).joined(separator: " ")
    let config = DocsConfig(budgets: DocsBudgets(router: 10, topic: 10))
    let findings = try Self.check(
      [Self.doc("docs/area/designs/big-design.md", "## Problem\n\n\(hugeProse)")], config: config)
    #expect(findings.filter { $0.ruleID.hasSuffix("word-budget") } == [])
  }

  @Test(
    "docs-lint never applies design-lint's per-section budgets (e.g. Architecture's 80 words) to a non-design doc — a deliberate decision: [docs.budgets.sections] is design-lint's exclusively"
  )
  func sectionBudgetsDoNotApplyOutsideDesignDocs() throws {
    let architectureProse = Array(repeating: "word", count: 81).joined(separator: " ")
    let findings = try Self.check(
      [Self.doc("docs/handoffs/topic.md", "## Architecture\n\n\(architectureProse)")])
    #expect(findings.isEmpty)
  }

  // MARK: - Local paths, attributed to the real doc

  @Test(
    "a local-path finding is attributed to the document docs-lint scanned, not LocalPathRule's internal placeholder"
  )
  func localPathFindingIsAttributedToTheRealDocPath() throws {
    let findings = try Self.check([Self.doc("docs/handoffs/topic.md", "see /Users/me/notes")])
    let finding = try #require(findings.first { $0.ruleID == "docs-lint.local-path" })
    #expect(finding.file == "docs/handoffs/topic.md")
  }

  // MARK: - Every finding is major (docs-lint has no advisory family; the spec calls each of these a violation)

  @Test("every docs-lint policy finding is major and fails the gate")
  func everyFindingIsMajorAndFailsTheGate() throws {
    let config = DocsConfig(
      managedFiles: ["docs/index.md"],
      bannedPhrases: [BannedPhrase(phrase: "leverage", reason: "jargon")],
      anchors: ["nonexistent-anchor"],
      budgets: DocsBudgets(router: 1, topic: 1, agentsMdLines: 1))
    let findings = try Self.check(
      [
        Self.doc("AGENTS.md", "one\ntwo\nthree"),
        Self.doc("docs/handoffs/topic.md", "leverage /Users/me/x one two three"),
      ], config: config)
    #expect(!findings.isEmpty)
    for finding in findings {
      #expect(finding.severity == .major)
      #expect(finding.severity.failsGate)
    }
  }
}

@Suite("Local path rule")
struct LocalPathRuleTests {
  static func flagged(_ text: String) -> Bool {
    LocalPathRule.scan(text).contains { $0.ruleID == LocalPathRule.ruleID }
  }

  // MARK: - Flagged

  @Test("a tilde path outside the product allowlist is flagged")
  func tildeDeveloperPathIsFlagged() {
    #expect(Self.flagged("see ~/Developer/x for the source"))
  }

  @Test("/Users/... is flagged")
  func usersPathIsFlagged() {
    #expect(Self.flagged("the file lives at /Users/me/x"))
  }

  @Test("/home/... is flagged")
  func homePathIsFlagged() {
    #expect(Self.flagged("the file lives at /home/me/x"))
  }

  @Test("/private/tmp/... is flagged")
  func privateTmpPathIsFlagged() {
    #expect(Self.flagged("scratch output at /private/tmp/x"))
  }

  @Test("/var/folders/... is flagged")
  func varFoldersPathIsFlagged() {
    #expect(Self.flagged("temp dir /var/folders/ab/x"))
  }

  @Test("$HOME/... is flagged")
  func homeEnvironmentVariablePathIsFlagged() {
    #expect(Self.flagged("set to $HOME/x before running"))
  }

  // MARK: - False positives (never flagged)

  @Test(
    "a path inside a fenced code block, shown as an example of what NOT to do, is not flagged — catches an illustrative anti-pattern being reported as a live violation"
  )
  func pathInsideFencedCodeBlockIsNotFlagged() {
    let text = """
      Don't hardcode a machine path like this:

      ```
      let path = "/Users/me/x"
      ```

      Use a repository-relative path instead.
      """
    #expect(!Self.flagged(text))
  }

  @Test("the harness's own ~/.swift-harness/ product path is allowed")
  func swiftHarnessProductPathIsAllowed() {
    #expect(!Self.flagged("state lives under ~/.swift-harness/plans"))
  }

  @Test("the harness's own ~/.local/bin/swiftgate product path is allowed")
  func localBinSwiftgateProductPathIsAllowed() {
    #expect(!Self.flagged("install the shim at ~/.local/bin/swiftgate"))
  }

  @Test("the harness's own ~/.cache/swift-harness/ product path is allowed")
  func cacheSwiftHarnessProductPathIsAllowed() {
    #expect(!Self.flagged("the shim's binary cache lives at ~/.cache/swift-harness/bin"))
  }

  @Test(
    "a URL that happens to carry /Users/ in its path is not flagged — it names a remote resource, not a local one"
  )
  func urlContainingUsersSegmentIsNotFlagged() {
    #expect(!Self.flagged("see https://example.com/Users/x for details"))
  }

  @Test("/usr/bin/find is not flagged — it isn't a home directory, despite starting like one")
  func usrBinFindIsNotFlagged() {
    #expect(!Self.flagged("run /usr/bin/find over the tree"))
  }

  // MARK: - DocsLintPolicy.productPaths includes the shim's binary cache

  @Test("DocsLintPolicy.productPaths names the shim's default binary cache with no config key")
  func productPathsIncludesTheBinaryCache() {
    #expect(DocsLintPolicy.productPaths.contains("~/.cache/swift-harness/"))
  }
}
