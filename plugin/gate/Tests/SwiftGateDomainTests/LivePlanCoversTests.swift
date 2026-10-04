import Foundation
import SwiftGateDomain
import Testing

/// A plan with 2 requirements, each covered by 1 of its 2 tasks; `covers` replaces the second
/// task's `Covers:` line.
private func plan(secondCovers covers: String = "req-offline-save") -> String {
  """
  # Offline drafts

  ## Requirements
  - req-draft-list: Show every saved draft
  - `req-offline-save`: Save a draft without a network,
    and keep it until it syncs

  ## Assumptions
  - A draft syncs on the next launch with a network.

  ### draft-list
  List the saved drafts.
  - Deps: none · Gate: slice · estLines: 60
  - Why: requirement 1.
  - Covers: req-draft-list
  - Writes: `app/drafts/list/`

  ### save-queue
  Queue a save made offline.
  - Deps: draft-list · Gate: slice · estLines: 120
  - Why: requirement 2.
  - Covers: \(covers)
  - Writes: `app/drafts/queue/`
  """
}

@Suite("Live plan covers")
struct LivePlanCoversTests {
  @Test(
    "a PLAN.md with 2 requirements and 2 tasks imports each task's Covers into its ledger covers and keeps each requirement's title — catches a dropped Covers line"
  )
  func importsCovers() throws {
    let parsed = try LivePlanParser.parse(plan())
    #expect(
      parsed.requirements == [
        LivePlanRequirement(id: "req-draft-list", title: "Show every saved draft"),
        LivePlanRequirement(
          id: "req-offline-save",
          title: "Save a draft without a network, and keep it until it syncs"),
      ])
    let ledger = try parsed.ledger(maxParallel: 2, existing: nil) { "worktrees/\($0)" }
    #expect(ledger.tasks.map(\.covers) == [["req-draft-list"], ["req-offline-save"]])
    let file = parsed.planFile(slug: "offline-drafts", resume: ledger.resume, existing: nil)
    let decoded = try PlanFileJSON.decode(PlanFileJSON.encode(file))
    #expect(decoded.livePlanSource?.requirements == parsed.requirements)
  }

  @Test(
    "a Covers line naming an id Requirements doesn't list fails naming the task and the id — catches a misspelled requirement passing as covered"
  )
  func unknownCoverFails() {
    let error = #expect(throws: LivePlanError.self) {
      try LivePlanParser.parse(plan(secondCovers: "req-offline-save, req-ofline-sync"))
    }
    #expect(error == .unknownRequirement(task: "save-queue", id: "req-ofline-sync"))
    #expect(error?.message.contains("`req-ofline-sync`") == true)
  }

  @Test(
    "a requirement no task covers fails naming it — catches a requirement the plan dropped"
  )
  func uncoveredRequirementFails() {
    let text = plan().replacingOccurrences(
      of: "- Covers: req-offline-save\n", with: "")
    #expect(throws: LivePlanError.uncoveredRequirement("req-offline-save")) {
      try LivePlanParser.parse(text)
    }
  }

  @Test(
    "a Requirements bullet that isn't an id and a title fails naming the line, and an id listed twice fails naming it — catches a requirement read with an empty id"
  )
  func malformedRequirementsFail() {
    let bare = plan().replacingOccurrences(
      of: "- req-draft-list: Show every saved draft", with: "- Show every saved draft")
    #expect(throws: LivePlanError.invalidRequirement(line: "- Show every saved draft")) {
      try LivePlanParser.parse(bare)
    }
    let twice = plan().replacingOccurrences(
      of: "- req-draft-list: Show every saved draft",
      with: "- req-draft-list: Show every saved draft\n- req-draft-list: Again")
    #expect(throws: LivePlanError.duplicateRequirement("req-draft-list")) {
      try LivePlanParser.parse(twice)
    }
  }
}
