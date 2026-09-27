import Foundation
import SwiftGateDomain
import Testing

@Suite("Ledger build states and fields")
struct LedgerBuildStatesTests {
  static func task(
    status: TaskStatus = .pending, model: TaskModel? = nil, branch: String? = nil
  ) -> LedgerTask {
    LedgerTask(
      id: "offline-queue-core-reducer", deps: [], writeSet: ["a/"], gate: .push,
      tests: ["test-a"], covers: ["test-a"], estLines: 180, status: status, worktree: "../w",
      model: model, branch: branch)
  }

  // MARK: - Round-trip

  @Test(
    "a task with model and branch round-trips byte-stable — catches the new fields mangled on decode"
  )
  func modelAndBranchRoundTrip() throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

    let branch = "2026-09-25-offline-order-queue/offline-queue-core-reducer"
    let withFields = Self.task(model: .opus, branch: branch)
    let firstPass = try encoder.encode(withFields)
    let text = String(decoding: firstPass, as: UTF8.self)
    #expect(text.contains("\"model\":\"opus\""))
    #expect(text.contains("\"branch\":\"\(branch)\""))
    let decoded = try JSONDecoder().decode(LedgerTask.self, from: firstPass)
    #expect(decoded == withFields)
    #expect(try encoder.encode(decoded) == firstPass)
  }

  @Test(
    "a task with no model or branch omits both keys entirely and round-trips byte-stable — catches an absent field written as null"
  )
  func absentModelAndBranchOmitted() throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

    let bare = Self.task()
    #expect(bare.model == nil)
    #expect(bare.branch == nil)
    let firstPass = try encoder.encode(bare)
    let text = String(decoding: firstPass, as: UTF8.self)
    #expect(!text.contains("model"))
    #expect(!text.contains("branch"))
    #expect(!text.contains("null"))
    let decoded = try JSONDecoder().decode(LedgerTask.self, from: firstPass)
    #expect(decoded == bare)
    #expect(decoded.model == nil)
    #expect(decoded.branch == nil)
    #expect(try encoder.encode(decoded) == firstPass)
  }

  @Test(
    "an older ledger with no model field still decodes — catches a schema bump that breaks old ledgers"
  )
  func ledgerWithNoModelFieldStillDecodes() throws {
    let json = """
      {
        "id": "offline-queue-core-reducer",
        "deps": [],
        "writeSet": ["a/"],
        "gate": "push",
        "tests": ["test-a"],
        "covers": ["test-a"],
        "estLines": 180,
        "status": "pending",
        "worktree": "../w"
      }
      """
    let decoded = try JSONDecoder().decode(LedgerTask.self, from: Data(json.utf8))
    #expect(decoded.model == nil)
    #expect(decoded.branch == nil)
  }

  @Test(
    "an unrecognized model value fails to decode, naming the value — catches a bad model silently accepted"
  )
  func unknownModelRejected() throws {
    let json = Data("\"haiku\"".utf8)
    let error = #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(TaskModel.self, from: json)
    }
    #expect(error != nil)
    #expect(String(describing: error).contains("haiku"))
  }

  @Test("model round-trips byte-stable for each case — catches sonnet or opus mangled on decode")
  func modelRoundTripsForEachCase() throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    for model in TaskModel.allCases {
      let firstPass = try encoder.encode(model)
      let decoded = try JSONDecoder().decode(TaskModel.self, from: firstPass)
      #expect(decoded == model)
      #expect(try encoder.encode(decoded) == firstPass)
    }
  }

  @Test(
    "an unrecognized task status is still rejected after adding blocked and abandoned, naming the value — catches an unknown build state passed through unexamined"
  )
  func unknownStatusStillRejected() throws {
    let json = Data("\"cancelled\"".utf8)
    let error = #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(TaskStatus.self, from: json)
    }
    #expect(error != nil)
    #expect(String(describing: error).contains("cancelled"))
  }

  @Test("blocked and abandoned round-trip byte-stable, like every other status")
  func newStatusesRoundTrip() throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    for status in [TaskStatus.blocked, .abandoned] {
      let task = Self.task(status: status)
      let firstPass = try encoder.encode(task)
      let decoded = try JSONDecoder().decode(LedgerTask.self, from: firstPass)
      #expect(decoded == task)
      #expect(try encoder.encode(decoded) == firstPass)
    }
  }

  // MARK: - LedgerTransition

  /// The transitions the build-executor spec §6.2 and sub-project 2 §5.9/§8.4 define, hand-listed
  /// once here; every pair `TaskStatus.allCases x TaskStatus.allCases` leaves out is asserted
  /// refused below, so the illegal set is never hand-listed.
  static let legalTransitions: Set<[TaskStatus]> = [
    [.pending, .inProgress],
    [.inProgress, .done],
    [.inProgress, .blocked],
    [.inProgress, .abandoned],
    [.inProgress, .pending],
    [.blocked, .pending],
    [.blocked, .abandoned],
    [.pending, .needsReplan],
    [.inProgress, .needsReplan],
    [.blocked, .needsReplan],
    [.abandoned, .needsReplan],
  ]

  @Test("every legal transition is allowed and every other pair is refused, over every status pair")
  func everyPairMatchesTheLegalSet() {
    for from in TaskStatus.allCases {
      for to in TaskStatus.allCases {
        let expectedLegal = Self.legalTransitions.contains([from, to])
        switch LedgerTransition.check(from: from, to: to) {
        case .allowed:
          #expect(expectedLegal, "\(from.rawValue) -> \(to.rawValue) should have been refused")
        case .refused(let reason):
          #expect(
            !expectedLegal,
            "\(from.rawValue) -> \(to.rawValue) should have been allowed, refused: \(reason)")
          #expect(!reason.isEmpty)
        }
      }
    }
  }

  @Test("done is immutable — catches a mutable done")
  func doneIsImmutable() {
    for to in TaskStatus.allCases {
      switch LedgerTransition.check(from: .done, to: to) {
      case .allowed:
        Issue.record("done -> \(to.rawValue) should never be allowed")
      case .refused:
        break
      }
    }
  }

  @Test("done -> pending fails specifically — catches a mutable done regression")
  func doneToPendingFails() {
    switch LedgerTransition.check(from: .done, to: .pending) {
    case .allowed: Issue.record("done -> pending must be refused")
    case .refused: break
    }
  }

  // MARK: - Rendering

  static func ledgerRenderInput(tasks: [LedgerTask]) -> LedgerRender.Input {
    let text = """
      # Sample

      ## Problem

      Something.

      ## Requirements

      ## Decision

      Do it.

      ## Test plan by tier

      - test-sample: it works — tier T1

      """
    let design = DesignDocument(markdown: .parse(text))
    let ledger = Ledger(
      schemaVersion: 1, resume: "planned", maxParallel: 3, tasks: tasks,
      waves: [tasks.map(\.id)])
    return LedgerRender.Input(
      slug: "sample-plan", ledger: ledger, design: design, designSha: "deadbeef")
  }

  @Test(
    "blocked and abandoned tasks each show their own visible status text, distinct from each other and from every other state — catches a view that only differs by colour"
  )
  func blockedAndAbandonedAreVisiblyDistinct() throws {
    let tasks = [
      LedgerTask(
        id: "task-blocked", deps: [], writeSet: ["a/"], gate: .fast, tests: [], covers: [],
        estLines: 10, status: .blocked, worktree: "../w"),
      LedgerTask(
        id: "task-abandoned", deps: [], writeSet: ["b/"], gate: .fast, tests: [], covers: [],
        estLines: 10, status: .abandoned, worktree: "../w"),
      LedgerTask(
        id: "task-pending", deps: [], writeSet: ["c/"], gate: .fast, tests: [], covers: [],
        estLines: 10, status: .pending, worktree: "../w"),
    ]
    let html = LedgerRender.page(Self.ledgerRenderInput(tasks: tasks)).html

    let blockedLI = try Self.liContaining(id: "task-blocked", html: html)
    let abandonedLI = try Self.liContaining(id: "task-abandoned", html: html)
    let pendingLI = try Self.liContaining(id: "task-pending", html: html)

    #expect(blockedLI.contains("data-status=\"blocked\""))
    #expect(abandonedLI.contains("data-status=\"abandoned\""))
    #expect(pendingLI.contains("data-status=\"pending\""))

    // Each state's visible text (not colour alone) names its own state and no other's.
    #expect(blockedLI.contains(LedgerRender.statusLabel(.blocked)))
    #expect(!blockedLI.contains(LedgerRender.statusLabel(.abandoned)))
    #expect(abandonedLI.contains(LedgerRender.statusLabel(.abandoned)))
    #expect(!abandonedLI.contains(LedgerRender.statusLabel(.blocked)))
    #expect(pendingLI.contains(LedgerRender.statusLabel(.pending)))
    #expect(!pendingLI.contains(LedgerRender.statusLabel(.blocked)))
    #expect(!pendingLI.contains(LedgerRender.statusLabel(.abandoned)))
  }

  static func liContaining(id: String, html: String) throws -> Substring {
    let marker = try #require(html.range(of: ">\(id)<"))
    let start = try #require(html[..<marker.lowerBound].range(of: "<li ", options: .backwards))
    let end = try #require(html[marker.upperBound...].range(of: "</li>"))
    return html[start.lowerBound..<end.upperBound]
  }

  @Test("every task status renders a distinct, non-empty visible label")
  func everyStatusHasADistinctLabel() {
    let labels = TaskStatus.allCases.map(LedgerRender.statusLabel)
    #expect(Set(labels).count == TaskStatus.allCases.count)
    #expect(labels.allSatisfy { !$0.isEmpty })
  }
}
