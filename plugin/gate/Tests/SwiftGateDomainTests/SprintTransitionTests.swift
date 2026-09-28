import SwiftGateDomain
import Testing

/// Runs built only through the state machine, so every fixture is a state a real sprint reaches.
enum SprintFixtures {
  static let base = String(repeating: "a", count: 40)
  static let surface = String(repeating: "b", count: 40)
  static let sliceCount = 3

  static func gateRun(_ n: Int) -> String { "20260927T23170\(n)Z-cb69701e" }
  static let finalGateRun = "20260928T004518Z-a6412b52"

  static let start = SprintEvent.start(
    slug: "notes-search", specPage: "docs/sprints/notes-search.md", baseCommit: base,
    sliceCount: sliceCount)

  /// Every event of one whole sprint, in the only order the machine accepts.
  static let legalEvents: [SprintEvent] =
    [start, .surface(commit: surface)]
    + (1...sliceCount).map { .slice($0, gateRun: gateRun($0)) }
    + [.finish(gateRun: finalGateRun)]

  /// The run after the first `count` legal events; `nil` before any.
  static func run(after count: Int) throws -> SprintRun? {
    var run: SprintRun?
    for event in legalEvents.prefix(count) {
      run = try SprintTransition.apply(event, to: run)
    }
    return run
  }

  /// Every step a sprint can be at, paired with the step it must take next.
  static let states: [(events: Int, next: SprintNextStep)] = [
    (0, .start), (1, .surface), (2, .slice(1)), (3, .slice(2)), (4, .slice(3)), (5, .finish),
    (6, .start),
  ]

  static let everyEvent: [(SprintEvent, SprintNextStep)] = [
    (start, .start), (.surface(commit: surface), .surface),
    (.slice(1, gateRun: gateRun(1)), .slice(1)), (.slice(2, gateRun: gateRun(2)), .slice(2)),
    (.slice(3, gateRun: gateRun(3)), .slice(3)), (.slice(4, gateRun: gateRun(4)), .slice(4)),
    (.finish(gateRun: finalGateRun), .finish),
  ]
}

@Suite("Sprint state machine")
struct SprintTransitionTests {
  @Test(
    "a whole sprint walks start, surface, slices in order and finish, recording each step — catches a legal transition refused or a recorded field dropped"
  )
  func legalSequence() throws {
    let started = try #require(try SprintFixtures.run(after: 1))
    #expect(started.step == .started)
    #expect(started.slug == "notes-search")
    #expect(started.specPage == "docs/sprints/notes-search.md")
    #expect(started.branch == "sprint/notes-search")
    #expect(started.baseCommit == SprintFixtures.base)
    #expect(started.surfaceCommit == nil)
    #expect(started.slices.map(\.number) == [1, 2, 3])
    #expect(started.slices.allSatisfy { $0.status == .pending && $0.gateRun == nil })
    #expect(started.next == .surface)

    let surfaced = try #require(try SprintFixtures.run(after: 2))
    #expect(surfaced.step == .surfaced)
    #expect(surfaced.surfaceCommit == SprintFixtures.surface)
    #expect(surfaced.next == .slice(1))

    let second = try #require(try SprintFixtures.run(after: 4))
    #expect(second.step == .slicing(2))
    #expect(second.slices.map(\.status) == [.passed, .passed, .pending])
    #expect(
      second.slices.map(\.gateRun) == [SprintFixtures.gateRun(1), SprintFixtures.gateRun(2), nil])
    #expect(second.next == .slice(3))
    #expect(second.surfaceCommit == SprintFixtures.surface)
    #expect(second.baseCommit == SprintFixtures.base)

    let lastSlice = try #require(try SprintFixtures.run(after: 5))
    #expect(lastSlice.next == .finish)
    #expect(lastSlice.finalGateRun == nil)

    let finished = try #require(try SprintFixtures.run(after: 6))
    #expect(finished.step == .finished)
    #expect(finished.finalGateRun == SprintFixtures.finalGateRun)
    #expect(finished.slices.allSatisfy { $0.status == .passed })
    #expect(finished.next == .start)
  }

  @Test(
    "a finished sprint accepts a new start, which records a fresh run — catches a change request after finish refused or inheriting the old slices"
  )
  func startAfterFinish() throws {
    let finished = try SprintFixtures.run(after: 6)
    let next = try SprintTransition.apply(
      .start(
        slug: "notes-search-2", specPage: "docs/sprints/notes-search.md",
        baseCommit: String(repeating: "c", count: 40), sliceCount: 1),
      to: finished)
    #expect(next.step == .started)
    #expect(next.slug == "notes-search-2")
    #expect(next.slices.map(\.status) == [.pending])
    #expect(next.surfaceCommit == nil)
    #expect(next.finalGateRun == nil)
  }

  @Test(
    "every event other than the expected one is refused, naming the step it expected — catches an illegal transition accepted"
  )
  func everyIllegalTransitionRefused() throws {
    var refusals = 0
    for state in SprintFixtures.states {
      let run = try SprintFixtures.run(after: state.events)
      for (event, attempted) in SprintFixtures.everyEvent where attempted != state.next {
        #expect(
          throws: SprintTransitionError.outOfOrder(attempted: attempted, expected: state.next),
          "\(attempted) at \(state.next)"
        ) {
          try SprintTransition.apply(event, to: run)
        }
        refusals += 1
      }
    }
    #expect(refusals == 42)
  }

  @Test("slice 2 before slice 1 is refused naming slice 1 — catches slices taken out of order")
  func sliceTwoBeforeOne() throws {
    let surfaced = try SprintFixtures.run(after: 2)
    let error = #expect(throws: SprintTransitionError.self) {
      try SprintTransition.apply(.slice(2, gateRun: SprintFixtures.gateRun(2)), to: surfaced)
    }
    #expect(error == .outOfOrder(attempted: .slice(2), expected: .slice(1)))
    #expect(error?.message.contains("expected slice 1") == true)
  }

  @Test(
    "finish before every slice passed is refused naming the next slice — catches a sprint finishing with a slice unproven"
  )
  func finishBeforeEverySlice() throws {
    let firstSlice = try SprintFixtures.run(after: 3)
    let error = #expect(throws: SprintTransitionError.self) {
      try SprintTransition.apply(.finish(gateRun: SprintFixtures.finalGateRun), to: firstSlice)
    }
    #expect(error == .outOfOrder(attempted: .finish, expected: .slice(2)))
    #expect(error?.message.contains("expected slice 2") == true)
  }

  @Test(
    "each step reads as the command that takes it — catches a refusal naming a step no command has"
  )
  func stepDescriptions() {
    #expect(SprintNextStep.start.description == "start")
    #expect(SprintNextStep.surface.description == "surface")
    #expect(SprintNextStep.slice(4).description == "slice 4")
    #expect(SprintNextStep.finish.description == "finish")
    let message = SprintTransitionError.outOfOrder(attempted: .finish, expected: .surface).message
    #expect(message.contains("got finish"))
    #expect(message.contains("expected surface"))
  }

  @Test(
    "a malformed slug, commit, gate run or slice count is refused naming the value — catches junk recorded as sprint state",
    arguments: [
      (
        SprintEvent.start(
          slug: "Notes Search", specPage: "p.md", baseCommit: SprintFixtures.base, sliceCount: 1),
        SprintTransitionError.invalidSlug("Notes Search")
      ),
      (
        .start(slug: "-notes", specPage: "p.md", baseCommit: SprintFixtures.base, sliceCount: 1),
        .invalidSlug("-notes")
      ),
      (
        .start(slug: "notes", specPage: "", baseCommit: SprintFixtures.base, sliceCount: 1),
        .invalidSpecPage("")
      ),
      (
        .start(slug: "notes", specPage: "p.md", baseCommit: "main", sliceCount: 1),
        .invalidCommit("main")
      ),
      (
        .start(slug: "notes", specPage: "p.md", baseCommit: SprintFixtures.base, sliceCount: 0),
        .invalidSliceCount(0)
      ),
    ])
  func malformedStart(event: SprintEvent, expected: SprintTransitionError) {
    #expect(throws: expected) { try SprintTransition.apply(event, to: nil) }
  }

  @Test(
    "a surface commit or gate run id that isn't one is refused — catches an abbreviated sha or empty run id recorded"
  )
  func malformedLaterEvents() throws {
    let started = try SprintFixtures.run(after: 1)
    #expect(throws: SprintTransitionError.invalidCommit("abc123")) {
      try SprintTransition.apply(.surface(commit: "abc123"), to: started)
    }
    let surfaced = try SprintFixtures.run(after: 2)
    #expect(throws: SprintTransitionError.invalidGateRun("")) {
      try SprintTransition.apply(.slice(1, gateRun: ""), to: surfaced)
    }
    let lastSlice = try SprintFixtures.run(after: 5)
    #expect(throws: SprintTransitionError.invalidGateRun("../runs")) {
      try SprintTransition.apply(.finish(gateRun: "../runs"), to: lastSlice)
    }
  }
}
