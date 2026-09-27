import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import Testing

/// The build run store against real files under a temporary repository's git common dir.
@Suite("Build run store")
struct BuildRunStoreTests {
  private static let preset = BuildPreset(
    designTier: .standard, maxParallel: 3, review: .gate, taskGate: .tier(.push),
    mergeGate: .ready, workerModel: .tagged, timeBudgetMin: 90, stopStartsBeforeMin: 15,
    onDesignConflict: .block)
  private static let startedAt = Date(timeIntervalSince1970: 1_790_000_000)

  private static func repository() async throws -> TemporaryGitRepository {
    let repo = try await TemporaryGitRepository()
    try repo.write("A.swift", "a\n")
    _ = try await repo.commitAll("base")
    return repo
  }

  private static func create(_ git: any Git, suffix: UInt32 = 0xabc) async throws -> BuildRunStore {
    try await BuildRunStore.create(
      plan: "search", presetName: "default", preset: preset, startedAt: startedAt, git: git,
      suffix: suffix)
  }

  private static func transition(_ task: String, second: Int) -> BuildEvent {
    .transition(
      .init(
        task: task, from: .pending, to: .inProgress,
        at: startedAt.addingTimeInterval(TimeInterval(second))))
  }

  @Test(
    "8 concurrent appenders each appending 40 events lose none and keep each writer's order — catches a racy append"
  )
  func concurrentAppendersLoseNothing() async throws {
    let repo = try await Self.repository()
    defer { repo.remove() }
    let created = try await Self.create(repo.adapter)
    let writers = 8
    let perWriter = 40

    try await withThrowingTaskGroup(of: Void.self) { group in
      for writer in 0..<writers {
        group.addTask {
          let store = try await BuildRunStore.open(
            plan: "search", runID: created.runID, git: repo.adapter)
          for index in 0..<perWriter {
            try await store.append(Self.transition("w\(writer)", second: index))
          }
        }
      }
      try await group.waitForAll()
    }

    let log = try created.events()
    #expect(log.damage == [])
    #expect(log.events.count == writers * perWriter)
    for writer in 0..<writers {
      let own = log.events.filter { $0.task == "w\(writer)" }
      #expect(own == (0..<perWriter).map { Self.transition("w\(writer)", second: $0) })
    }
  }

  @Test(
    "run.json round-trips the run id, plan, start time, preset name and every preset value — catches a preset field dropped on write"
  )
  func runRecordRoundTrips() async throws {
    let repo = try await Self.repository()
    defer { repo.remove() }
    let created = try await Self.create(repo.adapter, suffix: 0x1f)

    let reopened = try await BuildRunStore.open(
      plan: "search", runID: created.runID, git: repo.adapter)
    let record = try reopened.record()

    #expect(created.runID == RunID.make(startedAt: Self.startedAt, suffix: 0x1f))
    #expect(
      record
        == BuildRunRecord(
          runID: created.runID, plan: "search", startedAt: Self.startedAt, presetName: "default",
          preset: Self.preset))
    let ledgerGated = BuildPreset(
      designTier: .sketch, maxParallel: 1, review: .full, taskGate: .ledger, mergeGate: .fast,
      workerModel: .opus, timeBudgetMin: 0, stopStartsBeforeMin: 0, onDesignConflict: .amend)
    let other = BuildRunRecord(
      runID: "r", plan: "p", startedAt: Self.startedAt, presetName: "interview",
      preset: ledgerGated)
    #expect(try BuildRunJSON.decode(BuildRunJSON.encode(other)) == other)
  }

  @Test(
    "a second run with the same id is refused and the first run.json is untouched — catches a run clobbering another"
  )
  func duplicateRunRefused() async throws {
    let repo = try await Self.repository()
    defer { repo.remove() }
    let first = try await Self.create(repo.adapter)
    let before = FileManager.default.contents(atPath: first.layout.runFile)

    await #expect(throws: BuildRunStoreError.runExists(first.layout.directory)) {
      _ = try await BuildRunStore.create(
        plan: "search", presetName: "interview", preset: Self.preset, startedAt: Self.startedAt,
        git: repo.adapter, suffix: 0xabc)
    }
    #expect(FileManager.default.contents(atPath: first.layout.runFile) == before)
  }

  @Test(
    "an unknown preset value in run.json fails decoding and names itself — catches an open string at the trust boundary"
  )
  func unknownPresetValueFails() throws {
    let record = BuildRunRecord(
      runID: "r", plan: "p", startedAt: Self.startedAt, presetName: "default", preset: Self.preset)
    let text = String(decoding: try BuildRunJSON.encode(record), as: UTF8.self)
      .replacingOccurrences(of: "\"workerModel\" : \"tagged\"", with: "\"workerModel\" : \"haiku\"")

    #expect(text.contains("haiku"))
    #expect {
      _ = try BuildRunJSON.decode(Data(text.utf8))
    } throws: { error in
      String(describing: error).contains("haiku")
    }
  }

  @Test(
    "a torn last line is reported with its line number, and the next append refuses to glue onto it — catches a torn write silently skipped"
  )
  func tornLastLineReported() async throws {
    let repo = try await Self.repository()
    defer { repo.remove() }
    let store = try await Self.create(repo.adapter)
    try await store.append(Self.transition("a", second: 1))
    try await store.append(Self.transition("b", second: 2))
    let handle = try #require(FileHandle(forWritingAtPath: store.layout.eventsFile))
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(#"{"kind":"transition","task":"c""#.utf8))
    try handle.close()

    let log = try store.events()

    #expect(log.events == [Self.transition("a", second: 1), Self.transition("b", second: 2)])
    #expect(log.damage == [.tornLastLine(line: 3)])
    await #expect(throws: BuildRunStoreError.tornTail(store.layout.eventsFile)) {
      try await store.append(Self.transition("d", second: 4))
    }
    #expect(try store.events() == log)
  }

  @Test(
    "a complete line of an unknown kind is reported as undecodable, and later events still read — catches a closed kind decoded loosely"
  )
  func undecodableLineReported() async throws {
    let repo = try await Self.repository()
    defer { repo.remove() }
    let store = try await Self.create(repo.adapter)
    try await store.append(Self.transition("a", second: 1))
    let handle = try #require(FileHandle(forWritingAtPath: store.layout.eventsFile))
    try handle.seekToEnd()
    try handle.write(
      contentsOf: Data(
        "{\"at\":\"2026-09-26T10:00:00Z\",\"kind\":\"rebase\",\"task\":\"x\"}\n".utf8))
    try handle.close()
    try await store.append(Self.transition("b", second: 2))

    let log = try store.events()

    #expect(log.events == [Self.transition("a", second: 1), Self.transition("b", second: 2)])
    #expect(log.damage.count == 1)
    guard case .undecodableLine(line: 2, let reason) = log.damage.first else {
      Issue.record("expected line 2 undecodable, got \(log.damage)")
      return
    }
    #expect(reason.contains("rebase"))
  }

  @Test(
    "a store opened from a linked worktree resolves the same run directory and reads the same events — catches per-worktree build state"
  )
  func linkedWorktreeResolvesSameRun() async throws {
    let repo = try await Self.repository()
    defer { repo.remove() }
    let linked = repo.root.deletingLastPathComponent()
      .appending(path: "\(repo.root.lastPathComponent)-linked", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: linked) }
    try await repo.git("worktree", "add", "-q", "-b", "task", linked.path)
    let main = try await Self.create(repo.adapter)
    try await main.append(Self.transition("a", second: 1))

    let fromLinked = try await BuildRunStore.open(
      plan: "search", runID: main.runID,
      git: LiveGit(runner: repo.runner, repositoryRoot: linked.path))
    try await fromLinked.append(Self.transition("b", second: 2))

    #expect(fromLinked.layout == main.layout)
    #expect(main.layout.directory.hasPrefix(CanonicalPath.of(repo.root.appending(path: ".git"))))
    #expect(
      try main.events().events == [
        Self.transition("a", second: 1), Self.transition("b", second: 2),
      ])
  }

  @Test(
    "the latest merge's post commit is read from the log, nil before any merge, and a damaged log refuses — catches main checked against a stale or partial log"
  )
  func lastMergePostCommit() async throws {
    let repo = try await Self.repository()
    defer { repo.remove() }
    let store = try await Self.create(repo.adapter)
    try await store.append(Self.transition("a", second: 1))
    #expect(try store.lastMergePostCommit() == nil)

    try await store.append(
      .merge(.init(task: "a", preCommit: "p1", postCommit: "c1", at: Self.startedAt)))
    try await store.append(Self.transition("b", second: 2))
    try await store.append(
      .merge(.init(task: "b", preCommit: "c1", postCommit: "c2", at: Self.startedAt)))
    try await store.append(Self.transition("c", second: 3))
    #expect(try store.lastMergePostCommit() == "c2")

    let handle = try #require(FileHandle(forWritingAtPath: store.layout.eventsFile))
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(#"{"kind":"merge""#.utf8))
    try handle.close()
    #expect(throws: BuildRunStoreError.damagedLog([.tornLastLine(line: 6)])) {
      _ = try store.lastMergePostCommit()
    }
  }

  @Test(
    "an undo after the newest merge makes its toCommit where main should be, and a later merge's post commit wins again — catches every merge after an undo refused as main moved"
  )
  func undoMovesTheExpectedMain() async throws {
    let repo = try await Self.repository()
    defer { repo.remove() }
    let store = try await Self.create(repo.adapter)
    try await store.append(
      .merge(.init(task: "a", preCommit: "p1", postCommit: "c1", at: Self.startedAt)))
    try await store.append(
      .undo(.init(task: "a", fromCommit: "c1", toCommit: "p1", at: Self.startedAt)))
    #expect(try store.lastMergePostCommit() == "p1")

    try await store.append(
      .merge(.init(task: "a", preCommit: "p1", postCommit: "c2", at: Self.startedAt)))
    #expect(try store.lastMergePostCommit() == "c2")
    #expect(try store.events().events.map(\.kind) == [.merge, .undo, .merge])
  }

  @Test(
    "an events log written before the undo kind existed still decodes whole — catches the new kind breaking older runs' logs"
  )
  func oldFormatLogDecodes() {
    let lines = [
      #"{"at":"2026-09-26T10:00:00Z","from":"pending","kind":"transition","task":"a","to":"in-progress"}"#,
      #"{"at":"2026-09-26T10:05:00Z","kind":"merge","postCommit":"c1","preCommit":"p1","task":"a"}"#,
    ]
    let log = BuildEventJSON.decode(Data((lines.joined(separator: "\n") + "\n").utf8))

    #expect(log.damage == [])
    #expect(log.events.map(\.kind) == [.transition, .merge])
    #expect(log.lastMergePostCommit == "c1")
  }

  @Test(
    "run ids and plan names that aren't one path component are refused — catches a run addressing another plan's files",
    arguments: ["..", "a/b", ".hidden", ""])
  func invalidRunIDRefused(runID: String) async throws {
    let repo = try await Self.repository()
    defer { repo.remove() }
    await #expect(throws: BuildRunStoreError.invalidRunID(runID)) {
      _ = try await BuildRunStore.open(plan: "search", runID: runID, git: repo.adapter)
    }
    await #expect(throws: BuildRunStoreError.invalidPlanName("x/y")) {
      _ = try await BuildRunStore.open(plan: "x/y", runID: "r", git: repo.adapter)
    }
  }
}
