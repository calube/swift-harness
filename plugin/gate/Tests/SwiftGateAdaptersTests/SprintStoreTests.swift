import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Synchronization
import Testing

/// Each test's sprint state lives under a throwaway repository's git common dir, never this
/// checkout's, which every sibling worktree shares.
private struct SprintScenario {
  static let base = String(repeating: "a", count: 40)
  static let surface = String(repeating: "b", count: 40)

  let repo: TemporaryGitRepository
  let layout: PlanStateLayout

  init() async throws {
    repo = try await TemporaryGitRepository()
    layout = try PlanStateLayout(commonDirectory: try await repo.adapter.commonDirectory())
  }

  var sprintFile: String { layout.root + "/sprint.json" }

  func store(timeout: Duration = .seconds(30)) -> SprintStore {
    SprintStore(layout: layout, lock: Self.lock(layout), timeout: timeout)
  }

  /// The plan-state root's lock, polled fast so contended tests don't wait on the default
  /// interval; the lock files are the same ones `index.json`'s store takes.
  static func lock(_ layout: PlanStateLayout) -> FileCountingLock {
    FileCountingLock(
      directory: URL(filePath: layout.root, directoryHint: .isDirectory),
      name: PlanIndexStore.lockName, capacity: 1, pollInterval: .milliseconds(2))
  }

  static func start(slices: Int) -> SprintEvent {
    .start(
      slug: "notes-search", specPage: "docs/sprints/notes-search.md", baseCommit: base,
      sliceCount: slices)
  }

  func contents() -> Data? { FileManager.default.contents(atPath: sprintFile) }

  func remove() { repo.remove() }
}

@Suite("Sprint store")
struct SprintStoreTests {
  @Test(
    "a started sprint lands in the plan-state root of the repository's git common dir and reads back — catches sprint state written per worktree or not at all"
  )
  func writesUnderCommonDirectory() async throws {
    let scenario = try await SprintScenario()
    defer { scenario.remove() }
    let located = try await SprintStore.locate(git: scenario.repo.adapter)
    #expect(
      located.path
        == CanonicalPath.of(scenario.repo.root.appending(path: ".git"))
        + "/swift-harness/plans/sprint.json")
    #expect(try located.read() == nil)

    let started = try await located.apply(SprintScenario.start(slices: 2))

    #expect(started.step == .started)
    #expect(try located.read() == started)
    let bytes = try #require(scenario.contents())
    #expect(try SprintRunJSON.decode(bytes) == started)
    #expect(try bytes == SprintRunJSON.encode(started))
  }

  @Test(
    "a refused transition leaves sprint.json byte-identical and names the expected step — catches an out-of-order command half-applied"
  )
  func refusalLeavesFile() async throws {
    let scenario = try await SprintScenario()
    defer { scenario.remove() }
    let store = scenario.store()
    try await store.apply(SprintScenario.start(slices: 2))
    let before = scenario.contents()

    let error = await #expect(throws: SprintStoreError.self) {
      try await store.apply(.slice(1, gateRun: "20260927T231701Z-cb69701e"))
    }

    #expect(error == .transition(.outOfOrder(attempted: .slice(1), expected: .surface)))
    #expect(scenario.contents() == before)
  }

  @Test(
    "a malformed sprint.json fails the update naming its field and is never overwritten — catches a corrupt file replaced by a fresh sprint"
  )
  func malformedFileNotClobbered() async throws {
    let scenario = try await SprintScenario()
    defer { scenario.remove() }
    let store = scenario.store()
    try await store.apply(SprintScenario.start(slices: 2))
    let original = String(decoding: try #require(scenario.contents()), as: UTF8.self)
    let corrupt = original.replacingOccurrences(
      of: "\"name\" : \"started\"", with: "\"name\" : \"paused\"")
    try #require(corrupt != original)
    try Data(corrupt.utf8).write(to: URL(filePath: scenario.sprintFile))

    let error = await #expect(throws: SprintStoreError.self) {
      try await store.apply(SprintScenario.start(slices: 1))
    }

    guard case .malformed(let path, .invalid(let field, _)) = error else {
      Issue.record("expected a malformed file, got \(String(describing: error))")
      return
    }
    #expect(path == scenario.sprintFile)
    #expect(field == "step.name")
    #expect(throws: SprintStoreError.self) { try store.read() }
    #expect(scenario.contents() == Data(corrupt.utf8))
  }

  @Test(
    "4 writers racing every slice of a 60-slice sprint each win distinct slices and lose none — catches an unlocked read-modify-write of sprint.json"
  )
  func concurrentWritersLoseNothing() async throws {
    let scenario = try await SprintScenario()
    defer { scenario.remove() }
    let sliceCount = 60
    try await scenario.store().apply(SprintScenario.start(slices: sliceCount))
    try await scenario.store().apply(.surface(commit: SprintScenario.surface))

    // Each writer reads the next slice without the lock, then races the others to take it. The
    // lock makes exactly one of them win each slice; a lost update shows up as 2 writers both
    // winning 1 slice, or a slice whose recorded run isn't its winner's.
    let wins = try await withThrowingTaskGroup(of: [Int: String].self) { group in
      for writer in 0..<4 {
        group.addTask { try await Self.takeSlices(writer: writer, store: scenario.store()) }
      }
      var all: [[Int: String]] = []
      for try await won in group { all.append(won) }
      return all
    }

    let run = try #require(try scenario.store().read())
    #expect(run.step == .slicing(sliceCount))
    #expect(wins.map(\.count).reduce(0, +) == sliceCount)
    let merged = wins.reduce(into: [Int: String]()) { $0.merge($1) { first, _ in first } }
    #expect(run.slices.map(\.gateRun) == (1...sliceCount).map { merged[$0] })
  }

  /// Takes whichever slice is next until none is left, returning the slices this writer won.
  private static func takeSlices(writer: Int, store: SprintStore) async throws -> [Int: String] {
    var won: [Int: String] = [:]
    while case .slice(let n)? = try store.read()?.next {
      let gateRun = "20260927T231700Z-\(writer)\(n)"
      do {
        try await store.apply(.slice(n, gateRun: gateRun))
        won[n] = gateRun
      } catch .transition(.outOfOrder) {
        continue
      }
    }
    return won
  }

  @Test(
    "a crash between writing the staged file and renaming it leaves the previous sprint.json readable and whole — catches sprint.json written in place"
  )
  func crashBeforeRenameKeepsPrevious() async throws {
    let scenario = try await SprintScenario()
    defer { scenario.remove() }
    try await scenario.store().apply(SprintScenario.start(slices: 2))
    let before = try #require(scenario.contents())
    let staged = StagedPath()
    let crashing = SprintStore(
      layout: scenario.layout, lock: SprintScenario.lock(scenario.layout), timeout: .seconds(30),
      beforeRename: { path in
        staged.record(path, contents: FileManager.default.contents(atPath: path))
        throw SimulatedCrash()
      })

    await #expect(throws: SprintStoreError.self) {
      try await crashing.apply(.surface(commit: SprintScenario.surface))
    }

    let (path, stagedBytes) = try #require(staged.value)
    #expect(path != scenario.sprintFile)
    #expect(URL(filePath: path).deletingLastPathComponent().path == scenario.layout.root)
    let stagedRun = try SprintRunJSON.decode(try #require(stagedBytes))
    #expect(stagedRun.step == .surfaced)
    #expect(scenario.contents() == before)
    #expect(try scenario.store().read()?.step == .started)
    let resumed = try await scenario.store().apply(.surface(commit: SprintScenario.surface))
    #expect(resumed.step == .surfaced)
  }

  @Test(
    "an update waits while index.json's store holds the plan-state lock — catches sprint.json guarded by a lock of its own"
  )
  func sharesIndexLock() async throws {
    let scenario = try await SprintScenario()
    defer { scenario.remove() }
    try await scenario.store().apply(SprintScenario.start(slices: 2))
    let before = scenario.contents()
    let holder = try await FileCountingLock(
      directory: URL(filePath: scenario.layout.root, directoryHint: .isDirectory),
      name: "index.lock", capacity: 1
    ).acquire(timeout: .seconds(5))
    defer { holder.release() }

    let error = await #expect(throws: SprintStoreError.self) {
      try await SprintStore(layout: scenario.layout, timeout: .milliseconds(200))
        .apply(.surface(commit: SprintScenario.surface))
    }

    #expect(error == .lock(.timedOut(waited: .milliseconds(200), capacity: 1)))
    #expect(scenario.contents() == before)
  }

  @Test(
    "a full volume fails the staged write, leaves sprint.json absent and removes the half-written staging file — catches a partial staging file left beside sprint.json",
    .enabled(if: FileSystemConditions.hasDiskImages, "needs hdiutil to attach a FAT volume"))
  func fullVolumeRemovesStagingFile() async throws {
    try await FATVolume.with { volume in
      let layout = try PlanStateLayout(commonDirectory: volume.mountPoint.path)
      try FileManager.default.createDirectory(
        atPath: layout.root, withIntermediateDirectories: true)
      // The lock lives off the volume so only the staged write runs out of space.
      let lockDirectory = try FileSystemConditions.scratchDirectory("sprint-lock")
      defer { TestTemporaryDirectory.remove(lockDirectory) }
      let store = SprintStore(
        layout: layout,
        lock: FileCountingLock(
          directory: lockDirectory, name: PlanIndexStore.lockName, capacity: 1,
          pollInterval: .milliseconds(2)),
        timeout: .seconds(30))
      try volume.fill()

      let error = await #expect(throws: SprintStoreError.self) {
        try await store.apply(SprintScenario.start(slices: 1))
      }

      guard case .io(let operation, let path, _) = error else {
        Issue.record("expected an io error, got \(String(describing: error))")
        return
      }
      #expect(operation == "write")
      #expect(path.hasPrefix(layout.root + "/.sprint.json."))
      #expect(error?.leftoverStaging == nil)
      #expect(FileSystemConditions.contents(of: layout.root).isEmpty)
      #expect(try store.read() == nil)
    }
  }

  @Test(
    "a failed write whose staging file can't be removed names that file in the error and leaves sprint.json as it was — catches a leftover staging file going unreported",
    .enabled(if: FileSystemConditions.permissionsDeny, "root ignores directory permissions"))
  func unremovableStagingIsReported() async throws {
    let scenario = try await SprintScenario()
    defer { scenario.remove() }
    try await scenario.store().apply(SprintScenario.start(slices: 2))
    let before = scenario.contents()
    let root = scenario.layout.root
    // A directory that can't be written to can't have its entries unlinked.
    let crashing = SprintStore(
      layout: scenario.layout, lock: SprintScenario.lock(scenario.layout), timeout: .seconds(30),
      beforeRename: { _ in
        try FileSystemConditions.setMode(0o555, root)
        throw SimulatedCrash()
      })
    defer { try? FileSystemConditions.setMode(0o755, root) }

    let error = await #expect(throws: SprintStoreError.self) {
      try await crashing.apply(.surface(commit: SprintScenario.surface))
    }
    try FileSystemConditions.setMode(0o755, root)

    let leftover = try #require(error?.leftoverStaging)
    #expect(leftover.hasPrefix(root + "/.sprint.json."))
    #expect(FileManager.default.fileExists(atPath: leftover))
    guard case .stagingLeft(let operation, _, _, _, let removal) = error else {
      Issue.record("expected stagingLeft, got \(String(describing: error))")
      return
    }
    #expect(operation == "stage")
    #expect(!removal.isEmpty)
    #expect(scenario.contents() == before)
  }
}

private struct SimulatedCrash: Error {}

private final class StagedPath: Sendable {
  private let storage = Mutex<(String, Data?)?>(nil)

  func record(_ path: String, contents: Data?) { storage.withLock { $0 = (path, contents) } }

  var value: (String, Data?)? { storage.withLock { $0 } }
}
