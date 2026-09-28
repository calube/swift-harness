import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

/// `Fixtures/ledger-page/` holds a design plan's ledger page as `design-render --ledger` wrote it
/// before a plan could come from a spec page, with the ledger it was rendered from; its README
/// records the capture.
@Suite("Design render — a spec-page plan's ledger page")
struct LedgerRenderSpecPageTests {
  static let slug = "queue-plan"

  static func specPage() throws -> SpecPage {
    switch SpecPage.parse(try Fixture.text("spec-page/task-status.page.txt")) {
    case .parsed(let page): return page
    case .malformed(let problems): throw Unparsed(problems: problems)
    }
  }

  struct Unparsed: Error {
    let problems: [SpecPageProblem]
  }

  static func task(id: String, deps: [String] = [], covers: [String]) -> LedgerTask {
    LedgerTask(
      id: id, deps: deps, writeSet: ["Sample/Sources/\(id)/"], gate: .fast, tests: [],
      covers: covers, estLines: 40, status: .pending, worktree: "../app-\(id)")
  }

  /// The `<tr …>` element whose attributes hold `attribute`.
  static func row(_ attribute: String, in html: String) throws -> Substring {
    let start = try #require(html.range(of: attribute), "no row carries \(attribute)")
    let end = try #require(html[start.upperBound...].range(of: "</tr>"))
    return html[start.lowerBound..<end.upperBound]
  }

  /// `html` with the revision chip and the coverage section cut out, so two pages rendered from
  /// the same ledger compare equal everywhere their source doesn't reach.
  static func withoutSource(_ html: String, revision: String) throws -> String {
    var text = html.replacingOccurrences(of: revision, with: "REVISION")
    text = text.replacingOccurrences(of: String(revision.prefix(10)), with: "REVISION")
    let heading = try #require(
      text.range(of: "<h2>Requirement × task coverage</h2>")
        ?? text.range(of: "<h2>Slice × task coverage</h2>"),
      "no coverage section")
    let open = try #require(text[..<heading.lowerBound].range(of: "<section", options: .backwards))
    let close = try #require(text[heading.upperBound...].range(of: "</section>"))
    text.replaceSubrange(open.lowerBound..<close.upperBound, with: "COVERAGE")
    return text
  }

  @Test(
    "a spec-page plan's page has a row per slice naming its test and tier, marks the task that covers it, and shows a slice no task covers as a gap — catches rendering an empty matrix"
  )
  func sliceMatrixShowsEachSlice() throws {
    let page = try Self.specPage()
    let ids = page.slices.map(\.id)
    try #require(ids.count == 4)
    let tasks = [
      Self.task(id: "task-a", covers: [ids[0], ids[1]]),
      Self.task(id: "task-b", deps: ["task-a"], covers: [ids[2]]),
    ]
    let ledger = Ledger(
      schemaVersion: 1, resume: "planned", maxParallel: 3, tasks: tasks,
      waves: [["task-a"], ["task-b"]])
    let html = LedgerRender.page(
      .init(slug: Self.slug, ledger: ledger, source: .specPage(page, pageSha: "ab12cd34ef567890"))
    ).html

    #expect(html.contains("<h2>Slice × task coverage</h2>"))
    #expect(!html.contains("Requirement × task coverage"))
    #expect(html.contains("Revision ab12cd34ef"))
    #expect(html.contains("<th>task-a</th><th>task-b</th>"), "the head names each task in order")
    for (slice, expected) in zip(
      page.slices, [["Covered", ""], ["Covered", ""], ["", "Covered"]])
    {
      let row = try Self.row("data-slice=\"\(slice.id)\"", in: html)
      #expect(row.contains("\(slice.number). \(slice.testName)"), "\(row)")
      #expect(row.contains("T1"), "\(row)")
      #expect(row.contains(expected.map { "<td>\($0)</td>" }.joined()), "\(row)")
      #expect(row.contains("data-gap=\"false\""), "\(row)")
    }
    let gap = try Self.row("data-slice=\"\(ids[3])\"", in: html)
    #expect(gap.contains("<td></td><td></td>"), "\(gap)")
    #expect(gap.contains("data-gap=\"true\""), "\(gap)")
    #expect(gap.contains("Gap: no task covers this"), "\(gap)")
    #expect(!html.contains(">\(ids[0])<"), "a slice id reaches the page only in data- attributes")
  }

  @Test(
    "a slice's Tier: T3 shows on its row — catches every slice rendered at the default tier"
  )
  func sliceTierShown() throws {
    let text = try Fixture.text("spec-page/task-status.page.txt")
    let marker = "Spec: \"Undo reverts"
    try #require(text.contains(marker))
    guard
      case .parsed(let page) = SpecPage.parse(
        text.replacingOccurrences(of: marker, with: "Tier: T3. " + marker))
    else {
      Issue.record("the page with a tier no longer parses")
      return
    }
    let html = LedgerRender.page(
      .init(
        slug: Self.slug,
        ledger: Ledger(schemaVersion: 1, resume: "planned", maxParallel: 3, tasks: [], waves: []),
        source: .specPage(page, pageSha: "ab12cd34ef567890"))
    ).html
    let last = try #require(page.slices.last)
    #expect(try Self.row("data-slice=\"\(last.id)\"", in: html).contains("T3"))
    let first = try #require(page.slices.first)
    #expect(!(try Self.row("data-slice=\"\(first.id)\"", in: html).contains("T3")))
  }

  @Test(
    "a design plan's page is byte-identical to the one captured before spec pages, and the same ledger from a spec page differs only in its revision and coverage section — catches the source switch changing the design page or the rest of a spec-page plan's page"
  )
  func designPageUnchangedAndSpecPageSwapsOnlyCoverage() throws {
    let designText = try Fixture.text("DesignSha/lf-proposed.md")
    let designSha = DesignSha.of(designText)
    let ledger = try LedgerJSON.decode(try Fixture.data("ledger-page/ledger.json"))
    let design = LedgerRender.page(
      .init(
        slug: Self.slug, ledger: ledger, design: DesignDocument(markdown: .parse(designText)),
        designSha: designSha)
    ).html
    #expect(design == (try Fixture.text("ledger-page/design-plan-ledger.html")))

    let page = try Self.specPage()
    let pageSha = "ab12cd34ef567890ab12cd34ef567890"
    let fromPage = LedgerRender.page(
      .init(slug: Self.slug, ledger: ledger, source: .specPage(page, pageSha: pageSha))
    ).html
    #expect(
      try Self.withoutSource(fromPage, revision: pageSha)
        == (try Self.withoutSource(design, revision: designSha)))
    #expect(fromPage.components(separatedBy: "data-slice=").count - 1 == page.slices.count)
  }
}
