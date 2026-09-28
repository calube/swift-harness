import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import Testing

@Suite("Session record store")
struct SessionRecordStoreTests {
  static let hash = String(repeating: "0f", count: 32)

  static func record(_ id: String, at seconds: TimeInterval = 1_790_000_000) throws
    -> SessionRecord
  {
    try SessionRecord(
      sessionId: id, recordedAt: Date(timeIntervalSince1970: seconds),
      pluginRoot: "/plugins/swift-harness", pluginVersion: "0.1.0", treeHash: hash,
      transcriptPath: nil)
  }

  /// Backdates a record file so prune order doesn't depend on how fast the writes ran.
  static func age(_ url: URL, secondsAgo: TimeInterval) throws {
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSinceNow: -secondsAgo)], ofItemAtPath: url.path)
  }

  static func recordFiles(_ store: SessionRecordStore) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: store.directoryURL.path)) ?? [])
      .filter { $0.hasSuffix(".json") }.sorted()
  }

  @Test(
    "a written record reads back by session id from .harness/hook-state/sessions/<id>.json, and a temp repo's git status stays clean — catches a record ship's clean-tree preflight trips over"
  )
  func writeReadsBackIgnored() async throws {
    let repository = try await TemporaryGitRepository()
    defer { repository.remove() }
    try repository.write("README.md", "x\n")
    try await repository.git("add", "README.md")
    try await repository.git("commit", "-q", "-m", "init")
    let store = SessionRecordStore(worktreeRoot: repository.root)
    let record = try Self.record("session-a")

    try store.write(record)

    let file = repository.root.appending(path: ".harness/hook-state/sessions/session-a.json")
    #expect(try SessionRecord.decode(Data(contentsOf: file)) == record)
    #expect(try store.file(sessionID: "session-a") == file)
    #expect(try store.record(sessionID: "session-a") == record)
    #expect(try store.record(sessionID: "session-b") == nil)
    #expect(try await repository.git("status", "--porcelain", "--untracked-files=all") == "")
  }

  @Test(
    "an unsafe session id names no file and a lookup refuses it, leaving the directory untouched — catches '/', '..' or an empty id reading or writing outside the records directory"
  )
  func unsafeIdsTouchNothing() throws {
    let scratch = try FileSystemConditions.scratchDirectory("session-unsafe")
    defer { try? FileManager.default.removeItem(at: scratch) }
    let root = scratch.appending(path: "repo", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = SessionRecordStore(worktreeRoot: root)
    for id in ["", "/", "..", "../x", "../../escape"] {
      #expect(throws: SessionRecordStoreError.unsafeSessionID(id)) {
        try store.file(sessionID: id)
      }
      #expect(throws: SessionRecordStoreError.unsafeSessionID(id)) {
        try store.record(sessionID: id)
      }
    }
    #expect(FileSystemConditions.contents(of: scratch.path) == ["repo"])
  }

  @Test(
    "the 21st record prunes the oldest by write time, and rewriting a kept session prunes nothing — catches records piling up forever or a prune that eats the newest"
  )
  func prunesToTwenty() throws {
    let scratch = try FileSystemConditions.scratchDirectory("session-prune")
    defer { try? FileManager.default.removeItem(at: scratch) }
    let store = SessionRecordStore(worktreeRoot: scratch)
    for index in 0..<20 {
      try store.write(try Self.record("s\(index)", at: 1_790_000_000 + Double(index)))
      try Self.age(try store.file(sessionID: "s\(index)"), secondsAgo: Double(1000 - index))
    }
    #expect(Self.recordFiles(store).count == 20)

    try store.write(try Self.record("s5", at: 1_790_000_100))
    #expect(Self.recordFiles(store).count == 20)

    try store.write(try Self.record("s20", at: 1_790_000_200))
    let kept = Self.recordFiles(store)
    #expect(kept.count == 20)
    #expect(!kept.contains("s0.json"))
    #expect(kept.contains("s20.json") && kept.contains("s1.json") && kept.contains("s5.json"))
  }

  @Test(
    "sessions starting at once, with the store already full, all keep their records — catches a racing write or prune losing a fresh session's record"
  )
  func concurrentStartsKeepEveryRecord() async throws {
    for round in 0..<10 {
      let scratch = try FileSystemConditions.scratchDirectory("session-race")
      defer { try? FileManager.default.removeItem(at: scratch) }
      let store = SessionRecordStore(worktreeRoot: scratch)
      for index in 0..<19 {
        try store.write(try Self.record("old\(index)"))
        try Self.age(try store.file(sessionID: "old\(index)"), secondsAgo: Double(1000 - index))
      }
      let fresh = (0..<4).map { "fresh\(round)-\($0)" }
      try await withThrowingTaskGroup(of: Void.self) { group in
        for id in fresh {
          let record = try Self.record(id)
          group.addTask { try store.write(record) }
        }
        try await group.waitForAll()
      }
      let kept = Self.recordFiles(store)
      #expect(kept.count == 20, "round \(round): \(kept)")
      for id in fresh {
        #expect(try store.record(sessionID: id) != nil, "round \(round) lost \(id)")
      }
    }
  }

  @Test(
    "a reader racing a session that re-records itself always reads a whole record, old or new — catches a write that truncates the file in place"
  )
  func rewriteIsAtomic() async throws {
    let scratch = try FileSystemConditions.scratchDirectory("session-atomic")
    defer { try? FileManager.default.removeItem(at: scratch) }
    let store = SessionRecordStore(worktreeRoot: scratch)
    let long = "/t/" + String(repeating: "x", count: 64 * 1024)
    let records = try (0..<2).map { index in
      try SessionRecord(
        sessionId: "session-a", recordedAt: Date(timeIntervalSince1970: Double(index)),
        pluginRoot: "/plugins/swift-harness", pluginVersion: "0.1.0", treeHash: Self.hash,
        transcriptPath: long + "\(index)")
    }
    try store.write(records[0])
    let torn = try await withThrowingTaskGroup(of: Int.self) { group in
      group.addTask {
        for index in 0..<300 { try store.write(records[index % 2]) }
        return 0
      }
      group.addTask {
        var torn = 0
        for _ in 0..<3000 {
          let read: SessionRecord?
          do {
            read = try store.record(sessionID: "session-a")
          } catch {
            Issue.record(error, "a reader saw a partial record")
            return torn + 1
          }
          if read.map(records.contains) != true { torn += 1 }
        }
        return torn
      }
      return try await group.reduce(0, +)
    }
    #expect(torn == 0)
  }

  @Test(
    "an unwritable hook-state directory fails the write naming the path — catches a record silently not written",
    .enabled(if: FileSystemConditions.permissionsDeny, "chmod denies nothing to root"))
  func unwritableFails() throws {
    let scratch = try FileSystemConditions.scratchDirectory("session-unwritable")
    let hookState = scratch.appending(path: ".harness/hook-state", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: hookState, withIntermediateDirectories: true)
    try FileSystemConditions.setMode(0o500, hookState.path)
    defer {
      try? FileSystemConditions.setMode(0o700, hookState.path)
      try? FileManager.default.removeItem(at: scratch)
    }
    let store = SessionRecordStore(worktreeRoot: scratch)
    let record = try Self.record("session-a")
    do {
      try store.write(record)
      Issue.record("the write succeeded into a read-only directory")
    } catch {
      guard case .unwritable(let path, _) = error else {
        Issue.record("\(error)")
        return
      }
      #expect(path.hasPrefix(hookState.path))
    }
  }

  @Test(
    "a scan returns the newest record by recordedAt and names a corrupt record file instead of dropping it — catches doctor reading the wrong session or a corrupt record vanishing silently"
  )
  func scanNamesNewestAndCorrupt() throws {
    let scratch = try FileSystemConditions.scratchDirectory("session-scan")
    defer { try? FileManager.default.removeItem(at: scratch) }
    let store = SessionRecordStore(worktreeRoot: scratch)
    try store.write(try Self.record("late", at: 1_790_000_500))
    try store.write(try Self.record("early", at: 1_790_000_100))
    let corrupt = store.directoryURL.appending(path: "broken.json")
    try Data("{".utf8).write(to: corrupt)

    let scan = store.scan()

    #expect(scan.newest?.sessionId == "late")
    #expect(Set(scan.records.map(\.sessionId)) == ["late", "early"])
    #expect(scan.unreadable.map(\.path) == [corrupt.path])
    #expect(throws: SessionRecordStoreError.self) { try store.record(sessionID: "broken") }
  }
}
