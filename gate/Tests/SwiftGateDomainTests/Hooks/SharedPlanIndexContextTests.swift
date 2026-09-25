import Foundation
import SwiftGateDomain
import Testing

/// The shared-plan-index side of `SessionContext` (spec §6.3 rows 1 and 7): classifying the
/// common-dir `index.json`, the session id line skills read for `plan claim`, and the plan-list
/// overflow count. The CLI-level wiring (git resolution, worktree sharing, the legacy
/// `.harness/plans/index.json` no longer being read) is covered in `HookCommandTests`.
@Suite("Shared plan index context")
struct SharedPlanIndexContextTests {
  @Test(
    "no index bytes at all degrades silently to no active plans — catches a missing common dir or a plan index that hasn't been created yet blocking a session"
  )
  func resolvesToNoneWithoutBytes() {
    #expect(SessionContext.resolvePlans(indexData: nil) == .none)
  }

  @Test(
    "bytes that fail to decode as an index surface a short note instead of silently dropping every plan — catches a corrupt shared index hiding real plan state"
  )
  func resolvesToUnreadableOnCorruptBytes() {
    guard
      case .unreadable(let reason) = SessionContext.resolvePlans(indexData: Data("not json".utf8))
    else {
      Issue.record("expected .unreadable")
      return
    }
    #expect(!reason.isEmpty)

    let text = SessionContext.render(
      SessionContext.Inputs(
        projectName: "SampleApp", modules: [], xcode: nil,
        plans: .unreadable(reason), notes: []))
    #expect(text.contains("shared plan index is unreadable"))
  }

  @Test(
    "valid but empty index bytes decode to an explicit empty plan list, not a note — catches an empty index misreported as unreadable"
  )
  func resolvesToActiveEmptyList() {
    let plans = SessionContext.resolvePlans(indexData: Data(#"{"plans": []}"#.utf8))
    #expect(plans == .active([]))
  }

  @Test(
    "PlanIndex.encode() round-trips through PlanIndex.decode() — catches an encoder/decoder mismatch corrupting the shared index that `index set` writes"
  )
  func encodeRoundTrips() throws {
    let index = PlanIndex(plans: [
      PlanSummary(slug: "2026-09-24-feed", status: "active", resume: "Next: T3."),
      PlanSummary(slug: "2026-09-01-old", status: "done", resume: nil),
    ])

    let decoded = try PlanIndex.decode(try index.encode())

    #expect(decoded == index)
  }

  @Test(
    "PlanIndex.encode() output is stable — catches a non-deterministic encode turning index.json into a spurious diff on every write"
  )
  func encodeIsDeterministic() throws {
    let index = PlanIndex(plans: [
      PlanSummary(slug: "b-plan", status: "active", resume: "B"),
      PlanSummary(slug: "a-plan", status: "active", resume: "A"),
    ])
    #expect(try index.encode() == index.encode())
  }

  @Test(
    "superseded and abandoned plans drop out of the active list — catches the closed PlanStatus set failing to retire terminal plans"
  )
  func supersededAndAbandonedAreNotActive() {
    let index = PlanIndex(plans: [
      PlanSummary(slug: "still-going", status: "building", resume: nil),
      PlanSummary(slug: "replaced", status: "superseded", resume: nil),
      PlanSummary(slug: "dropped", status: "abandoned", resume: nil),
    ])
    #expect(index.active.map(\.slug) == ["still-going"])
  }

  @Test(
    "a legacy status outside the closed PlanStatus set stays listed as active — catches a bad or pre-migration entry silently disappearing instead of staying visible"
  )
  func legacyStatusStaysActive() {
    let index = PlanIndex(plans: [
      PlanSummary(slug: "old-entry", status: "complete", resume: nil)
    ])
    #expect(index.active.map(\.slug) == ["old-entry"])
  }

  @Test(
    "the session id appears in the injected context so a skill can pass it to `plan claim` — catches skills unable to identify their own session"
  )
  func rendersSessionID() {
    let text = SessionContext.render(
      SessionContext.Inputs(
        projectName: "SampleApp", sessionID: "8f2c1d7e-5b4a-4c1e-9d3f-2a6b7c8d9e0f", modules: [],
        xcode: nil, plans: .none, notes: []))
    #expect(text.contains("Session id: 8f2c1d7e-5b4a-4c1e-9d3f-2a6b7c8d9e0f"))
    #expect(text.contains("plan claim"))
  }

  @Test(
    "an empty session id is never rendered — catches a placeholder session id leaking into context when the caller has none to report"
  )
  func omitsEmptySessionID() {
    let text = SessionContext.render(
      SessionContext.Inputs(
        projectName: "SampleApp", modules: [], xcode: nil, plans: .none, notes: []))
    #expect(!text.contains("Session id"))
  }

  @Test(
    "200 active plans render under the context budget with an explicit overflow count instead of a mid-line cut — catches a large shared index blowing the SessionStart budget or silently truncating the plan list"
  )
  func capsPlanListWithOverflowCount() {
    let plans = (0..<200).map {
      PlanSummary(
        slug: "2026-09-\(String(format: "%02d", $0 % 28 + 1))-plan-\($0)", status: "active",
        resume: "Next: wire task \($0) and update the ledger before merging the wave.")
    }

    let text = SessionContext.render(
      SessionContext.Inputs(
        projectName: "SampleApp", modules: [], xcode: nil, plans: .active(plans), notes: []))

    #expect(text.count < SessionContext.maxCharacters)
    #expect(text.contains("more active plan"))
    #expect(text.contains(plans[0].slug))
    #expect(!text.contains(plans[199].slug))
  }

  @Test(
    "a plan list that fits comfortably renders with no overflow count — catches an overflow line appearing when nothing was actually dropped"
  )
  func noOverflowCountWhenEverythingFits() {
    let plans = [
      PlanSummary(slug: "2026-09-24-feed", status: "active", resume: "Next: T3."),
      PlanSummary(slug: "2026-09-23-search", status: "active", resume: "Next: T1."),
    ]

    let text = SessionContext.render(
      SessionContext.Inputs(
        projectName: "SampleApp", modules: [], xcode: nil, plans: .active(plans), notes: []))

    #expect(!text.contains("more active plan"))
    #expect(text.contains("2026-09-24-feed"))
    #expect(text.contains("2026-09-23-search"))
  }
}
