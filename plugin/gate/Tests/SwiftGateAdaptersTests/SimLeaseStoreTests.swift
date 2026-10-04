import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@Suite("SimLeaseStore")
struct SimLeaseStoreTests {
  let directory = TestTemporaryDirectory.root.appending(
    path: "sim-leases-\(UUID().uuidString)", directoryHint: .isDirectory)

  static func lease(_ runID: String, session: String? = nil) -> SimLease {
    SimLease(
      runID: runID, worktree: "/repos/app", udid: "MADE-1", holderPID: 4242, session: session)
  }

  @Test(
    "a written lease reads back, lists, and is gone once removed, and removing it again succeeds — catches a lease sim down can't clear"
  )
  func lifecycle() throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = SimLeaseStore(directory: directory)
    #expect(try store.read(runID: "r1") == nil)

    try store.write(Self.lease("r1"))
    try store.write(Self.lease("r2", session: "qa-2"))

    #expect(try store.read(runID: "r1") == Self.lease("r1"))
    #expect(try store.all().leases.map(\.runID).sorted() == ["r1", "r2"])
    try store.remove(runID: "r1")
    try store.remove(runID: "r1")
    #expect(try store.read(runID: "r1") == nil)
    #expect(
      try store.all()
        == SimLeaseListing(leases: [Self.lease("r2", session: "qa-2")], unreadable: []))
  }

  @Test(
    "a run id with a path separator is refused before anything is written — catches a lease written outside the lease directory"
  )
  func invalidRunID() throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = SimLeaseStore(directory: directory)
    #expect(throws: SimLeaseStoreError.invalidRunID("../escape")) {
      try store.write(Self.lease("../escape"))
    }
    #expect(throws: SimLeaseStoreError.invalidRunID("a/b")) { try store.read(runID: "a/b") }
    #expect(
      !FileManager.default.fileExists(
        atPath: directory.deletingLastPathComponent()
          .appending(path: "escape.json").path))
  }

  @Test(
    "a corrupt lease file is listed as unreadable naming its file while good leases still list — catches one bad file hiding every lease, or being skipped silently"
  )
  func corruptLeaseNamed() throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = SimLeaseStore(directory: directory)
    try store.write(Self.lease("good"))
    let bad = store.file(runID: "bad")
    try Data(#"{"runID":"bad"}"#.utf8).write(to: bad)

    let listing = try store.all()

    #expect(listing.leases.map(\.runID) == ["good"])
    #expect(listing.unreadable == [.unreadable(path: bad.path, reason: .missingKey("worktree"))])
    #expect(throws: SimLeaseStoreError.unreadable(path: bad.path, reason: .missingKey("worktree")))
    {
      try store.read(runID: "bad")
    }
  }

  @Test(
    "readers racing many rewriters of one lease always see a whole lease, and the last write wins — catches a lease written in place that a reader catches half-written"
  )
  func atomicRewrites() async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = SimLeaseStore(directory: directory)
    try store.write(Self.lease("r", session: "s-initial"))

    let torn = try await withThrowingTaskGroup(of: Int.self) { group in
      for writer in 0..<6 {
        group.addTask {
          for round in 0..<40 {
            try store.write(
              Self.lease(
                "r", session: "s-\(writer)-\(round)-" + String(repeating: "x", count: 4096)))
          }
          return 0
        }
      }
      for _ in 0..<3 {
        group.addTask {
          var failures = 0
          for _ in 0..<200 {
            do {
              if try store.read(runID: "r") == nil { failures += 1 }
            } catch {
              failures += 1
            }
          }
          return failures
        }
      }
      return try await group.reduce(0, +)
    }

    #expect(torn == 0)
    #expect(try store.read(runID: "r")?.session?.hasPrefix("s-") == true)
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    #expect(leftovers == ["r.json"], "temporary files left behind: \(leftovers)")
  }
}
