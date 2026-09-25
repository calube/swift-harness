import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import Testing

/// The known-id feed read from a real repository: ids from every readable source, and a named
/// finding for every source that exists but can't be read, never a silently narrower feed.
@Suite("KnownIdSources")
struct KnownIdSourcesTests {
  private static func claimLine(_ id: String) throws -> String {
    let claim = Claim(
      id: id, lane: "search", text: "debounce holds",
      citation: Citation(kind: .answer, loc: "run-1"),
      status: .new)
    return String(decoding: try ClaimJSON.encodeLine(claim), as: UTF8.self)
  }

  private static func designDoc(requirement: String, testPlan: String) -> String {
    """
    # Search

    ## Requirements

    - \(requirement): typing debounces the query

    ## Test plan by tier

    - \(testPlan): debounce collapses bursts — tier push

    """
  }

  private static func ledger(taskID: String) throws -> Data {
    try LedgerJSON.encode(
      Ledger(
        schemaVersion: 1, resume: "seed", maxParallel: 1,
        tasks: [
          LedgerTask(
            id: taskID, deps: [], writeSet: ["Sources/"], gate: .push, tests: [], covers: [],
            estLines: 10, status: .pending, worktree: "main")
        ], waves: [[taskID]]))
  }

  private func write(_ content: String, _ path: String, in repo: TemporaryGitRepository) throws {
    try write(Data(content.utf8), path, in: repo)
  }

  private func write(_ data: Data, _ path: String, in repo: TemporaryGitRepository) throws {
    let url = repo.root.appending(path: path)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url)
  }

  private func plans(_ repo: TemporaryGitRepository) async throws -> PlanStateLayout {
    try PlanStateLayout(commonDirectory: try await repo.adapter.commonDirectory())
  }

  @Test(
    "ids come from ledgers, evidence claims and design docs, and only from files at those paths — catches a claims file or doc outside its directory feeding the id-leak check"
  )
  func readsEachSourceAtItsPath() async throws {
    let repo = try await TemporaryGitRepository()
    defer { repo.remove() }
    let plan = try await plans(repo).plan("search")
    try FileManager.default.createDirectory(
      atPath: plan.directory, withIntermediateDirectories: true)
    try Self.ledger(taskID: "search-debounce-task").write(to: URL(filePath: plan.ledgerFile))
    try FileManager.default.createDirectory(
      atPath: try await plans(repo).plan("claimed-not-scheduled").directory,
      withIntermediateDirectories: true)
    try write(
      try Self.claimLine("ev-debounce-holds-fast"), "docs/search/search.evidence/claims.jsonl",
      in: repo)
    try write(try Self.claimLine("ev-stray-claims-file"), "docs/search/claims.jsonl", in: repo)
    try write(try Self.claimLine("ev-top-level-claims"), "docs/claims.jsonl", in: repo)
    try write(
      Self.designDoc(requirement: "search-debounce", testPlan: "search-debounce-burst"),
      "docs/search/designs/search.md", in: repo)
    try write(
      Self.designDoc(requirement: "notes-requirement", testPlan: "notes-test-plan"),
      "docs/search/notes/search.md", in: repo)
    try write(
      Self.designDoc(requirement: "text-requirement", testPlan: "text-test-plan"),
      "docs/search/designs/search.txt", in: repo)
    try write(
      Self.designDoc(requirement: "top-requirement", testPlan: "top-test-plan"), "docs/top.md",
      in: repo)

    let loaded = await KnownIdSources.load(root: repo.root, git: repo.adapter)

    #expect(
      loaded.ids == [
        "search-debounce-task", "ev-debounce-holds-fast", "search-debounce",
        "search-debounce-burst",
      ])
    #expect(loaded.unreadable.isEmpty)
  }

  @Test(
    "a plan-state entry whose name can't be a plan is reported and the valid plans still load — catches one odd directory hiding every ledger"
  )
  func invalidPlanDirectoryNameIsReported() async throws {
    let repo = try await TemporaryGitRepository()
    defer { repo.remove() }
    let layout = try await plans(repo)
    let plan = try layout.plan("search")
    try FileManager.default.createDirectory(
      atPath: plan.directory, withIntermediateDirectories: true)
    try Self.ledger(taskID: "search-debounce-task").write(to: URL(filePath: plan.ledgerFile))
    try FileManager.default.createDirectory(
      atPath: layout.root + "/bad\nname", withIntermediateDirectories: true)

    let loaded = await KnownIdSources.load(root: repo.root, git: repo.adapter)

    #expect(loaded.ids == ["search-debounce-task"])
    #expect(
      loaded.unreadable == [
        KnownIdSources.UnreadableSource(
          path: layout.root + "/bad\nname", reason: "not a valid plan directory name")
      ])
  }

  @Test(
    "a ledger without read permission is reported by path and the other plans still load — catches an unreadable ledger silently dropping its task ids",
    .enabled(if: FileSystemConditions.permissionsDeny, "chmod doesn't deny root"))
  func unreadableLedgerIsReported() async throws {
    let repo = try await TemporaryGitRepository()
    defer { repo.remove() }
    let layout = try await plans(repo)
    let readable = try layout.plan("readable")
    let locked = try layout.plan("locked")
    for plan in [readable, locked] {
      try FileManager.default.createDirectory(
        atPath: plan.directory, withIntermediateDirectories: true)
    }
    try Self.ledger(taskID: "readable-task").write(to: URL(filePath: readable.ledgerFile))
    try Self.ledger(taskID: "locked-task").write(to: URL(filePath: locked.ledgerFile))
    try FileSystemConditions.setMode(0o000, locked.ledgerFile)
    defer { chmod(locked.ledgerFile, 0o644) }

    let loaded = await KnownIdSources.load(root: repo.root, git: repo.adapter)

    #expect(loaded.ids == ["readable-task"])
    #expect(
      loaded.unreadable == [
        KnownIdSources.UnreadableSource(path: locked.ledgerFile, reason: "could not be read")
      ])
  }

  @Test(
    "a claims file with a torn line keeps its whole lines and reports the count — catches one bad line discarding the file or passing unnoticed"
  )
  func tornClaimsLineIsReported() async throws {
    let repo = try await TemporaryGitRepository()
    defer { repo.remove() }
    let path = "docs/search/search.evidence/claims.jsonl"
    try write(
      try Self.claimLine("ev-debounce-holds-fast") + "{\"id\":\"ev-torn-by-cr", path, in: repo)

    let loaded = await KnownIdSources.load(root: repo.root, git: repo.adapter)

    #expect(loaded.ids == ["ev-debounce-holds-fast"])
    #expect(
      loaded.unreadable == [
        KnownIdSources.UnreadableSource(
          path: path, reason: "1 line(s) could not be parsed as JSON")
      ])
  }

  @Test(
    "a claims file without read permission is reported by path — catches its claim ids silently leaving the feed",
    .enabled(if: FileSystemConditions.permissionsDeny, "chmod doesn't deny root"))
  func unreadableClaimsFileIsReported() async throws {
    let repo = try await TemporaryGitRepository()
    defer { repo.remove() }
    let path = "docs/search/search.evidence/claims.jsonl"
    try write(try Self.claimLine("ev-debounce-holds-fast"), path, in: repo)
    let absolute = repo.root.appending(path: path).path
    try FileSystemConditions.setMode(0o000, absolute)
    defer { chmod(absolute, 0o644) }

    let loaded = await KnownIdSources.load(root: repo.root, git: repo.adapter)

    #expect(loaded.ids.isEmpty)
    #expect(
      loaded.unreadable == [
        KnownIdSources.UnreadableSource(path: path, reason: "could not be read")
      ]
    )
  }

  @Test(
    "a design doc that isn't UTF-8 is reported by path, the other docs still load, and findings sort by path — catches one bad doc dropping every requirement id"
  )
  func undecodableDesignDocIsReported() async throws {
    let repo = try await TemporaryGitRepository()
    defer { repo.remove() }
    try write(
      Self.designDoc(requirement: "search-debounce", testPlan: "search-debounce-burst"),
      "docs/search/designs/search.md", in: repo)
    try write(Data([0x23, 0x20, 0xFF, 0xFE, 0x0A]), "docs/cart/designs/cart.md", in: repo)
    try write(Data([0xC3, 0x28, 0x0A]), "docs/about/designs/about.md", in: repo)

    let loaded = await KnownIdSources.load(root: repo.root, git: repo.adapter)

    #expect(loaded.ids == ["search-debounce", "search-debounce-burst"])
    #expect(
      loaded.unreadable.map(\.path) == ["docs/about/designs/about.md", "docs/cart/designs/cart.md"])
    #expect(loaded.unreadable.allSatisfy { !$0.reason.isEmpty })
  }
}
