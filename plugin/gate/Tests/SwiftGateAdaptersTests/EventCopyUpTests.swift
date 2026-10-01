import Darwin
import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import Synchronization
import Testing

@Suite("event copy-up: a worktree's events into the main checkout's imported stores")
struct EventCopyUpTests {
  typealias Store = EventSegmentStoreTests

  /// A main checkout and a task worktree, each a temp directory.
  struct Checkouts {
    let main = Store.temporaryRoot()
    let worktree = Store.temporaryRoot()

    var copyUp: EventCopyUp { EventCopyUp(source: worktree, destination: main) }
    var imported: URL { main.appending(path: EventCopyUp.importedDirectory) }

    func storeID(_ root: URL? = nil) throws -> String {
      let data = try Data(
        contentsOf: (root ?? worktree).appending(path: EventSegmentLayout.storeFile))
      return try JSONDecoder().decode(EventStoreIdentity.self, from: data).storeID
    }

    func remove() {
      for root in [main, worktree] { try? FileManager.default.removeItem(at: root) }
    }
  }

  /// Every regular file under `root`, relative, with its bytes.
  static func contents(_ root: URL) throws -> [String: Data] {
    var found: [String: Data] = [:]
    for path in try FileManager.default.subpathsOfDirectory(atPath: root.path) {
      let url = root.appending(path: path)
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
        !isDirectory.boolValue
      else { continue }
      found[path] = try Data(contentsOf: url)
    }
    return found
  }

  static func inode(_ url: URL) -> UInt64? {
    var info = stat()
    guard stat(url.path, &info) == 0 else { return nil }
    return UInt64(info.st_ino)
  }

  @Test(
    "a worktree's store, sealed segments and every stream's active file, lands whole under imported/<storeID>/ and nowhere else, read once beside main's own — catches a copy into main's own active files"
  )
  func copiesIntoImportedOnly() throws {
    let checkouts = Checkouts()
    defer { checkouts.remove() }
    try HarnessEventFiles(root: checkouts.main).append(Store.decision("main-own", second: 0))
    let mainActive = checkouts.main.appending(path: RunLayout.eventsFile(.judge))
    let mainBefore = try Data(contentsOf: mainActive)
    // Every write past 1 byte rotates, so the first batch is sealed and the last stays active.
    let sealing = HarnessEventFiles(root: checkouts.worktree, rotationBytes: { _ in 1 })
    try sealing.append(Store.decision("sealed", second: 1))
    try HarnessEventFiles(root: checkouts.worktree).append(contentsOf: [
      Store.decision("active", second: 2),
      HarnessEvent(
        eventID: "gate-step", time: Date(timeIntervalSince1970: 1_790_000_003),
        source: HarnessEventSource(route: .check, tier: .push),
        payload: .gateStep(
          GateStepEvent(
            GateStepTiming(
              step: .appBuild, tier: nil, milliseconds: 7, verdict: .green, derivedData: .warm)))
      ),
    ])
    let source = try Self.contents(checkouts.worktree.appending(path: RunLayout.eventsDirectory))
      .filter { $0.key != "store.lock" }
    #expect(source.keys.contains { $0.hasSuffix(".jsonl.lzfse") })
    #expect(source.keys.contains(HarnessEventStream.gate.fileName))

    let outcome = try checkouts.copyUp.run()

    let storeID = try checkouts.storeID()
    let bytes = source.values.map(\.count).reduce(0, +)
    #expect(outcome == .copied(storeID: storeID, bytes: bytes))
    let copied = try Self.contents(checkouts.imported.appending(path: storeID))
    #expect(copied == source)
    // Beside the import, only its lock.
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: checkouts.imported.path).sorted()
        == [".\(storeID).lock", storeID])
    #expect(try Data(contentsOf: mainActive) == mainBefore)
    let read = EventStoreReader(files: LiveEventStoreFiles(root: checkouts.main)).read(
      EventQuery())
    #expect(read.events.map(\.event.eventID) == ["main-own", "sealed", "active", "gate-step"])
    #expect(read.damage.isEmpty)
  }

  @Test(
    "a worktree with no events copies nothing, and one whose store has no identity yet gets one and is copied under it — catches an empty import or events left behind for want of a store id"
  )
  func identityAndEmptyStores() throws {
    let checkouts = Checkouts()
    defer { checkouts.remove() }
    #expect(try checkouts.copyUp.run() == .nothing)
    #expect(!FileManager.default.fileExists(atPath: checkouts.imported.path))

    let line = try HarnessEventJSON.encodeLine(Store.decision("before-identity"))
    let active = checkouts.worktree.appending(path: RunLayout.eventsFile(.judge))
    try FileManager.default.createDirectory(
      at: active.deletingLastPathComponent(), withIntermediateDirectories: true)
    try line.write(to: active)

    let outcome = try checkouts.copyUp.run()

    let storeID = try checkouts.storeID()
    guard case .copied(let copiedID, _) = outcome else {
      Issue.record("expected a copy, got \(outcome)")
      return
    }
    #expect(copiedID == storeID)
    #expect(
      try Data(contentsOf: checkouts.imported.appending(path: "\(storeID)/judge.jsonl")) == line)
  }

  @Test(
    "a second copy whose source holds more bytes replaces the import; one with equal or fewer bytes leaves it untouched — catches a stale import kept, or a whole store rewritten on every remove"
  )
  func replacesOnlyWhenLarger() throws {
    let checkouts = Checkouts()
    defer { checkouts.remove() }
    let writer = HarnessEventFiles(root: checkouts.worktree)
    try writer.append(Store.decision("first", second: 0))
    _ = try checkouts.copyUp.run()
    let storeID = try checkouts.storeID()
    let target = checkouts.imported.appending(path: storeID)
    let firstInode = Self.inode(target)

    let again = try checkouts.copyUp.run()

    let bytes = try Self.contents(target).values.map(\.count).reduce(0, +)
    #expect(again == .kept(storeID: storeID, bytes: bytes))
    #expect(Self.inode(target) == firstInode)

    try writer.append(Store.decision("second", second: 1))
    let grown = try checkouts.copyUp.run()

    guard case .copied(_, let grownBytes) = grown else {
      Issue.record("expected a copy, got \(grown)")
      return
    }
    #expect(grownBytes > bytes)
    let read = EventStoreReader(files: LiveEventStoreFiles(root: checkouts.main)).read(
      EventQuery())
    #expect(read.events.map(\.event.eventID) == ["first", "second"])
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: checkouts.imported.path).filter {
        !$0.hasSuffix(".lock")
      } == [storeID])

    let active = checkouts.worktree.appending(path: RunLayout.eventsFile(.judge))
    try Data().write(to: active)
    let inodeBeforeShrunk = Self.inode(target)
    guard case .kept = try checkouts.copyUp.run() else {
      Issue.record("a smaller source replaced the import")
      return
    }
    #expect(Self.inode(target) == inodeBeforeShrunk)
  }

  @Test(
    "a copy that fails partway throws naming the file, leaves the earlier import whole and leaves no temporary directory — catches events lost or half an import made visible"
  )
  func failedCopyKeepsEarlierImport() throws {
    let checkouts = Checkouts()
    defer { checkouts.remove() }
    let writer = HarnessEventFiles(root: checkouts.worktree)
    try writer.append(Store.decision("first", second: 0))
    _ = try checkouts.copyUp.run()
    let storeID = try checkouts.storeID()
    let target = checkouts.imported.appending(path: storeID)
    let earlier = try Self.contents(target)
    try writer.append(Store.decision("second", second: 1))
    let active = checkouts.worktree.appending(path: RunLayout.eventsFile(.judge))
    #expect(chmod(active.path, 0) == 0)
    defer { chmod(active.path, 0o644) }

    #expect {
      try checkouts.copyUp.run()
    } throws: { error in
      (error as? EventCopyUpError)?.path.hasSuffix("judge.jsonl") == true
    }
    #expect(try Self.contents(target) == earlier)
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: checkouts.imported.path).filter {
        !$0.hasSuffix(".lock")
      } == [storeID])
  }

  @Test(
    "2 worktrees copied at once, and 1 of them copied twice at once, each land whole and none fails — catches a race on the imported directory or 2 copies of 1 store renaming over each other"
  )
  func concurrentCopies() throws {
    let main = Store.temporaryRoot()
    let first = Store.temporaryRoot()
    let second = Store.temporaryRoot()
    defer {
      for root in [main, first, second] { try? FileManager.default.removeItem(at: root) }
    }
    try HarnessEventFiles(root: first).append(Store.decision("from-first", second: 0))
    try HarnessEventFiles(root: second).append(Store.decision("from-second", second: 1))
    let sources = [first, second, first]
    let outcomes = Mutex<[Int: Result<EventCopyUpOutcome, EventCopyUpError>]>([:])

    DispatchQueue.concurrentPerform(iterations: sources.count) { index in
      let result = Result { () throws(EventCopyUpError) -> EventCopyUpOutcome in
        try EventCopyUp(source: sources[index], destination: main).run()
      }
      outcomes.withLock { $0[index] = result }
    }

    let results = outcomes.withLock { $0 }
    for (index, result) in results {
      if case .failure(let error) = result { Issue.record("copy \(index) failed: \(error)") }
    }
    let copies = results.values.filter {
      if case .success(.copied) = $0 { true } else { false }
    }
    #expect(copies.count == 2)
    let read = EventStoreReader(files: LiveEventStoreFiles(root: main)).read(EventQuery())
    #expect(read.events.map(\.event.eventID) == ["from-first", "from-second"])
    #expect(read.damage.isEmpty)
    let imported = try FileManager.default.contentsOfDirectory(
      atPath: main.appending(path: EventCopyUp.importedDirectory).path)
    #expect(imported.filter { $0.hasPrefix(".") && !$0.hasSuffix(".lock") }.isEmpty)
  }
  @Test(
    "moving aside renames the worktree's whole store to the main checkout's unkept/<storeID>/, where the reader finds it, and falls back to the git common dir when that move fails — catches events copied instead of moved, or lost when the checkout can't take them"
  )
  func moveAsideRenamesWhole() throws {
    let checkouts = Checkouts()
    let common = Store.temporaryRoot()
    defer {
      checkouts.remove()
      try? FileManager.default.removeItem(at: common)
    }
    try HarnessEventFiles(root: checkouts.worktree).append(Store.decision("moved", second: 0))
    let events = checkouts.worktree.appending(path: RunLayout.eventsDirectory)
    let storeID = try checkouts.storeID()
    let activeInode = Self.inode(events.appending(path: HarnessEventStream.judge.fileName))

    let moved = try checkouts.copyUp.moveAside(commonDirectory: common)

    let target = checkouts.main.appending(path: "\(EventCopyUp.unkeptDirectory)/\(storeID)")
    #expect(moved == target.path)
    #expect(!FileManager.default.fileExists(atPath: events.path))
    #expect(Self.inode(target.appending(path: HarnessEventStream.judge.fileName)) == activeInode)
    let read = EventStoreReader(files: LiveEventStoreFiles(root: checkouts.main)).read(
      EventQuery())
    #expect(read.events.map(\.event.eventID) == ["moved"])

    let other = Store.temporaryRoot()
    defer { try? FileManager.default.removeItem(at: other) }
    try HarnessEventFiles(root: other).append(Store.decision("fallback", second: 1))
    let otherID = try checkouts.storeID(other)
    let blocked = Store.temporaryRoot()
    defer { try? FileManager.default.removeItem(at: blocked) }
    let unkept = blocked.appending(path: EventCopyUp.unkeptDirectory)
    try FileManager.default.createDirectory(
      at: unkept.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("in the way".utf8).write(to: unkept)

    let fellBack = try EventCopyUp(source: other, destination: blocked).moveAside(
      commonDirectory: common)

    #expect(
      fellBack == common.appending(path: "\(EventCopyUp.commonUnkeptDirectory)/\(otherID)").path)
    #expect(
      !FileManager.default.fileExists(atPath: other.appending(path: RunLayout.eventsDirectory).path)
    )
  }
}
