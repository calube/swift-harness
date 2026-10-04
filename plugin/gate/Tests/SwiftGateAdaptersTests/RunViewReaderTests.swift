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
    var common: URL { checkout.appending(path: ".git", directoryHint: .isDirectory) }
    var events: URL { checkout.appending(path: ".harness/events", directoryHint: .isDirectory) }
    var worktreeEvents: URL {
      parent.appending(
        path: "\(checkout.lastPathComponent)-\(RunViewReaderTests.plan)-\(RunViewReaderTests.task)"
          + "/.harness/events", directoryHint: .isDirectory)
    }

    /// A checkout holding the captured run's plan state, with empty stores.
    init() throws {
      parent = FileManager.default.temporaryDirectory.appending(
        path: "run-view-reader-\(UUID().uuidString)", directoryHint: .isDirectory)
      checkout = parent.appending(path: "app", directoryHint: .isDirectory)
      let planDirectory = common.appending(
        path: "swift-harness/plans/\(RunViewReaderTests.plan)", directoryHint: .isDirectory)
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
    #expect(!input.events.contains { $0.eventID == (try? Self.eventID(otherRun)) })
    #expect(!input.events.contains { $0.kind == .cacheLookup || $0.kind == .hookDecision })
    #expect(input.events.filter { $0.kind == .agentUsage }.count == 91)
    #expect(input.events.filter { $0.kind == .buildHalt }.count == 1)
    #expect(
      input.events.filter { $0.kind == .gateStep || $0.kind == .testResult }
        .allSatisfy { $0.runID.map(gateRuns.contains) == true })
    #expect(input.events.contains { $0.kind == .testResult })
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
}
