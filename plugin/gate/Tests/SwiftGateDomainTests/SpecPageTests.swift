import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

/// The fixtures under `Fixtures/spec-page/` are pages a sprint session wrote from each spec file
/// there; their README records the capture.
enum SpecPageFixture {
  static let covered = ["recipient-postcode", "task-status"]

  static func page(_ name: String) throws -> String {
    try Fixture.text("spec-page/\(name).page.txt")
  }

  static func spec(_ name: String) throws -> String {
    try Fixture.text("spec-page/\(name).spec.txt")
  }

  /// `text` with `target` replaced by `replacement`, failing the test when `target` isn't there,
  /// so a derived page never silently equals the captured one.
  static func replacing(_ target: String, with replacement: String, in text: String) throws
    -> String
  {
    try #require(text.contains(target), "the page no longer holds \(target)")
    return text.replacingOccurrences(of: target, with: replacement)
  }

  static func parsed(_ text: String) throws -> SpecPage {
    switch SpecPage.parse(text) {
    case .parsed(let page): return page
    case .malformed(let problems):
      Issue.record("malformed: \(problems)")
      throw SpecPageFixtureError.malformed
    }
  }

  static func problems(_ text: String) -> [SpecPageProblem] {
    switch SpecPage.parse(text) {
    case .parsed: []
    case .malformed(let problems): problems
    }
  }

  static func ruleIDs(_ report: SpecPageReport) -> [String] {
    report.findings.map(\.ruleID)
  }
}

enum SpecPageFixtureError: Error { case malformed }

@Suite("spec page parse")
struct SpecPageParseTests {
  @Test(
    "a captured sprint page parses into its title, spec path, goal, modules, surface, slices and out of scope — catches a parser tighter than the pages the sprint skill writes"
  )
  func capturedPageParses() throws {
    let page = try SpecPageFixture.parsed(SpecPageFixture.page("recipient-postcode"))

    #expect(page.title == "Save a recipient and postcode")
    #expect(page.specPath == "./recipient-postcode.spec.md")
    #expect(page.goal.hasPrefix("On the first screen, under the posts count, a user fills in"))
    #expect(page.goal.hasSuffix("without touching the saved address."))
    #expect(page.modules.map(\.name) == ["AddressClient", "AppCore", "AppUI"])
    #expect(page.modules.map(\.kind) == [.client, .feature, .feature])
    #expect(page.modules[1].dependsOn == "AddressClient, LogClient")
    #expect(page.modules[0].dependsOn == "none")
    #expect(page.surface.count == 5)
    #expect(page.surface[0] == "`Address`: `recipient: String`, `postcode: String`")
    #expect(
      page.outOfScope == [
        "More than one address, address lookup, and syncing to a server.",
        "Any network call from the form.",
      ])
    #expect(page.slices.map(\.number) == [1, 2, 3, 4])
    #expect(page.slices.map(\.line) == [23, 24, 25, 26])
    #expect(
      page.slices.map(\.testName) == [
        "testShortRecipientShowsErrorAndDisablesSave",
        "testInvalidPostcodeShowsErrorAndDisablesSave",
        "testSaveStoresAddressAndNextLaunchShowsIt",
        "testClearEmptiesFieldsAndErrorsKeepsSavedAddress",
      ])
    #expect(page.slices.allSatisfy { $0.tier == .t1 })
    #expect(
      page.slices[0].spec
        == .quote(
          "A recipient of fewer than 2 characters after trimming shows \"Recipient must be 2 to 50 characters\" and Save stays disabled."
        ))
  }

  @Test(
    "a page whose slices quote lines with arrows parses every quote whole — catches a quote cut at its first inner quote mark"
  )
  func innerQuotesAndArrows() throws {
    let page = try SpecPageFixture.parsed(SpecPageFixture.page("task-status"))

    #expect(
      page.slices[1].spec
        == .quote(
          "From In progress, \"Block\" moves the task to Blocked and adds \"In progress → Blocked\" to the history."
        ))
    #expect(page.modules.map(\.name) == ["AppCore", "AppUI"])
  }

  @Test(
    "a slice that says Spec: none parses as none — catches none read as a quote the check then fails"
  )
  func specNone() throws {
    let page = try SpecPageFixture.parsed(SpecPageFixture.page("shipping-address"))

    #expect(page.slices.map(\.spec).filter { $0 == .none }.count == 1)
    #expect(page.slices[2].spec == .none)
    #expect(page.slices[2].testName == "deliveryNoteShowsCharactersLeft")
  }

  @Test(
    "a goal wrapped over 2 lines, as the sprint session wrote one, reads as 1 goal — catches a parser that takes only a section's first line"
  )
  func wrappedGoal() throws {
    let text = try SpecPageFixture.replacing(
      "and a 5-digit postcode, sees", with: "and a 5-digit postcode,\nsees",
      in: SpecPageFixture.page("recipient-postcode"))

    let page = try SpecPageFixture.parsed(text)

    #expect(page.goal.contains("and a 5-digit postcode, sees each field's error"))
  }

  @Test(
    "an optional Tier: T2 or T3 on a slice sets its tier, and a slice without one is T1 — catches every slice read as T1"
  )
  func optionalTier() throws {
    var text = try SpecPageFixture.replacing(
      "`recipientError` to \"Recipient must be 2 to 50 characters\" and `isSaveDisabled` stays true. Spec:",
      with:
        "`recipientError` to \"Recipient must be 2 to 50 characters\" and `isSaveDisabled` stays true. Tier: T2. Spec:",
      in: SpecPageFixture.page("recipient-postcode"))
    text = try SpecPageFixture.replacing(
      "loads the same `recipient` and `postcode` on launch. Spec:",
      with: "loads the same `recipient` and `postcode` on launch. Tier: T3. Spec:", in: text)

    let page = try SpecPageFixture.parsed(text)

    #expect(page.slices.map(\.tier) == [.t2, .t1, .t3, .t1])
  }

  @Test(
    "a slice with Tier: T0, T1 or an unknown tier is a format problem on its line — catches a slice gated at a tier that runs no test"
  )
  func badTier() throws {
    for tier in ["T0", "T1", "T4", "t2"] {
      let text = try SpecPageFixture.replacing(
        "stays true. Spec: \"A postcode", with: "stays true. Tier: \(tier). Spec: \"A postcode",
        in: SpecPageFixture.page("recipient-postcode"))

      let problems = SpecPageFixture.problems(text)

      #expect(problems.map(\.line) == [24], "Tier: \(tier)")
      #expect(problems.first?.message.contains("Tier") == true, "\(problems)")
    }
  }

  @Test(
    "a slice with 2 tests is a format problem naming the slice — catches a slice that hides a second acceptance test"
  )
  func twoTests() throws {
    let text = try SpecPageFixture.replacing(
      "`isSaveDisabled` stays true. Spec: \"A postcode",
      with:
        "`isSaveDisabled` stays true. Test: `testValidPostcodeClearsError`: `postcodeError` is nil. Spec: \"A postcode",
      in: SpecPageFixture.page("recipient-postcode"))

    let problems = SpecPageFixture.problems(text)

    #expect(problems.count == 1)
    #expect(problems.first?.line == 24)
    #expect(problems.first?.message.contains("slice 2") == true, "\(problems)")
    #expect(problems.first?.message.contains("2 tests") == true, "\(problems)")
  }

  @Test(
    "a slice with no test is a format problem naming the slice — catches a slice that ships untested"
  )
  func noTest() throws {
    let text = try SpecPageFixture.replacing(
      "Test: `testClearEmptiesFieldsAndErrorsKeepsSavedAddress`:", with: "It checks that",
      in: SpecPageFixture.page("recipient-postcode"))

    let problems = SpecPageFixture.problems(text)

    #expect(problems.map(\.line) == [26])
    #expect(problems.first?.message.contains("slice 4") == true, "\(problems)")
    #expect(problems.first?.message.contains("0 tests") == true, "\(problems)")
  }

  @Test(
    "2 slices with the same test name are a format problem naming the name — catches 2 coverage items with 1 id"
  )
  func repeatedTestName() throws {
    let text = try SpecPageFixture.replacing(
      "`testClearEmptiesFieldsAndErrorsKeepsSavedAddress`",
      with: "`testShortRecipientShowsErrorAndDisablesSave`",
      in: SpecPageFixture.page("recipient-postcode"))

    let problems = SpecPageFixture.problems(text)

    #expect(problems.map(\.line) == [26])
    #expect(
      problems.first?.message.contains("testShortRecipientShowsErrorAndDisablesSave") == true,
      "\(problems)")
  }

  @Test(
    "a slice with neither a quote nor none after Spec: is a format problem — catches a paraphrase or a missing Spec: read as a quote"
  )
  func missingSpec() throws {
    let page = try SpecPageFixture.page("recipient-postcode")
    let noSpec = try SpecPageFixture.replacing(
      " Spec: \"Saving a valid address stores it, and the next launch shows the saved values.\"",
      with: "", in: page)
    let unquoted = try SpecPageFixture.replacing(
      "Spec: \"Saving a valid address stores it, and the next launch shows the saved values.\"",
      with: "Spec: saving stores it", in: page)
    let emptyQuote = try SpecPageFixture.replacing(
      "Spec: \"Saving a valid address stores it, and the next launch shows the saved values.\"",
      with: "Spec: \"\"", in: page)

    for text in [noSpec, unquoted, emptyQuote] {
      let problems = SpecPageFixture.problems(text)
      #expect(problems.map(\.line) == [25])
      #expect(problems.first?.message.contains("Spec:") == true, "\(problems)")
    }
  }

  @Test(
    "a page without ## Surface is a format problem naming Surface — catches a page whose surface commit has no list to hold"
  )
  func missingSection() throws {
    let page = try SpecPageFixture.page("recipient-postcode")
    let start = try #require(page.range(of: "## Surface\n"))
    let end = try #require(page.range(of: "## Slices\n"))
    let text = page.replacingCharacters(in: start.lowerBound..<end.lowerBound, with: "")

    let problems = SpecPageFixture.problems(text)

    #expect(problems.count == 1)
    #expect(problems.first?.message.contains("## Surface") == true, "\(problems)")
  }

  @Test(
    "sections out of order are a format problem naming the section — catches a page whose slices come before the surface they build on"
  )
  func sectionsOutOfOrder() throws {
    let page = try SpecPageFixture.page("recipient-postcode")
    let surfaceStart = try #require(page.range(of: "## Surface\n"))
    let slicesStart = try #require(page.range(of: "## Slices\n"))
    let outStart = try #require(page.range(of: "## Out of scope\n"))
    let surface = String(page[surfaceStart.lowerBound..<slicesStart.lowerBound])
    let slices = String(page[slicesStart.lowerBound..<outStart.lowerBound])
    let text =
      String(page[..<surfaceStart.lowerBound]) + slices + surface
      + String(page[outStart.lowerBound...])

    let problems = SpecPageFixture.problems(text)

    #expect(!problems.isEmpty)
    #expect(problems.contains { $0.message.contains("## Surface") }, "\(problems)")
  }

  @Test(
    "a page with no title, no Spec: line or an unknown section is a format problem naming each — catches a page that reports only its first problem"
  )
  func everyProblemReported() throws {
    var text = try SpecPageFixture.replacing(
      "# Save a recipient and postcode\n", with: "Save a recipient and postcode\n",
      in: SpecPageFixture.page("recipient-postcode"))
    text = try SpecPageFixture.replacing(
      "Spec: ./recipient-postcode.spec.md\n", with: "", in: text)
    text = try SpecPageFixture.replacing("## Out of scope\n", with: "## Notes\n", in: text)

    let messages = SpecPageFixture.problems(text).map(\.message)

    #expect(messages.contains { $0.contains("title") }, "\(messages)")
    #expect(messages.contains { $0.contains("Spec:") }, "\(messages)")
    #expect(messages.contains { $0.contains("## Notes") }, "\(messages)")
    #expect(messages.contains { $0.contains("## Out of scope") }, "\(messages)")
  }

  @Test(
    "a module row with a kind standards.md doesn't list is a format problem on its line — catches a module kind no arch rule knows"
  )
  func unknownModuleKind() throws {
    let text = try SpecPageFixture.replacing(
      "| AppUI | feature |", with: "| AppUI | screen |",
      in: SpecPageFixture.page("recipient-postcode"))

    let problems = SpecPageFixture.problems(text)

    #expect(problems.map(\.line) == [13])
    #expect(problems.first?.message.contains("screen") == true, "\(problems)")
  }

  @Test(
    "slices numbered out of sequence are a format problem — catches a slice count that disagrees with the last number"
  )
  func sliceNumbering() throws {
    let text = try SpecPageFixture.replacing(
      "\n3. Save through", with: "\n5. Save through",
      in: SpecPageFixture.page("recipient-postcode"))

    let problems = SpecPageFixture.problems(text)

    #expect(problems.map(\.line) == [25])
  }

  @Test(
    "a slice's id is slice-<n>-<kebab test name> — catches an id plan-lint coverage can't match to its test",
    arguments: [
      (
        "testShortRecipientShowsErrorAndDisablesSave",
        "test-short-recipient-shows-error-and-disables-save"
      ),
      ("newDocumentIsDraft", "new-document-is-draft"),
      ("URLParserHandlesIPv6", "url-parser-handles-i-pv6"),
      ("loads 2 items_fast", "loads-2-items-fast"),
      ("test2Items", "test2-items"),
    ])
  func kebabCase(_ example: (name: String, kebab: String)) {
    #expect(SpecPage.kebabCase(example.name) == example.kebab)
  }

  @Test(
    "a parsed slice's id joins its number and kebab test name — catches an id without its number")
  func sliceID() throws {
    let page = try SpecPageFixture.parsed(SpecPageFixture.page("task-status"))

    #expect(
      page.slices.map(\.id) == [
        "slice-1-test-new-task-is-to-do-with-only-start-and-empty-history",
        "slice-2-test-block-from-in-progress-moves-to-blocked-and-records-history",
        "slice-3-test-only-blocked-offers-unblock-and-done-offers-only-reopen",
        "slice-4-test-undo-reverts-latest-change-and-is-disabled-when-history-empty",
      ])
  }
}

@Suite("spec page check")
struct SpecPageCheckTests {
  @Test(
    "both captured pages whose slices all quote their spec are GREEN and skippable — catches a check stricter than the pages the sprint skill writes",
    arguments: SpecPageFixture.covered)
  func coveredPagesAreSkippable(_ name: String) throws {
    let report = try SpecPageCheck.check(
      page: SpecPageFixture.page(name), pagePath: "\(name).page.txt",
      spec: SpecPageFixture.spec(name))

    #expect(report.verdict == .green)
    #expect(report.confirm == .skippable)
    #expect(SpecPageFixture.ruleIDs(report) == ["spec-page.summary"])
    #expect(report.findings.first?.severity == .nit)
    #expect(report.page?.slices.count == 4)
  }

  @Test(
    "1 slice saying Spec: none makes confirm required without failing the page — catches the skill skipping the user's confirm"
  )
  func noneRequiresConfirm() throws {
    let text = try SpecPageFixture.replacing(
      "Spec: \"Clear empties every field and clears every error, and the saved address is unchanged.\"",
      with: "Spec: none", in: SpecPageFixture.page("recipient-postcode"))

    let report = try SpecPageCheck.check(
      page: text, pagePath: "page.md", spec: SpecPageFixture.spec("recipient-postcode"))

    #expect(report.confirm == .required)
    #expect(report.verdict == .green)
  }

  @Test(
    "the captured page with a none slice and 417 words is RED on too-long and needs a confirm — catches a long page passing"
  )
  func capturedLongPage() throws {
    let report = try SpecPageCheck.check(
      page: SpecPageFixture.page("shipping-address"), pagePath: "shipping-address.page.txt",
      spec: SpecPageFixture.spec("shipping-address"))

    #expect(report.confirm == .required)
    #expect(report.verdict == .red)
    #expect(SpecPageFixture.ruleIDs(report) == ["spec-page.too-long", "spec-page.summary"])
    #expect(report.findings.first?.message.contains("417") == true)
  }

  @Test(
    "a page of 401 words is too-long and 1 of 400 is not — catches an off-by-one at the 400-word limit"
  )
  func wordLimit() throws {
    let page = try SpecPageFixture.page("recipient-postcode")
    #expect(SpecPageCheck.wordCount(page) == 398)
    let spec = try SpecPageFixture.spec("recipient-postcode")
    let at400 = try SpecPageFixture.replacing(
      "Any network call from the form.", with: "Any network call from the form, ever again.",
      in: page)
    let at401 = try SpecPageFixture.replacing(
      "Any network call from the form.", with: "Any network call from the form, not ever again.",
      in: page)

    let under = try SpecPageCheck.check(page: at400, pagePath: "page.md", spec: spec)
    let over = try SpecPageCheck.check(page: at401, pagePath: "page.md", spec: spec)

    #expect(SpecPageCheck.wordCount(at400) == 400)
    #expect(under.verdict == .green)
    #expect(SpecPageFixture.ruleIDs(over) == ["spec-page.too-long", "spec-page.summary"])
    #expect(over.findings.first?.message.contains("401") == true)
    #expect(over.verdict == .red)
  }

  @Test(
    "a quote with 1 changed word is quote-not-in-spec on its slice's line, naming the slice — catches a paraphrase passing as the spec's own line"
  )
  func changedWord() throws {
    let text = try SpecPageFixture.replacing(
      "and the next launch shows the saved values.\"",
      with: "and the next launch shows the stored values.\"",
      in: SpecPageFixture.page("recipient-postcode"))

    let report = try SpecPageCheck.check(
      page: text, pagePath: "page.md", spec: SpecPageFixture.spec("recipient-postcode"))

    #expect(
      SpecPageFixture.ruleIDs(report) == ["spec-page.quote-not-in-spec", "spec-page.summary"])
    let finding = try #require(report.findings.first)
    #expect(finding.line == 25)
    #expect(finding.file == "page.md")
    #expect(finding.message.contains("slice 3"))
    #expect(finding.message.contains("testSaveStoresAddressAndNextLaunchShowsIt"))
    #expect(finding.severity.failsGate)
    #expect(report.verdict == .red)
    #expect(report.confirm == .required)
  }

  @Test(
    "a malformed page has no parsed page and no confirm, and each problem is a format finding — catches a broken page read as skippable"
  )
  func malformedReport() throws {
    let text = try SpecPageFixture.replacing(
      "## Surface\n", with: "## Types\n", in: SpecPageFixture.page("recipient-postcode"))

    let report = try SpecPageCheck.check(
      page: text, pagePath: "page.md", spec: SpecPageFixture.spec("recipient-postcode"))

    #expect(report.page == nil)
    #expect(report.confirm == nil)
    #expect(report.verdict == .red)
    #expect(report.findings.dropLast().allSatisfy { $0.ruleID == "spec-page.format" })
    #expect(report.findings.count >= 2)
    #expect(report.findings.last?.ruleID == "spec-page.summary")
  }

  @Test(
    "the page sha is the lowercase hex SHA-256 of the page's bytes — catches a confirm bound to anything but the exact page"
  )
  func pageSha() throws {
    #expect(
      SpecPageCheck.pageSha(Data("abc".utf8))
        == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    #expect(
      SpecPageCheck.pageSha(try Fixture.data("spec-page/task-status.page.txt"))
        == "dbdc3a9cc390c6760e52ddfeeb8750d7fea2d1b3c9a595ab58b9e44db775aa5a")
  }
}

/// The verbatim rule's near misses, each decided on purpose.
@Suite("spec page quote match")
struct SpecPageQuoteTests {
  static let line =
    "A postcode that is not exactly 5 digits shows \"Enter a 5-digit postcode\" and Save stays disabled."

  @Test(
    "a quote of a spec line the spec file wraps over 2 lines appears — catches a wrapped acceptance line never matching"
  )
  func wrappedLine() throws {
    let spec = try SpecPageFixture.spec("recipient-postcode")
    #expect(spec.contains("Save stays\n   disabled."))

    #expect(SpecPageCheck.quoteAppears(Self.line, in: spec))
  }

  @Test(
    "near misses: a changed case, curly quotes, a cut word, an extra word and a changed number never appear where the exact line does — catches a loosened match letting a paraphrase skip the confirm",
    arguments: [
      "a postcode that is not exactly 5 digits shows \"Enter a 5-digit postcode\" and Save stays disabled.",
      "A postcode that is not exactly 5 digits shows “Enter a 5-digit postcode” and Save stays disabled.",
      "A postcode that is not exactly 5 digits shows \"Enter a 5-digit postcode\" and Save stays disab",
      "ostcode that is not exactly 5 digits shows \"Enter a 5-digit postcode\" and Save stays disabled.",
      "A postcode that is not exactly 5 digits shows \"Enter a 5-digit postcode\" and Save stays disabled now.",
      "A postcode that is not exactly 6 digits shows \"Enter a 5-digit postcode\" and Save stays disabled.",
    ])
  func nearMissesFail(_ quote: String) throws {
    let spec = try SpecPageFixture.spec("recipient-postcode")

    #expect(SpecPageCheck.quoteAppears(Self.line, in: spec))
    #expect(!SpecPageCheck.quoteAppears(quote, in: spec))
  }

  @Test(
    "near misses that stay verbatim: extra spaces, a dropped final period and a dropped whole last word appear — catches a match stricter than word for word",
    arguments: [
      "A postcode that is not  exactly 5 digits shows \"Enter a 5-digit postcode\" and Save stays disabled.",
      " A postcode that is not exactly 5 digits shows \"Enter a 5-digit postcode\" and Save stays disabled. ",
      "A postcode that is not exactly 5 digits shows \"Enter a 5-digit postcode\" and Save stays disabled",
      "A postcode that is not exactly 5 digits shows \"Enter a 5-digit postcode\" and Save stays",
    ])
  func verbatimNearMissesPass(_ quote: String) throws {
    let spec = try SpecPageFixture.spec("recipient-postcode")

    #expect(SpecPageCheck.quoteAppears(quote, in: spec))
  }

  @Test(
    "a quote of only whitespace never appears, where the text itself does — catches an empty quote matching every spec file"
  )
  func blankQuote() {
    #expect(SpecPageCheck.quoteAppears("anything", in: "anything"))
    #expect(!SpecPageCheck.quoteAppears("  ", in: "anything"))
  }

  @Test(
    "words count as wc -w counts them, over spaces, tabs and newlines — catches the limit measured in characters or lines"
  )
  func wordCount() {
    #expect(SpecPageCheck.wordCount("one two\tthree\n\nfour  five\n") == 5)
    #expect(SpecPageCheck.wordCount("") == 0)
  }
}
