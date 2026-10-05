import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

/// The reader's event query starts at the run, so a long-lived store's history isn't read on
/// every poll.
@Suite("run view reader window")
struct RunViewReaderWindowTests {
  typealias Repository = RunViewReaderTests.Repository

  @Test(
    "a halt naming the build run from 2 days before it started isn't read, while the run's own halts are — catches a reader that keeps scanning every past event"
  )
  func eventBeforeTheRunIsNotRead() throws {
    let repository = try Repository()
    defer { repository.remove() }
    let file = repository.events.appending(path: "build.jsonl")
    try repository.write(try RunViewReaderTests.lines("events/build.jsonl"), to: file)
    let before = try #require(
      RunViewEventWindow.startTime(of: RunViewReaderTests.buildRun)?.addingTimeInterval(-2 * 86_400))
    try HarnessEventFiles(root: repository.checkout).append(
      HarnessEvent(
        eventID: "halt-2-days-early", time: before, source: HarnessEventSource(route: nil),
        payload: .buildHalt(
          BuildHaltEvent(buildRun: RunViewReaderTests.buildRun, task: nil, reason: .stall))))

    let ids = Set(try repository.read().events.map(\.eventID))
    #expect(!ids.contains("halt-2-days-early"))
    #expect(ids.contains("5F0836DD-38FC-465D-8B06-ED54F3D05CB0"))
  }

  @Test(
    "a sealed segment whose index ends before the run started is never opened, so its unreadable body is no damage — catches a reader that decompresses all history"
  )
  func sealedHistoryIsNotOpened() throws {
    let repository = try Repository()
    defer { repository.remove() }
    let sealed = StateRoot.tree(repository.checkout).url(EventSegmentLayout.sealedDirectory(.build))
    try Repository.make(sealed)
    let old = Date(timeIntervalSince1970: 1_700_000_000)
    let index = EventSegmentIndex(
      firstTime: old, lastTime: old.addingTimeInterval(60), lines: 1, bytes: 10,
      compressedBytes: 10, sha256: String(repeating: "0", count: 64),
      runIDs: [RunViewReaderTests.buildRun])
    try index.encoded().write(to: sealed.appending(path: EventSegmentLayout.indexName(1)))
    try Data("not lzfse".utf8).write(
      to: sealed.appending(path: EventSegmentLayout.compressedName(1)))

    let input = try repository.read()
    #expect(!input.damage.contains { $0.source.contains("sealed") }, "\(input.damage)")
  }

  @Test(
    "the newest build run by name is the greatest run directory of any plan, and none when no plan has one — catches a server that keeps showing an old run after build start"
  )
  func newestBuildRunByName() throws {
    let repository = try Repository()
    defer { repository.remove() }
    let reader = RunViewReader(commonDirectory: repository.common, stateRoot: .tree(repository.checkout))
    #expect(reader.newestBuildRunName() == RunViewReaderTests.buildRun)
    let later = "20261005T000000Z-00000001"
    try Repository.make(
      repository.common.appending(
        path: "swift-harness/plans/another-plan/build/\(later)", directoryHint: .isDirectory))
    try Repository.make(
      repository.common.appending(
        path: "swift-harness/plans/another-plan/build/not a run", directoryHint: .isDirectory))
    #expect(reader.newestBuildRunName() == later)

    let empty = try Repository()
    defer { empty.remove() }
    try FileManager.default.removeItem(
      at: empty.common.appending(path: "swift-harness/plans", directoryHint: .isDirectory))
    #expect(
      RunViewReader(commonDirectory: empty.common, stateRoot: .tree(empty.checkout))
        .newestBuildRunName() == nil)
  }
}
