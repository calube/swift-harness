import Foundation
import SwiftGateDomain
import Testing

@Suite("Session context")
struct SessionContextTests {
  @Test(
    "an Xcode that differs from the pin is called out — catches sessions building with the wrong toolchain unnoticed"
  )
  func xcodePin() {
    #expect(XcodePin.matches(pinned: "26.2", selected: "26.2"))
    #expect(XcodePin.matches(pinned: "26.2", selected: "26.2.1"))
    #expect(!XcodePin.matches(pinned: "26.2", selected: "26.20"))
    #expect(!XcodePin.matches(pinned: "26.2", selected: "26.1"))

    let text = SessionContext.render(
      SessionContext.Inputs(
        projectName: "SampleApp", modules: [],
        xcode: .selected(
          pinned: "26.2", version: "26.1",
          developerDirectory: "/Applications/Xcode-26.1.app/Contents/Developer"),
        plans: .none, notes: []))
    #expect(text.contains("MISMATCH"))
    #expect(text.contains("26.1"))
  }

  @Test(
    "lists active plans with their RESUME summary only, capped — catches whole ledgers or finished plans flooding context"
  )
  func plans() throws {
    let index = """
      {"plans": [
        {"slug": "2026-09-24-feed", "status": "building", "resume": "Next: T3 wire the feed client.", "ledger": {"huge": true}},
        {"slug": "2026-09-01-old", "status": "done", "resume": "finished"},
        {"slug": "2026-09-20-long", "status": "in-review", "resume": "\(String(repeating: "x", count: 5000))"}
      ]}
      """
    let summaries = try PlanIndex.decode(Data(index.utf8)).active
    #expect(summaries.map(\.slug) == ["2026-09-24-feed", "2026-09-20-long"])

    let text = SessionContext.render(
      SessionContext.Inputs(
        projectName: "SampleApp", modules: [], xcode: .unknown(pinned: "26.2", reason: "x"),
        plans: .active(summaries), notes: []))
    #expect(text.contains("2026-09-24-feed (building): Next: T3 wire the feed client."))
    #expect(!text.contains("2026-09-01-old"))
    #expect(!text.contains("huge"))
    #expect(text.count < SessionContext.maxCharacters)
  }

  @Test("groups modules by package with role and kind — catches an unreadable module map")
  func moduleMap() {
    let text = SessionContext.render(
      SessionContext.Inputs(
        projectName: "SampleApp",
        modules: [
          .init(package: "CounterFeature", name: "CounterCore", role: "core", kind: "feature"),
          .init(package: "CounterFeature", name: "CounterUI", role: "ui", kind: "feature"),
          .init(package: "GameEngine", name: "GameEngine", role: "core", kind: "engine"),
        ],
        xcode: .selected(pinned: "26.2", version: "26.2", developerDirectory: "/X"), plans: .none,
        notes: []))
    #expect(text.contains("CounterFeature: CounterCore (core, feature), CounterUI (ui, feature)"))
    #expect(text.contains("GameEngine: GameEngine (core, engine)"))
    #expect(!text.contains("MISMATCH"))
  }
}
