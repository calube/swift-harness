import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import Testing

/// Error paths of the exclusive-create lock behind `plan claim` and `plan release`, each driven by
/// a real filesystem state. Every one must leave the plan directory exactly as it found it: no
/// lock the guard would honour, and no staging file.
@Suite("PlanLock error paths")
struct PlanLockTests {
  static let alice = "5e0c7a1b-2d3f-4a6b-8c9d-0e1f2a3b4c5d"
  static let bob = "9a8b7c6d-5e4f-4a3b-2c1d-0e9f8a7b6c5d"

  private static func isIO(_ error: PlanLockError, mentioning fragment: String) -> Bool {
    guard case .io(let message) = error else { return false }
    return message.contains(fragment)
  }

  @Test(
    "an unreadable lock blocks claim, release and force-release and stays in place — catches an unreadable lock read as unclaimed and taken over",
    .enabled(if: FileSystemConditions.permissionsDeny, "chmod doesn't deny root"))
  func unreadableLockBlocks() throws {
    let common = try FileSystemConditions.scratchDirectory("lock")
    defer { try? FileManager.default.removeItem(at: common) }
    let plan = try PlanStateLayout(commonDirectory: common.path).plan("search")
    let lock = PlanLock(plan: plan)
    #expect(try lock.claim(session: Self.alice) == .claimed)
    try FileSystemConditions.setMode(0o000, plan.orchestratorLock)
    defer { chmod(plan.orchestratorLock, 0o644) }

    let claimError = try #require(throws: PlanLockError.self) { try lock.claim(session: Self.bob) }
    #expect(Self.isIO(claimError, mentioning: "reading \(plan.orchestratorLock)"))
    #expect(throws: PlanLockError.self) { try lock.release(session: Self.alice) }
    #expect(throws: PlanLockError.self) { try lock.forceRelease() }

    #expect(FileSystemConditions.contents(of: plan.directory) == ["orchestrator.lock"])
  }

  @Test(
    "a plan directory that can't be created blocks the claim — catches a claim reported as won with no lock on disk",
    .enabled(if: FileSystemConditions.permissionsDeny, "chmod doesn't deny root"))
  func uncreatablePlanDirectoryBlocks() throws {
    let common = try FileSystemConditions.scratchDirectory("lock")
    defer { try? FileManager.default.removeItem(at: common) }
    let layout = try PlanStateLayout(commonDirectory: common.path)
    try FileManager.default.createDirectory(atPath: layout.root, withIntermediateDirectories: true)
    try FileSystemConditions.setMode(0o500, layout.root)
    defer { chmod(layout.root, 0o755) }
    let plan = try layout.plan("search")

    let error = try #require(throws: PlanLockError.self) {
      try PlanLock(plan: plan).claim(session: Self.alice)
    }

    #expect(Self.isIO(error, mentioning: "creating \(plan.directory)"))
    #expect(FileSystemConditions.contents(of: layout.root).isEmpty)
  }

  @Test(
    "a plan directory without write permission blocks the claim at staging — catches a failed staging file mistaken for a won claim",
    .enabled(if: FileSystemConditions.permissionsDeny, "chmod doesn't deny root"))
  func unwritablePlanDirectoryBlocksStaging() throws {
    let common = try FileSystemConditions.scratchDirectory("lock")
    defer { try? FileManager.default.removeItem(at: common) }
    let plan = try PlanStateLayout(commonDirectory: common.path).plan("search")
    try FileManager.default.createDirectory(
      atPath: plan.directory, withIntermediateDirectories: true)
    try FileSystemConditions.setMode(0o500, plan.directory)
    defer { chmod(plan.directory, 0o755) }
    let lock = PlanLock(plan: plan)

    let claimError = try #require(throws: PlanLockError.self) {
      try lock.claim(session: Self.alice)
    }
    let seedError = try #require(throws: PlanLockError.self) {
      try lock.seedPlanFile(Data("{}".utf8))
    }

    #expect(Self.isIO(claimError, mentioning: "staging in \(plan.directory)"))
    #expect(Self.isIO(seedError, mentioning: "staging in \(plan.directory)"))
    #expect(FileSystemConditions.contents(of: plan.directory).isEmpty)
  }

  @Test(
    "a lock in a directory without write permission can't be released, and stays held — catches release reporting success while the lock survives",
    .enabled(if: FileSystemConditions.permissionsDeny, "chmod doesn't deny root"))
  func unremovableLockBlocksRelease() throws {
    let common = try FileSystemConditions.scratchDirectory("lock")
    defer { try? FileManager.default.removeItem(at: common) }
    let plan = try PlanStateLayout(commonDirectory: common.path).plan("search")
    let lock = PlanLock(plan: plan)
    #expect(try lock.claim(session: Self.alice) == .claimed)
    try FileSystemConditions.setMode(0o500, plan.directory)
    defer { chmod(plan.directory, 0o755) }

    let releaseError = try #require(throws: PlanLockError.self) {
      try lock.release(session: Self.alice)
    }
    let forceError = try #require(throws: PlanLockError.self) { try lock.forceRelease() }

    #expect(Self.isIO(releaseError, mentioning: "removing \(plan.orchestratorLock)"))
    #expect(Self.isIO(forceError, mentioning: "removing \(plan.orchestratorLock)"))
    #expect(try lock.holder() == Self.alice)
  }

  @Test(
    "a lock name taken by a dangling symlink blocks the claim instead of naming an empty holder — catches a lock no release or force-release can clear being reported as held"
  )
  func danglingSymlinkLockBlocks() throws {
    let common = try FileSystemConditions.scratchDirectory("lock")
    defer { try? FileManager.default.removeItem(at: common) }
    let plan = try PlanStateLayout(commonDirectory: common.path).plan("search")
    try FileManager.default.createDirectory(
      atPath: plan.directory, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      atPath: plan.orchestratorLock, withDestinationPath: plan.directory + "/missing")

    let error = try #require(throws: PlanLockError.self) {
      try PlanLock(plan: plan).claim(session: Self.alice)
    }

    #expect(Self.isIO(error, mentioning: plan.orchestratorLock))
    #expect(FileSystemConditions.contents(of: plan.directory) == ["orchestrator.lock"])
    #expect(
      try FileManager.default.destinationOfSymbolicLink(atPath: plan.orchestratorLock)
        == plan.directory + "/missing")
  }

  @Test(
    "seeding plan.json over an existing one reports false and keeps the original bytes — catches a re-claim clobbering a plan in progress"
  )
  func seedNeverOverwrites() throws {
    let common = try FileSystemConditions.scratchDirectory("lock")
    defer { try? FileManager.default.removeItem(at: common) }
    let plan = try PlanStateLayout(commonDirectory: common.path).plan("search")
    let lock = PlanLock(plan: plan)
    #expect(try lock.claim(session: Self.alice) == .claimed)
    let original = Data("{\"design\":\"docs/search/designs/search.md\"}\n".utf8)

    #expect(try lock.seedPlanFile(original))
    #expect(try !lock.seedPlanFile(Data("{}\n".utf8)))

    #expect(FileManager.default.contents(atPath: plan.planFile) == original)
    #expect(
      FileSystemConditions.contents(of: plan.directory) == ["orchestrator.lock", "plan.json"])
  }

  @Test(
    "a lock holding bytes no claim wrote is refused as held and only force-release clears it — catches corrupt lock contents read as unclaimed"
  )
  func garbageLockIsHeld() throws {
    let common = try FileSystemConditions.scratchDirectory("lock")
    defer { try? FileManager.default.removeItem(at: common) }
    let plan = try PlanStateLayout(commonDirectory: common.path).plan("search")
    try FileManager.default.createDirectory(
      atPath: plan.directory, withIntermediateDirectories: true)
    try Data("\u{FFFD}garbage\n".utf8).write(to: URL(filePath: plan.orchestratorLock))
    let lock = PlanLock(plan: plan)

    #expect(try lock.claim(session: Self.alice) == .heldByOther(holder: "\u{FFFD}garbage"))
    #expect(try lock.release(session: Self.alice) == .heldByOther(holder: "\u{FFFD}garbage"))
    #expect(try lock.forceRelease() == .overrode(holder: "\u{FFFD}garbage"))
    #expect(try lock.claim(session: Self.alice) == .claimed)
    #expect(FileSystemConditions.contents(of: plan.directory) == ["orchestrator.lock"])
  }

  @Test(
    "on a filesystem without hard links neither the lock nor plan.json is published and no staging file is left — catches a failed link treated as a lost race",
    .enabled(if: FileSystemConditions.hasDiskImages, "needs hdiutil to attach a FAT volume"))
  func noHardLinksBlocksPublishing() async throws {
    try await FATVolume.with { volume in
      let plan = try PlanStateLayout(commonDirectory: volume.mountPoint.path).plan("search")
      let lock = PlanLock(plan: plan)

      let claimError = try #require(throws: PlanLockError.self) {
        try lock.claim(session: Self.alice)
      }
      let seedError = try #require(throws: PlanLockError.self) {
        try lock.seedPlanFile(Data("{}".utf8))
      }

      #expect(Self.isIO(claimError, mentioning: "linking \(plan.orchestratorLock)"))
      #expect(Self.isIO(seedError, mentioning: "linking \(plan.planFile)"))
      #expect(FileSystemConditions.contents(of: plan.directory).isEmpty)
      #expect(try lock.holder() == nil)
    }
  }

  @Test(
    "a full volume fails the staging write and removes the half-written staging file — catches a partial lock file left behind",
    .enabled(if: FileSystemConditions.hasDiskImages, "needs hdiutil to attach a FAT volume"))
  func fullVolumeFailsStagingWrite() async throws {
    try await FATVolume.with { volume in
      let plan = try PlanStateLayout(commonDirectory: volume.mountPoint.path).plan("search")
      try FileManager.default.createDirectory(
        atPath: plan.directory, withIntermediateDirectories: true)
      try volume.fill()

      let error = try #require(throws: PlanLockError.self) {
        try PlanLock(plan: plan).claim(session: Self.alice)
      }

      #expect(Self.isIO(error, mentioning: "writing \(plan.directory)/.staging."))
      #expect(FileSystemConditions.contents(of: plan.directory).isEmpty)
    }
  }
}
