import Foundation
import SwiftGateDomain
import Testing

@Suite("plan.json source: a design or a spec page")
struct PlanFileSourceTests {
  static let fixturesRoot = URL(filePath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "Fixtures/PlanState", directoryHint: .isDirectory)

  static let at = Date(timeIntervalSince1970: 1_790_236_800)

  static func specPagePlan(
    pageSha: String? = "9b1e", approval: PlanFile.PageApproval? = nil,
    surfaceCommit: String? = nil
  ) -> PlanFile {
    PlanFile(
      schemaVersion: 1, slug: "2026-09-28-reading-list",
      source: .specPage(
        PlanFile.SpecPageSource(
          path: PlanFile.SpecPageSource.fileName, pageSha: pageSha, approval: approval)),
      surfaceCommit: surfaceCommit, resume: "framing")
  }

  static func text(_ plan: PlanFile) throws -> String {
    String(decoding: try PlanFileJSON.encode(plan), as: UTF8.self)
  }

  static func decodingError(_ text: String) -> String? {
    do {
      _ = try PlanFileJSON.decode(Data(text.utf8))
      return nil
    } catch {
      return String(describing: error)
    }
  }

  @Test(
    "every captured schema-1 plan.json decodes as a design plan and keeps every field when it gains a surface commit — catches a break to live plans",
    arguments: [
      ("claim-seeded.json", "docs/reading/designs/reading-list.md", nil),
      ("plan-set-tier-and-resume.json", "docs/search/designs/saved-search.md", DesignTier.deep),
    ] as [(String, String, DesignTier?)])
  func capturedPlansDecode(file: String, design: String, tier: DesignTier?) throws {
    let data = try Data(contentsOf: Self.fixturesRoot.appending(path: file))
    let plan = try PlanFileJSON.decode(data)
    let source = try #require(plan.designSource)
    #expect(source.design == design)
    #expect(source.tier == tier)
    #expect(source.designSha == nil)
    #expect(plan.specPageSource == nil)
    #expect(plan.surfaceCommit == nil)

    let surfaced = PlanFile(
      schemaVersion: plan.schemaVersion, slug: plan.slug, source: plan.source,
      surfaceCommit: "4d9a0c2", resume: plan.resume)
    #expect(try PlanFileJSON.decode(try PlanFileJSON.encode(surfaced)) == surfaced)
  }

  @Test(
    "a spec-page plan with a confirmation and a surface commit round-trips byte-stable under fixed keys — catches a spec-page plan read back as a design plan or losing its page sha"
  )
  func specPageRoundTrips() throws {
    for by in PlanFile.PageApprover.allCases {
      let plan = Self.specPagePlan(
        approval: PlanFile.PageApproval(pageSha: "9b1e", by: by, at: Self.at),
        surfaceCommit: "4d9a0c2")
      let first = try PlanFileJSON.encode(plan)
      let decoded = try PlanFileJSON.decode(first)
      #expect(decoded == plan)
      #expect(try PlanFileJSON.encode(decoded) == first)

      let object = try #require(
        try JSONSerialization.jsonObject(with: first) as? [String: Any])
      #expect(object["source"] as? String == "specPage")
      #expect(object["surfaceCommit"] as? String == "4d9a0c2")
      #expect(object["design"] == nil)
      let page = try #require(object["specPage"] as? [String: Any])
      #expect(page["path"] as? String == "spec-page.md")
      #expect(page["pageSha"] as? String == "9b1e")
      let approval = try #require(object["approval"] as? [String: Any])
      #expect(approval["by"] as? String == by.rawValue)
      #expect(approval["pageSha"] as? String == "9b1e")
    }
  }

  @Test(
    "a spec page with no pageSha reads as nil and its plan has no design — catches an unhashed page read as an empty sha"
  )
  func absentPageShaIsNil() throws {
    let text = try Self.text(Self.specPagePlan(pageSha: nil))
    #expect(!text.contains("pageSha"))
    let decoded = try PlanFileJSON.decode(Data(text.utf8))
    let page = try #require(decoded.specPageSource)
    #expect(page.pageSha == nil)
    #expect(page.approval == nil)
    #expect(decoded.designSource == nil)
  }

  @Test(
    "an unknown source kind or confirmer fails decoding and names the value — catches a plan of an unknown kind read as a design plan or a page read as confirmed"
  )
  func unknownValuesNameThemselves() throws {
    let confirmed = try Self.text(
      Self.specPagePlan(
        approval: PlanFile.PageApproval(pageSha: "9b1e", by: .specQuotes, at: Self.at)))

    let source = Self.decodingError(
      confirmed.replacingOccurrences(
        of: "\"source\" : \"specPage\"", with: "\"source\" : \"sprintPage\""))
    #expect(source?.contains("sprintPage") == true, "\(source ?? "decoded")")

    let designSource = Self.decodingError(
      try Self.text(
        PlanFile(
          schemaVersion: 1, slug: "a", design: "docs/a/designs/a.md", designSha: nil,
          approval: nil, clarifyChain: [], tier: nil, resume: "framing")
      )
      .replacingOccurrences(
        of: "\"schemaVersion\"", with: "\"source\" : \"desgin\",\n  \"schemaVersion\""))
    #expect(designSource?.contains("desgin") == true, "\(designSource ?? "decoded")")

    let by = Self.decodingError(
      confirmed.replacingOccurrences(of: "\"spec-quotes\"", with: "\"spec-quote\""))
    #expect(by?.contains("spec-quote") == true, "\(by ?? "decoded")")
  }

  @Test(
    "a plan carrying keys of the other source fails decoding naming the key — catches a spec-page plan that also names a design, or a design plan that also names a page"
  )
  func mixedSourcesFail() throws {
    let page = try Self.text(Self.specPagePlan())
    let withDesign = Self.decodingError(
      page.replacingOccurrences(
        of: "\"schemaVersion\"", with: "\"design\" : \"docs/a/designs/a.md\",\n  \"schemaVersion\"")
    )
    #expect(withDesign?.contains("design") == true, "\(withDesign ?? "decoded")")
    let withTier = Self.decodingError(
      page.replacingOccurrences(
        of: "\"schemaVersion\"", with: "\"tier\" : \"quick\",\n  \"schemaVersion\""))
    #expect(withTier?.contains("tier") == true, "\(withTier ?? "decoded")")

    let design = try Self.text(
      PlanFile(
        schemaVersion: 1, slug: "a", design: "docs/a/designs/a.md", designSha: nil,
        approval: nil, clarifyChain: [], tier: nil, resume: "framing"))
    let withPage = Self.decodingError(
      design.replacingOccurrences(
        of: "\"schemaVersion\"",
        with: "\"specPage\" : {\"path\" : \"spec-page.md\"},\n  \"schemaVersion\""))
    #expect(withPage?.contains("specPage") == true, "\(withPage ?? "decoded")")
  }

  @Test(
    "a spec page path that leaves the plan's directory or isn't a Markdown file fails decoding naming it — catches plan.json pointing the page at another plan's files",
    arguments: [
      "../other/spec-page.md", "notes/spec-page.md", "/tmp/spec-page.md", "spec-page.txt", ".md",
      "",
    ])
  func pagePathStaysInThePlan(path: String) throws {
    let text = try Self.text(Self.specPagePlan())
      .replacingOccurrences(of: "\"spec-page.md\"", with: "\"\(path)\"")
    let error = Self.decodingError(text)
    #expect(error?.contains("spec page path") == true, "\(error ?? "decoded")")
  }

  @Test("the spec-page seed names the page in the plan's directory with nothing hashed yet")
  func seedSpecPage() throws {
    let seed = PlanFile.seedSpecPage(slug: "2026-09-28-reading-list")
    let page = try #require(seed.specPageSource)
    #expect(page.path == "spec-page.md")
    #expect(page.pageSha == nil)
    #expect(page.approval == nil)
    #expect(seed.surfaceCommit == nil)
    #expect(try PlanFileJSON.decode(try PlanFileJSON.encode(seed)) == seed)
  }
}

@Suite("plan.json writes to a spec-page plan")
struct SpecPagePlanFileGuardTests {
  static let design = "/r/docs/feed/designs/offline.md"

  static func plans(current: PlanStateGuard.PlanRecord.Design) -> [PlanStateGuard.PlanRecord] {
    [PlanStateGuard.PlanRecord(name: "page", lock: "session-a", design: current)]
  }

  static func judge(
    writing written: PlanStateGuard.WrittenDesign, over current: PlanStateGuard.PlanRecord.Design
  ) -> GuardViolation? {
    PlanStateGuard.evaluatePlanFile(
      of: "page", writing: written, plans: plans(current: current), environmentValue: nil,
      agentID: nil)
  }

  @Test(
    "a spec-page plan's plan.json may be rewritten as a spec-page plan but never given a design, and a design plan's never turned into a spec-page plan — catches a holder taking a design through a spec-page plan, or dropping one"
  )
  func sourceKindIsFixed() {
    #expect(Self.judge(writing: .specPage, over: .specPage) == nil)
    #expect(Self.judge(writing: .specPage, over: .unreadable) == nil)

    let gainsDesign = Self.judge(writing: .named(Self.design), over: .specPage)
    #expect(gainsDesign?.ruleID == EditGuard.planStateRuleID)
    #expect(gainsDesign?.reason.contains("spec-page plan") == true)

    let losesDesign = Self.judge(writing: .specPage, over: .named(Self.design))
    #expect(losesDesign?.ruleID == EditGuard.planStateRuleID)
    #expect(losesDesign?.reason.contains(Self.design) == true)
  }
}
