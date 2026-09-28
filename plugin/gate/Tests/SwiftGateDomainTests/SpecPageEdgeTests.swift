import Foundation
import SwiftGateDomain
import Testing

/// The smallest page the format allows: 1 module, 1 bullet each, 1 slice.
enum MinimalSpecPage {
  static let text = """
    # T

    Spec: s.md

    ## Goal
    Do it.

    ## Modules
    | Module | Kind | Owns | Depends on |
    |---|---|---|---|
    | AppCore | feature | state | none |

    ## Surface
    - `A`: b

    ## Slices
    1. Adds a. Test: `aWorks`: a works. Spec: none

    ## Out of scope
    - c
    """

  static func with(_ target: String, _ replacement: String) throws -> String {
    try SpecPageFixture.replacing(target, with: replacement, in: text)
  }

  static func problems(_ text: String) -> [SpecPageProblem] {
    SpecPageFixture.problems(text)
  }
}

@Suite("spec page parse edges")
struct SpecPageParseEdgeTests {
  @Test(
    "a page with 1 module row, 1 bullet per list and 1 slice parses — catches a table that needs 2 module rows"
  )
  func minimalPageParses() throws {
    let page = try SpecPageFixture.parsed(MinimalSpecPage.text)

    #expect(page.modules.map(\.name) == ["AppCore"])
    #expect(page.surface == ["`A`: b"])
    #expect(page.outOfScope == ["c"])
    #expect(page.slices.map(\.id) == ["slice-1-a-works"])
  }

  @Test(
    "an empty page reports no title and every missing section, in section order — catches a scan past the last line or an unstable problem order"
  )
  func emptyPage() {
    let messages = MinimalSpecPage.problems("").map(\.message)

    #expect(
      messages == [
        "the page has no title; its first line is `# <title>`",
        "the page has no `Spec: <spec-file>` line under its title",
        "the page has no `## Goal` section",
        "the page has no `## Modules` section",
        "the page has no `## Surface` section",
        "the page has no `## Slices` section",
        "the page has no `## Out of scope` section",
      ])
  }

  @Test(
    "a page of only a title and a Spec: line reports the 5 missing sections — catches a scan past the last line"
  )
  func titleOnly() {
    let problems = MinimalSpecPage.problems("# T\nSpec: s.md")

    #expect(problems.count == 5)
    #expect(problems.allSatisfy { $0.line == nil })
    #expect(problems.first?.message == "the page has no `## Goal` section")
  }

  @Test(
    "a first line that isn't `# <title>`, or a `# ` with no title, is a problem on line 1 — catches a page read with no title"
  )
  func badTitle() throws {
    for first in ["# ", "Title"] {
      let problems = MinimalSpecPage.problems(try MinimalSpecPage.with("# T\n", first + "\n"))

      #expect(problems.map(\.line) == [1], "\(first)")
      #expect(
        problems.first?.message == "the page's first line must be its title, `# <title>`")
    }
  }

  @Test(
    "a page that opens on `## Goal` has no title and no Spec: line — catches a missing title passing silently"
  )
  func opensOnSection() throws {
    let text = try MinimalSpecPage.with("# T\n\nSpec: s.md\n\n", "")

    let messages = MinimalSpecPage.problems(text).map(\.message)

    #expect(
      messages == [
        "the page has no title; its first line is `# <title>`",
        "the page has no `Spec: <spec-file>` line under its title",
      ])
  }

  @Test(
    "a second Spec: line, or a Spec: naming nothing, is a problem on its line — catches a page naming 2 spec files or none"
  )
  func badSpecLine() throws {
    let twice = try MinimalSpecPage.with("Spec: s.md\n", "Spec: s.md\nSpec: t.md\n")
    let blank = try MinimalSpecPage.with("Spec: s.md\n", "Spec:   \n")

    #expect(MinimalSpecPage.problems(twice).map(\.line) == [4])
    #expect(
      MinimalSpecPage.problems(blank).map(\.message) == [
        "the page has no `Spec: <spec-file>` line under its title",
        "only 1 `Spec: <spec-file>` line goes between the title and `## Goal`",
      ])
  }

  @Test("a section given twice is a problem on the second — catches 2 goals merged silently")
  func repeatedSection() throws {
    let text = try MinimalSpecPage.with("## Out of scope\n", "## Goal\nAgain.\n\n## Out of scope\n")

    let problems = MinimalSpecPage.problems(text)

    #expect(problems.map(\.line) == [19])
    #expect(problems.first?.message == "`## Goal` appears twice")
  }

  @Test("an empty goal is a problem on its heading — catches a page that says nothing it builds")
  func emptyGoal() throws {
    let problems = MinimalSpecPage.problems(try MinimalSpecPage.with("Do it.\n", ""))

    #expect(problems.map(\.line) == [5])
    #expect(problems.first?.message == "`## Goal` is empty")
  }

  @Test(
    "modules written as a list, or a module row of 3 cells, are problems on their lines — catches a modules section read as empty"
  )
  func badModules() throws {
    let list = try MinimalSpecPage.with(
      "| Module | Kind | Owns | Depends on |\n|---|---|---|---|\n| AppCore | feature | state | none |",
      "- AppCore: feature")
    let short = try MinimalSpecPage.with(
      "| AppCore | feature | state | none |", "| AppCore | feature | state |")

    #expect(MinimalSpecPage.problems(list).map(\.line) == [8])
    #expect(
      MinimalSpecPage.problems(short).map(\.message) == [
        "a module row has 4 cells: module, kind, owns, depends on"
      ])
    #expect(MinimalSpecPage.problems(short).map(\.line) == [11])
  }

  @Test(
    "an indented line continues the bullet above it, and `* ` starts a bullet — catches a wrapped surface entry read as a problem"
  )
  func bulletContinuation() throws {
    var text = try MinimalSpecPage.with("- `A`: b\n", "* `A`: b\n  and more\n")
    text = try SpecPageFixture.replacing("- c", with: "- c\n\td", in: text)

    let page = try SpecPageFixture.parsed(text)

    #expect(page.surface == ["`A`: b and more"])
    #expect(page.outOfScope == ["c d"])
  }

  @Test(
    "a line in a list section that isn't a bullet or a continuation is 1 problem on its line — catches prose hidden in the surface"
  )
  func proseInList() throws {
    let prose = try MinimalSpecPage.with("- `A`: b\n", "- `A`: b\nThe rest.\n")
    let onlyProse = try MinimalSpecPage.with("- `A`: b\n", "The rest.\n")
    let indentedFirst = try MinimalSpecPage.with("- `A`: b\n", "  The rest.\n")

    for (text, line) in [(prose, 15), (onlyProse, 14), (indentedFirst, 14)] {
      let problems = MinimalSpecPage.problems(text)
      #expect(problems.map(\.line) == [line])
      #expect(problems.map(\.message) == ["`## Surface` holds only `- ` bullets"])
    }
  }

  @Test("an empty list section is a problem on its heading — catches an out of scope left blank")
  func emptyList() throws {
    let problems = MinimalSpecPage.problems(
      try MinimalSpecPage.with("## Out of scope\n- c", "## Out of scope\n"))

    #expect(problems.map(\.line) == [19])
    #expect(problems.first?.message == "`## Out of scope` lists nothing")
  }

  @Test(
    "an indented line continues the slice above it, keeping its test and quote — catches a wrapped slice losing its Spec:"
  )
  func sliceContinuation() throws {
    let wrapped = try MinimalSpecPage.with("a works. Spec: none", "a works.\n   Spec: none")
    let page = try SpecPageFixture.parsed(wrapped)

    #expect(page.slices.map(\.spec) == [.none])
    #expect(page.slices.map(\.testName) == ["aWorks"])
  }

  @Test(
    "a slices section with prose, or with no slice, is a problem — catches a slice list that builds nothing"
  )
  func badSlices() throws {
    let prose = try MinimalSpecPage.with("Spec: none\n", "Spec: none\nThe rest.\n")
    let empty = try MinimalSpecPage.with(
      "1. Adds a. Test: `aWorks`: a works. Spec: none\n", "")

    #expect(MinimalSpecPage.problems(prose).map(\.line) == [18])
    #expect(
      MinimalSpecPage.problems(prose).map(\.message) == [
        "`## Slices` holds only numbered slices, `1. …`"
      ])
    #expect(MinimalSpecPage.problems(empty).map(\.message) == ["`## Slices` lists no slice"])
    #expect(MinimalSpecPage.problems(empty).map(\.line) == [16])
  }

  @Test(
    "a test name with no letter or digit is a problem — catches a slice id of `slice-1-`"
  )
  func unnamedTest() throws {
    let problems = MinimalSpecPage.problems(try MinimalSpecPage.with("`aWorks`", "`!!`"))

    #expect(problems.map(\.message) == ["slice 1's test name `!!` has no letter or digit"])
  }

  @Test(
    "Tier: T3 before Spec: with no period, or T2 with a comma, sets the tier, and 2 Tier: tokens are a problem — catches a tier token read only with a period"
  )
  func tierPunctuation() throws {
    let bare = try MinimalSpecPage.with("a works. Spec:", "a works. Tier: T3 Spec:")
    let comma = try MinimalSpecPage.with("a works. Spec:", "a works. Tier: T2, Spec:")
    let twice = try MinimalSpecPage.with("a works. Spec:", "a works. Tier: T2. Tier: T3. Spec:")

    #expect(try SpecPageFixture.parsed(bare).slices.map(\.tier) == [.t3])
    #expect(try SpecPageFixture.parsed(comma).slices.map(\.tier) == [.t2])
    #expect(
      MinimalSpecPage.problems(twice).map(\.message) == [
        "slice 1 says `Tier:` 2 times; say it once or not at all"
      ])
  }

  @Test(
    "a page saved with CRLF line ends parses as its LF copy does — catches a page from a Windows editor refused"
  )
  func crlfPage() throws {
    let crlf = MinimalSpecPage.text.replacingOccurrences(of: "\n", with: "\r\n")

    #expect(try SpecPageFixture.parsed(crlf) == SpecPageFixture.parsed(MinimalSpecPage.text))
  }

  @Test(
    "a name ending in an uppercase run keeps it as 1 word — catches a read past the name's end"
  )
  func kebabTrailingCapitals() {
    #expect(SpecPage.kebabCase("loadsURL") == "loads-url")
    #expect(SpecPage.kebabCase("savesX") == "saves-x")
  }
}

@Suite("spec page check edges")
struct SpecPageCheckEdgeTests {
  @Test(
    "a malformed page of 400 words has no too-long finding, and one of 401 has 1 — catches an off-by-one on a page that breaks the format"
  )
  func malformedWordLimit() throws {
    let page = try SpecPageFixture.page("recipient-postcode")
    let spec = try SpecPageFixture.spec("recipient-postcode")
    let broken = try SpecPageFixture.replacing("## Surface\n", with: "## Types\n", in: page)
    let at400 = try SpecPageFixture.replacing(
      "Any network call from the form.", with: "Any network call from the form, ever again.",
      in: broken)
    let at401 = try SpecPageFixture.replacing(
      "Any network call from the form.", with: "Any network call from the form, not ever again.",
      in: broken)

    let under = try SpecPageCheck.check(page: at400, pagePath: "page.md", spec: spec)
    let over = try SpecPageCheck.check(page: at401, pagePath: "page.md", spec: spec)

    #expect(SpecPageCheck.wordCount(at400) == 400)
    #expect(Set(SpecPageFixture.ruleIDs(under)) == ["spec-page.format", "spec-page.summary"])
    #expect(SpecPageFixture.ruleIDs(over).filter { $0 == "spec-page.too-long" }.count == 1)
    #expect(SpecPageFixture.ruleIDs(over).contains("spec-page.format"))
  }

  @Test(
    "a quote whose first match sits inside a word still appears at a later clean match — catches a search that stops at the first match"
  )
  func laterCleanMatch() {
    #expect(SpecPageCheck.quoteAppears("cat", in: "concatenate the cat"))
    #expect(!SpecPageCheck.quoteAppears("cat", in: "concatenate the cats"))
  }

  @Test(
    "a quote cut inside a number or a snake_case name never appears, where the whole one does — catches digits or underscores read as word breaks"
  )
  func digitsAndUnderscoresAreWord() {
    #expect(SpecPageCheck.quoteAppears("90210", in: "such as 90210."))
    #expect(!SpecPageCheck.quoteAppears("0210", in: "such as 90210."))
    #expect(SpecPageCheck.quoteAppears("snake_case", in: "use snake_case here"))
    #expect(!SpecPageCheck.quoteAppears("case", in: "use snake_case here"))
    #expect(!SpecPageCheck.quoteAppears("snake", in: "use snake_case here"))
  }
}
