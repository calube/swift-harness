import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

/// Seeds a temp repository from the captured build run, so nothing here reads or writes this
/// checkout's own stores or plan state.
@Suite("run view reader")
struct RunViewReaderTests {
  static let captured = Fixture.gateDirectory.appending(
    path: "Tests/Fixtures/RunView/build-run-1", directoryHint: .isDirectory)
  static let buildRun = "20261004T045528Z-58d28c78"
  static let plan = "2026-10-03-counter-reset-and-floor"
  static let task = "counter-core-reset-and-decrement-floor"

  struct Repository {
    let parent: URL
    let checkout: URL
    let common: URL
    var planDirectory: URL {
      common.appending(
        path: "swift-harness/plans/\(RunViewReaderTests.plan)", directoryHint: .isDirectory)
    }
    var events: URL { checkout.appending(path: ".harness/events", directoryHint: .isDirectory) }
    var worktreeEvents: URL {
      parent.appending(
        path: "\(checkout.lastPathComponent)-\(RunViewReaderTests.plan)-\(RunViewReaderTests.task)"
          + "/.harness/events", directoryHint: .isDirectory)
    }

    /// A checkout holding the captured run's plan state, with empty stores. `bare` puts the git
    /// common dir beside the checkout, as a bare repository's, with no main checkout.
    init(bare: Bool = false) throws {
      parent = FileManager.default.temporaryDirectory.appending(
        path: "run-view-reader-\(UUID().uuidString)", directoryHint: .isDirectory)
      checkout = parent.appending(path: "app", directoryHint: .isDirectory)
      common =
        bare
        ? parent.appending(path: "app.git", directoryHint: .isDirectory)
        : checkout.appending(path: ".git", directoryHint: .isDirectory)
      let runDirectory = planDirectory.appending(
        path: "build/\(RunViewReaderTests.buildRun)", directoryHint: .isDirectory)
      try Self.make(runDirectory.appending(path: "returns"))
      try Self.make(events)
      try Data().write(to: checkout.appending(path: ".swiftgate.toml"))
      let copies: [(String, URL)] = [
        ("ledger.json", planDirectory.appending(path: "ledger.json")),
        ("plan.json", planDirectory.appending(path: "plan.json")),
        ("plan.md", planDirectory.appending(path: "spec-page.md")),
        ("run.json", runDirectory.appending(path: "run.json")),
        ("ledger-events.jsonl", runDirectory.appending(path: "events.jsonl")),
      ]
      for (name, target) in copies {
        try FileManager.default.copyItem(
          at: RunViewReaderTests.captured.appending(path: name), to: target)
      }
      for name in try Self.names(in: RunViewReaderTests.captured.appending(path: "returns")) {
        try FileManager.default.copyItem(
          at: RunViewReaderTests.captured.appending(path: "returns/\(name)"),
          to: runDirectory.appending(path: "returns/\(name)"))
      }
    }

    static func make(_ url: URL) throws {
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    static func names(in url: URL) throws -> [String] {
      try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
    }

    func write(_ lines: [String], to url: URL) throws {
      try Self.make(url.deletingLastPathComponent())
      try Data(lines.map { $0 + "\n" }.joined().utf8).write(to: url)
    }

    func read() throws -> RunViewInput {
      try RunViewReader(commonDirectory: common, stateRoot: .tree(checkout))
        .read(buildRun: RunViewReaderTests.buildRun)
    }

    func remove() { try? FileManager.default.removeItem(at: parent) }
  }

  static func lines(_ path: String) throws -> [String] {
    try String(contentsOf: captured.appending(path: path), encoding: .utf8)
      .split(separator: "\n").map(String.init)
  }

  static func eventID(_ line: String) throws -> String {
    let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
    return try #require(object?["eventID"] as? String)
  }

  static let redGate = "20261004T050310Z-ed998508"

  /// A checkout holding the captured run's gate and test streams, and the RED merge gate's
  /// `report.json` as `body` when given.
  static func redGateRepository(report body: Data?) throws -> Repository {
    let repository = try Repository()
    for stream in ["gate", "test", "build"] {
      try repository.write(
        try Self.lines("events/\(stream).jsonl"),
        to: repository.events.appending(path: "\(stream).jsonl"))
    }
    if let body {
      let report = repository.checkout.appending(path: ".harness/runs/\(redGate)/report.json")
      try Repository.make(report.deletingLastPathComponent())
      try body.write(to: report)
    }
    return repository
  }

  @Test(
    "a RED gate's report.json in the main checkout reads with its location relative to the checkout, beside the checkout's roots — catches the reader dropping a red gate's findings"
  )
  func readsTheRedGateReport() throws {
    let captured = try Data(
      contentsOf: Self.captured.appending(path: "runs/\(Self.redGate)/report.json"))
    let repository = try Self.redGateRepository(report: captured)
    defer { repository.remove() }
    let input = try repository.read()
    #expect(Array(input.gateReports.keys) == [Self.redGate])
    let read = try #require(input.gateReports[Self.redGate])
    #expect(read.location == ".harness/runs/\(Self.redGate)/report.json")
    #expect(read.report == (try RecordedRunReport.decode(captured)).report)
    #expect(input.checkoutRoots.contains(repository.checkout.standardizedFileURL.path))
    #expect(input.damage.isEmpty, "\(input.damage)")

    let failure = try #require(
      RunViewBuilder.build(input).gates.first { $0.runID == Self.redGate }?.failure)
    #expect(failure.findings.map(\.rule) == ["t2.test-failed"])
    #expect(failure.report == read.location)
  }

  @Test(
    "a RED gate's report.json that doesn't decode is 1 damage row naming its relative location, and a missing one leaves the failure with no report — catches a silent gap or a machine path in the footer"
  )
  func unreadableRedGateReportIsDamage() throws {
    let broken = try Self.redGateRepository(report: Data("{\"runID\":".utf8))
    defer { broken.remove() }
    let input = try broken.read()
    #expect(input.gateReports.isEmpty)
    #expect(input.damage.map(\.source) == [".harness/runs/\(Self.redGate)/report.json"])
    #expect(input.damage.allSatisfy { !$0.reason.contains(broken.parent.path) })

    let missing = try Self.redGateRepository(report: nil)
    defer { missing.remove() }
    let view = RunViewBuilder.build(try missing.read())
    let failure = try #require(view.gates.first { $0.runID == Self.redGate }?.failure)
    #expect(failure.report == nil)
    #expect(failure.tiers == [.t2])
  }

  @Test(
    "events split across the main store, a live task worktree's store and an imported store read back as the set 1 store holds — catches a store left out"
  )
  func readsEveryStore() throws {
    let usage = try Self.lines("events/usage.jsonl")
    let gate = try Self.lines("events/gate.jsonl")
    let build = try Self.lines("events/build.jsonl")

    let whole = try Repository()
    defer { whole.remove() }
    try whole.write(usage, to: whole.events.appending(path: "usage.jsonl"))
    try whole.write(gate, to: whole.events.appending(path: "gate.jsonl"))
    try whole.write(build, to: whole.events.appending(path: "build.jsonl"))
    let expected = Set(try whole.read().events.map(\.eventID))

    let split = try Repository()
    defer { split.remove() }
    let third = usage.count / 3
    let inMain = Array(usage[..<third])
    let inWorktree = Array(usage[third..<(2 * third)])
    let inImported = Array(usage[(2 * third)...])
    try split.write(inMain, to: split.events.appending(path: "usage.jsonl"))
    try split.write(gate, to: split.events.appending(path: "gate.jsonl"))
    try split.write(build, to: split.events.appending(path: "build.jsonl"))
    try split.write(inWorktree, to: split.worktreeEvents.appending(path: "usage.jsonl"))
    try split.write(
      inImported,
      to: split.events.appending(path: "imported/96702ebb-bca9-4a00-ae02-1cfdfe2c0e83/usage.jsonl"))
    let input = try split.read()
    let read = Set(input.events.map(\.eventID))

    for part in [inMain, inWorktree, inImported] {
      #expect(read.isSuperset(of: try part.map(Self.eventID)))
    }
    #expect(read == expected)
    #expect(input.damage.isEmpty, "\(input.damage)")
  }

  @Test(
    "a truncated JSONL line becomes 1 damage row naming its file and the other events still read — catches a silent gap or a lost store"
  )
  func truncatedLineIsDamage() throws {
    let usage = try Self.lines("events/usage.jsonl")
    let repository = try Repository()
    defer { repository.remove() }
    let file = repository.events.appending(path: "usage.jsonl")
    let last = try #require(usage.last)
    let body = usage.dropLast().map { $0 + "\n" }.joined() + String(last.prefix(last.count / 2))
    try Data(body.utf8).write(to: file)

    let input = try repository.read()
    #expect(input.damage.count == 1, "\(input.damage)")
    #expect(input.damage.first?.source.hasSuffix("events/usage.jsonl:\(usage.count)") == true)
    #expect(
      Set(input.events.map(\.eventID)) == Set(try usage.dropLast().map(Self.eventID)))
  }

  @Test(
    "events of another build run, of unnamed gate runs and of no build run stay out — catches a missing build run filter"
  )
  func keepsOnlyTheRun() throws {
    let repository = try Repository()
    defer { repository.remove() }
    for stream in ["usage", "gate", "test", "build", "cache", "hook"] {
      try repository.write(
        try Self.lines("events/\(stream).jsonl"),
        to: repository.events.appending(path: "\(stream).jsonl"))
    }
    let usage = try #require(try Self.lines("events/usage.jsonl").first)
    let otherRun =
      usage
      .replacingOccurrences(of: Self.buildRun, with: "20261004T060000Z-00000000")
      .replacingOccurrences(of: try Self.eventID(usage), with: UUID().uuidString)
    try repository.write(
      [otherRun], to: repository.events.appending(path: "imported/other/usage.jsonl"))

    let input = try repository.read()
    let gateRuns = Set(
      input.events.compactMap { event -> String? in
        guard case .gateRun = event.payload else { return nil }
        return event.runID
      })
    #expect(
      gateRuns == [
        "20261004T045901Z-e384a82a", "20261004T050310Z-ed998508", "20261004T051053Z-7447d956",
        "20261004T051601Z-46b2b09c",
      ])
    let otherID = try Self.eventID(otherRun)
    #expect(!input.events.contains { $0.eventID == otherID })
    #expect(!input.events.contains { $0.kind == .cacheLookup || $0.kind == .hookDecision })
    #expect(input.events.filter { $0.kind == .agentUsage }.count == 91)
    #expect(input.events.filter { $0.kind == .buildHalt }.count == 1)
    #expect(
      input.events.filter { $0.kind == .gateStep || $0.kind == .testResult }
        .allSatisfy { $0.runID.map(gateRuns.contains) == true })
    #expect(input.events.contains { $0.kind == .testResult })
  }

  @Test(
    "a fix worker's gate runs in an imported store read with the task whose window holds them, and unnamed runs of the main checkout or outside every window stay out — catches a worker's RED-then-fixed gates missing from the report"
  )
  func keepsWorkerGateRunsInTheTaskWindow() throws {
    let repository = try Repository()
    defer { repository.remove() }
    for stream in ["usage", "gate", "test", "build"] {
      try repository.write(
        try Self.lines("events/\(stream).jsonl"),
        to: repository.events.appending(path: "\(stream).jsonl"))
    }
    let store = "events/imported/b624dcba-0ec6-4c16-b29a-4c8992f0b8a4"
    let imported = try Self.lines("\(store)/gate.jsonl")
    let late = try #require(imported.first { $0.contains("20261004T050817Z-c5027c06") })
    let outside =
      late
      .replacingOccurrences(of: "20261004T050817Z-c5027c06", with: "20261004T044000Z-0badf00d")
      .replacingOccurrences(of: "2026-10-04T05:10:27.992Z", with: "2026-10-04T04:41:00.000Z")
      .replacingOccurrences(of: try Self.eventID(late), with: UUID().uuidString)
    try repository.write(
      imported + [outside], to: repository.events.appending(path: "imported/b624/gate.jsonl"))
    try repository.write(
      try Self.lines("\(store)/test.jsonl"),
      to: repository.events.appending(path: "imported/b624/test.jsonl"))

    let view = RunViewBuilder.build(try repository.read())
    let tasks = Dictionary(view.gates.map { ($0.runID, $0.task) }, uniquingKeysWith: { a, _ in a })
    #expect(tasks["20261004T050551Z-3bf0d37c"] == .some("counter-ui-reset-button"))
    #expect(tasks["20261004T050817Z-c5027c06"] == .some("counter-ui-reset-button"))
    #expect(tasks["20261004T050310Z-ed998508"] == .some("counter-ui-reset-button"))
    #expect(tasks["20261004T050310Z-8a535bea"] == nil, "a main checkout run no event names")
    #expect(tasks["20261004T044000Z-0badf00d"] == nil, "a run outside every task's window")
    #expect(
      view.spans.contains {
        $0.id == "gate:20261004T050817Z-c5027c06" && $0.parent == "task:counter-ui-reset-button"
      })
  }

  @Test(
    "a live plan's task briefs read into the view's tasks, a missing why reading empty — catches a brownfield task drawer with no Why, Scope or Acceptance"
  )
  func readsLivePlanBriefs() throws {
    let repository = try Repository()
    defer { repository.remove() }
    let brief = TaskBrief(
      title: "Reset the counter", why: "Users asked for a reset. Implements §2.1",
      designRef: "§2.1", scope: ["`CounterCore` gains `reset()`"],
      acceptance: ["`resetAfterIncrementsShowsZero` fails first"], outOfScope: ["The view"])
    let bare = TaskBrief(
      title: "Show a reset button", why: nil, designRef: nil, scope: [], acceptance: [],
      outOfScope: [])
    let plan = PlanFile(
      schemaVersion: 1, slug: Self.plan,
      source: .livePlan(
        PlanFile.LivePlanSource(briefs: [Self.task: brief, "counter-ui-reset-button": bare])),
      surfaceCommit: nil, resume: "imported")
    try PlanFileJSON.encode(plan).write(to: repository.planDirectory.appending(path: "plan.json"))

    let input = try repository.read()
    #expect(
      input.briefs[Self.task]
        == RunView.Brief(
          title: "Reset the counter", why: "Users asked for a reset. Implements §2.1",
          designRef: "§2.1", scope: ["`CounterCore` gains `reset()`"],
          acceptance: ["`resetAfterIncrementsShowsZero` fails first"], outOfScope: ["The view"]))
    #expect(
      input.briefs["counter-ui-reset-button"]
        == RunView.Brief(title: "Show a reset button", why: ""))
    #expect(input.briefs["counter-ui-reset-button-snapshot"] == nil)
    let view = RunViewBuilder.build(input)
    #expect(view.tasks.first { $0.id == Self.task }?.brief?.title == "Reset the counter")
  }

  @Test(
    "the run's ledger and its spec page's slices read with the join — catches a reader that drops the plan"
  )
  func readsThePlan() throws {
    let repository = try Repository()
    defer { repository.remove() }
    let input = try repository.read()
    #expect(input.join?.plan == Self.plan)
    #expect(input.ledger?.tasks.map(\.id).contains(Self.task) == true)
    #expect(
      input.requirements.map(\.id) == [
        "slice-1-reset-after-increments-shows-zero", "slice-2-decrement-at-zero-stays-zero",
      ])
    #expect(input.requirements.allSatisfy { $0.title.utf8.count <= RunView.maxTitleBytes })
    #expect(input.damage.isEmpty, "\(input.damage)")
  }

  @Test(
    "a run no plan holds reads as damage naming the plans directory — catches an empty view passing for a run with no events"
  )
  func unknownRunIsDamage() throws {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "run-view-reader-\(UUID().uuidString)", directoryHint: .isDirectory)
    let input = try RunViewReader(commonDirectory: directory, stateRoot: .tree(directory))
      .read(buildRun: Self.buildRun)
    #expect(input.events.isEmpty)
    #expect(input.join == nil)
    #expect(input.damage.map(\.source) == [BuildJoinReader.plansDirectory])
  }

  static let design = "docs/designs/counter.md"
  /// 3 bytes a character, so a cut at the title cap can't land on a character boundary by luck.
  static let longStatement = String(repeating: "\u{2192}", count: 60)

  func seedDesignPlan(_ repository: Repository) throws {
    try PlanFileJSON.encode(PlanFile.seed(slug: Self.plan, design: Self.design, tier: nil))
      .write(to: repository.planDirectory.appending(path: "plan.json"))
    try repository.write(
      ["# Counter", "", "## Requirements", "", "- req-counter-reset: \(Self.longStatement)"],
      to: repository.checkout.appending(path: Self.design))
  }

  @Test(
    "a design plan's requirements read from its design, each title cut to the title cap on a character boundary — catches a title past the cap or a split character"
  )
  func readsDesignRequirements() throws {
    let repository = try Repository()
    defer { repository.remove() }
    try seedDesignPlan(repository)
    let input = try repository.read()
    let requirement = try #require(input.requirements.first)
    #expect(input.requirements.count == 1)
    #expect(requirement.id == "req-counter-reset")
    #expect(requirement.title == String(repeating: "\u{2192}", count: 40))
    #expect(input.damage.isEmpty, "\(input.damage)")
  }

  @Test(
    "a common dir with no main checkout is damage naming the task worktrees and the design it can't read — catches a silent skip"
  )
  func bareCommonDirectoryIsDamage() throws {
    let repository = try Repository(bare: true)
    defer { repository.remove() }
    try seedDesignPlan(repository)
    let input = try repository.read()
    #expect(input.ledger != nil)
    #expect(input.requirements.isEmpty)
    #expect(input.damage.map(\.source) == [Self.design, "app.git"], "\(input.damage)")
  }

  @Test(
    "an undecodable ledger and an undecodable plan.json are damage rows naming each file — catches plan state dropped silently"
  )
  func undecodablePlanStateIsDamage() throws {
    let repository = try Repository()
    defer { repository.remove() }
    for name in ["ledger.json", "plan.json"] {
      try Data("{".utf8).write(to: repository.planDirectory.appending(path: name))
    }
    let input = try repository.read()
    #expect(input.ledger == nil)
    let planState = "swift-harness/plans/\(Self.plan)"
    #expect(
      input.damage.map(\.source).filter { $0.hasPrefix(planState) }
        == ["\(planState)/ledger.json", "\(planState)/plan.json"], "\(input.damage)")
  }

  @Test(
    "a malformed spec page is 1 damage row naming it and no requirement — catches a page read as having no slices"
  )
  func malformedSpecPageIsDamage() throws {
    let repository = try Repository()
    defer { repository.remove() }
    try Data("# Counter\n".utf8).write(to: repository.planDirectory.appending(path: "spec-page.md"))
    let input = try repository.read()
    #expect(input.requirements.isEmpty)
    #expect(
      input.damage.map(\.source) == ["swift-harness/plans/\(Self.plan)/spec-page.md"],
      "\(input.damage)")
    #expect(input.damage.first?.reason.hasPrefix("malformed spec page") == true)
  }

  @Test(
    "an events directory that can't be read is damage naming it — catches an unreadable store passing as a run with no events"
  )
  func unreadableStoreIsDamage() throws {
    let repository = try Repository()
    defer {
      try? FileManager.default.setAttributes(  // swiftgate:allow test.swallowed-error — cleanup
        [.posixPermissions: 0o755], ofItemAtPath: repository.events.path)
      repository.remove()
    }
    try repository.write(
      try Self.lines("events/usage.jsonl"), to: repository.events.appending(path: "usage.jsonl"))
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o000], ofItemAtPath: repository.events.path)
    let input = try repository.read()
    #expect(input.events.isEmpty)
    #expect(!input.damage.isEmpty)
    #expect(input.damage.allSatisfy { $0.source.hasPrefix(".harness/events") }, "\(input.damage)")
  }

  @Test(
    "a span.end of the run's span and a prove.result under the run's gate.run stay; another run's span.end goes — catches events that name no build run dropped or leaked"
  )
  func keepsSpanEndsAndProofsByParent() throws {
    let repository = try Repository()
    defer { repository.remove() }
    let gate = try Self.lines("events/gate.jsonl")
    let gateRun = try #require(
      gate.first {
        $0.contains("\"kind\":\"gate.run\"") && $0.contains("20261004T045901Z-e384a82a")
      })
    let time = Date(timeIntervalSince1970: 1_791_000_000)
    let source = HarnessEventSource(route: .check)
    func event(_ id: String, parent: String?, _ payload: HarnessEventPayload) throws -> String {
      let event = HarnessEvent(
        eventID: id, parentID: parent, time: time, source: source, payload: payload)
      return String(decoding: try HarnessEventJSON.encodeLine(event), as: UTF8.self)
        .trimmingCharacters(in: .newlines)
    }
    func start(_ id: String, span: String, run: String) throws -> String {
      try event(
        id, parent: nil,
        .spanStart(
          SpanStartEvent(
            spanID: span, parentSpan: nil, phase: .worker, buildRun: run, task: Self.task,
            role: nil)))
    }
    func end(_ id: String, start: String, span: String) throws -> String {
      try event(
        id, parent: start, .spanEnd(SpanEndEvent(spanID: span, outcome: .ok, milliseconds: 5)))
    }
    let spans = [
      try start("own-start", span: "00000000000000a1", run: Self.buildRun),
      try end("own-end", start: "own-start", span: "00000000000000a1"),
      try start("other-start", span: "00000000000000b2", run: "20261004T060000Z-00000000"),
      try end("other-end", start: "other-start", span: "00000000000000b2"),
    ]
    let proof = try event(
      "proof", parent: try Self.eventID(gateRun),
      .proveResult(
        ProveResultEvent(
          test: "CounterFeatureTests/resetAfterIncrementsShowsZero()", testHashed: false,
          target: "CounterCoreTests", outcome: .proven, proofBase: nil, assertion: nil)))
    try repository.write(gate, to: repository.events.appending(path: "gate.jsonl"))
    try repository.write(spans, to: repository.events.appending(path: "span.jsonl"))
    try repository.write([proof], to: repository.events.appending(path: "test.jsonl"))

    let kept = Set(try repository.read().events.map(\.eventID))
    #expect(kept.isSuperset(of: ["own-start", "own-end", "proof"]))
    #expect(kept.isDisjoint(with: ["other-start", "other-end"]))
  }
}
