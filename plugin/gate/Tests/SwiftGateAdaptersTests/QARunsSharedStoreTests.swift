import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@Suite("qa runs: a run's report outlives the checkout it ran in")
struct QARunsSharedStoreTests {
  static let qaRunID = "20261005T120000Z-0000aaaa"

  /// A configured clone with 1 linked worktree, as a build's slot is.
  static func cloneWithSlot(_ name: String) async throws -> (TemporaryGitRepository, URL) {
    let repository = try await StateRootResolverTests.clone(configured: true)
    let slot = repository.root.deletingLastPathComponent()
      .appending(
        path: "\(repository.root.lastPathComponent)-\(name)", directoryHint: .isDirectory)
    try await repository.git("worktree", "add", "-q", "-b", name, slot.path)
    return (repository, slot)
  }

  static func qaReport() throws -> Data {
    try Fixture.data("BrownfieldTrial/send-money-6-qa-before-account-client-amount-feature.json")
  }

  static func keptRoot(_ repository: TemporaryGitRepository) throws -> StateRoot {
    try #require(
      StateRootResolver.keptRuns(
        commonDir: repository.root.appending(path: ".git", directoryHint: .isDirectory)))
  }

  @Test(
    "a qa run in a slot of a configured clone writes its run directory under the common dir, so the report path it names still reads once the slot is removed — catches briefs citing a report path that didn't exist while the slot lived, or after it went"
  )
  func slotRunWritesTheSharedStore() async throws {
    let (repository, slot) = try await Self.cloneWithSlot("slot-run")
    defer {
      repository.remove()
      try? FileManager.default.removeItem(at: slot)
    }
    let report = try RunStore.qaRuns(worktree: slot).runDirectory(for: Self.qaRunID)
      .appending(path: "\(QAReport.directory)/\(QAReport.fileName)")
    try FileManager.default.createDirectory(
      at: report.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Self.qaReport().write(to: report)

    #expect(
      StateRootResolverTests.canonical(report)
        == StateRootResolverTests.canonical(
          try Self.keptRoot(repository).url(RunLayout.runDirectory(for: Self.qaRunID)))
        + "/qa/report.json")
    try await repository.git("worktree", "remove", "--force", slot.path)
    #expect(try Data(contentsOf: report) == Self.qaReport())
  }

  @Test(
    "keeping a slot's runs fills in a run directory the clone already holds part of, such as the events a command in the main checkout wrote for that run — catches a slot's at-base report lost because its run id was already under the common dir"
  )
  func keepFillsAPartlyKeptRun() async throws {
    let (repository, slot) = try await Self.cloneWithSlot("slot-keep")
    defer {
      repository.remove()
      try? FileManager.default.removeItem(at: slot)
    }
    let inSlot = try RunStore(worktreeRoot: slot).runDirectory(for: Self.qaRunID)
      .appending(path: QAReport.directory, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: inSlot, withIntermediateDirectories: true)
    try Self.qaReport().write(to: inSlot.appending(path: QAReport.fileName))
    try HarnessEventFiles(root: repository.root).append(
      EventSegmentStoreTests.decision("main-checkout", runID: Self.qaRunID))
    let kept = try Self.keptRoot(repository)
    let keptEvents = kept.url(RunLayout.runEventsFile(.judge, runID: Self.qaRunID))
    #expect(FileManager.default.fileExists(atPath: keptEvents.path))

    let outcome = try RunStore(worktreeRoot: slot).keepRuns(into: kept)
    try await repository.git("worktree", "remove", "--force", slot.path)

    #expect(outcome == RunKeepOutcome(kept: [Self.qaRunID], unkept: []))
    #expect(
      try Data(
        contentsOf: kept.url(RunLayout.runDirectory(for: Self.qaRunID))
          .appending(path: "\(QAReport.directory)/\(QAReport.fileName)")) == Self.qaReport())
    #expect(
      try String(contentsOf: keptEvents, encoding: .utf8).contains("main-checkout"),
      "what the clone already held stays")
  }

  @Test(
    "keeping a slot's runs keeps its history lines apart from the clone's own history, once each however often it is kept, so a run recorded in the slot is still found after the slot is removed — catches a removed slot taking its history with it"
  )
  func keepKeepsHistoryLines() async throws {
    let (repository, slot) = try await Self.cloneWithSlot("slot-history")
    defer {
      repository.remove()
      try? FileManager.default.removeItem(at: slot)
    }
    try RunStore(worktreeRoot: slot).record(
      try StateRootResolverTests.report(), finishedAt: Date(timeIntervalSince1970: 1_790_000_000))
    let kept = try Self.keptRoot(repository)

    _ = try RunStore(worktreeRoot: slot).keepRuns(into: kept)
    _ = try RunStore(worktreeRoot: slot).keepRuns(into: kept)
    try await repository.git("worktree", "remove", "--force", slot.path)

    let found = try RunStore.historyRecord(
      runID: StateRootResolverTests.runID, sharing: repository.root)
    #expect(found?.runID == StateRootResolverTests.runID)
    let keptLines = try String(
      contentsOf: kept.url(RunLayout.keptHistoryFile), encoding: .utf8
    ).split(separator: "\n")
    #expect(keptLines.count == 1)
    #expect(
      !FileManager.default.fileExists(atPath: kept.url(RunLayout.historyFile).path),
      "the clone's own history counts only its own runs")
  }
}
