import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import Testing

@testable import SwiftGateCLI

/// `evidence find` searches every repo `<slug>.evidence/claims.jsonl` plus the user-level
/// evidence reuse cache. Every fixture lives under a fresh temp directory (worker-brief pitfall
/// 7) — never this checkout's own `docs/` or real `$HOME`.
@Suite("swiftgate evidence find")
struct EvidenceFindCommandTests {
  private struct Repository {
    let root: URL

    init() throws {
      root = FileManager.default.temporaryDirectory
        .appending(
          path: "swiftgate-evidence-find-\(UUID().uuidString)", directoryHint: .isDirectory
        )
        .resolvingSymlinksInPath()
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    func write(_ contents: String, at relativePath: String) throws -> String {
      let url = root.appending(path: relativePath)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(contents.utf8).write(to: url)
      return relativePath
    }

    func freshCacheHome() throws -> String {
      try write("", at: "cache-home/.keep")
      return root.appending(path: "cache-home").path
    }
  }

  private static func claimLine(
    id: String, text: String, pin: String?, quote: String? = nil,
    status: Claim.Status = .supported
  ) throws -> String {
    let claim = Claim(
      id: id, lane: "packages", text: text,
      citation: Citation(kind: .file, loc: "Sources/Widget.swift:L1-L1", pin: pin, quote: quote),
      status: status)
    let data = try JSONEncoder().encode(claim)
    return String(decoding: data, as: UTF8.self)
  }

  /// A `file` citation into `.build/checkouts/<pkg>/…`: the one shape ``ReusableClaim`` accepts
  /// into the cache (spec §8.6 excludes codebase claims).
  private static func packageClaim(id: String, text: String, pin: String) -> Claim {
    Claim(
      id: id, lane: "packages", text: text,
      citation: Citation(
        kind: .file, loc: ".build/checkouts/tca/Sources/Widget.swift:L1-L1", pin: pin),
      status: .supported)
  }

  @Test("a repo hit and a cache hit both match the same query, each carrying its own origin")
  func repoAndCacheHitsCarryOrigin() async throws {
    let repository = try Repository()
    defer { repository.remove() }
    let line = try Self.claimLine(
      id: "ev-repo-widget", text: "the widget retries on failure", pin: nil)
    try repository.write("\(line)\n", at: "docs/ordering/designs/queue.evidence/claims.jsonl")

    let cacheHome = try repository.freshCacheHome()
    let store = EvidenceCacheStore(home: URL(filePath: cacheHome, directoryHint: .isDirectory))
    let cacheClaim = try ReusableClaim(
      Self.packageClaim(id: "ev-cache-widget", text: "the widget caches results", pin: "tca@1.0.0"))
    try await store.record(cacheClaim, origin: .researchLane)

    let report = EvidenceFindRun.run(
      query: "widget", pkg: nil, root: repository.root, cacheHome: cacheHome)
    #expect(report.verdict == .green)
    let origins = Set(report.hits.map(\.origin))
    #expect(origins == ["repo", "research-lane"])
    let repoHit = try #require(report.hits.first { $0.origin == "repo" })
    #expect(repoHit.id == "ev-repo-widget")
    #expect(repoHit.reuseCount == nil)
    let cacheHit = try #require(report.hits.first { $0.origin == "research-lane" })
    // Cache hits report a text hash as their id, never the origin repo's own claim id.
    #expect(cacheHit.id != "ev-cache-widget")
    #expect(cacheHit.reuseCount == 0)
  }

  @Test(
    "--pkg tca@1.0.0 excludes tca@1.0.1 and tca@1.0 — catches cross-version reuse"
  )
  func pkgFilterIsExactOnIdentityAndVersion() async throws {
    let repository = try Repository()
    defer { repository.remove() }
    let matching = try Self.claimLine(id: "ev-exact", text: "pinned exactly", pin: "tca@1.0.0")
    let laterPatch = try Self.claimLine(id: "ev-later", text: "pinned later", pin: "tca@1.0.1")
    let shorterVersion = try Self.claimLine(id: "ev-short", text: "pinned short", pin: "tca@1.0")
    try repository.write(
      "\(matching)\n\(laterPatch)\n\(shorterVersion)\n",
      at: "docs/ordering/designs/queue.evidence/claims.jsonl")
    let cacheHome = try repository.freshCacheHome()

    let report = EvidenceFindRun.run(
      query: "pinned", pkg: "tca@1.0.0", root: repository.root, cacheHome: cacheHome)
    #expect(report.verdict == .green)
    #expect(report.hits.map(\.id) == ["ev-exact"])
  }

  @Test("a --pkg without @<version> is blocked — exit 2")
  func pkgWithoutVersionIsBlocked() async throws {
    let repository = try Repository()
    defer { repository.remove() }
    let cacheHome = try repository.freshCacheHome()

    let report = EvidenceFindRun.run(
      query: "anything", pkg: "tca", root: repository.root, cacheHome: cacheHome)
    #expect(report.verdict == .blocked)
    #expect(report.message.contains("<name>@<version>"))
  }

  @Test("a tombstoned cache claim is hidden from results")
  func tombstonedCacheClaimsHidden() async throws {
    let repository = try Repository()
    defer { repository.remove() }
    let cacheHome = try repository.freshCacheHome()
    let store = EvidenceCacheStore(home: URL(filePath: cacheHome, directoryHint: .isDirectory))
    let refuted = try ReusableClaim(
      Self.packageClaim(id: "ev-refuted", text: "the gadget is fast", pin: "tca@1.0.0"))
    try await store.record(refuted, origin: .researchLane)
    try await store.tombstone(refuted, reason: .refuted)
    let live = try ReusableClaim(
      Claim(
        id: "ev-live", lane: "packages", text: "the gadget is still fast",
        citation: Citation(
          kind: .file, loc: ".build/checkouts/tca/Sources/Other.swift:L1-L1", pin: "tca@1.0.0"),
        status: .supported))
    try await store.record(live, origin: .researchLane)

    let report = EvidenceFindRun.run(
      query: "gadget", pkg: nil, root: repository.root, cacheHome: cacheHome)
    #expect(report.verdict == .green)
    #expect(!report.hits.contains { $0.text.contains("the gadget is fast") })
    #expect(report.hits.contains { $0.text == "the gadget is still fast" })
  }

  @Test(
    "a corrupt cache line surfaces as a note, not dropped, and a valid hit in the same file still shows"
  )
  func corruptCacheLineSurfacesAsNote() async throws {
    let repository = try Repository()
    defer { repository.remove() }
    let cacheHome = try repository.freshCacheHome()
    let store = EvidenceCacheStore(home: URL(filePath: cacheHome, directoryHint: .isDirectory))
    let live = try ReusableClaim(
      Self.packageClaim(id: "ev-live", text: "the sprocket turns", pin: "tca@1.0.0"))
    try await store.record(live, origin: .researchLane)

    let layout = EvidenceCacheLayout(home: cacheHome)
    let path = try layout.file(.package(pin: "tca@1.0.0"))
    var bytes = try Data(contentsOf: URL(filePath: path))
    bytes.append(Data("not valid json\n".utf8))
    try bytes.write(to: URL(filePath: path))

    let report = EvidenceFindRun.run(
      query: "sprocket", pkg: nil, root: repository.root, cacheHome: cacheHome)
    #expect(report.verdict == .green)
    #expect(report.hits.contains { $0.text == "the sprocket turns" })
    #expect(report.notes.contains { $0.contains("doesn't decode") })
  }

  @Test("hits are sorted by source then id, independent of write order")
  func hitsAreSortedDeterministically() async throws {
    let repository = try Repository()
    defer { repository.remove() }
    let alpha = try Self.claimLine(id: "ev-zzz", text: "sortable marker", pin: nil)
    let beta = try Self.claimLine(id: "ev-aaa", text: "sortable marker", pin: nil)
    try repository.write(
      "\(alpha)\n\(beta)\n", at: "docs/ordering/designs/queue.evidence/claims.jsonl")
    let cacheHome = try repository.freshCacheHome()

    let report = EvidenceFindRun.run(
      query: "sortable", pkg: nil, root: repository.root, cacheHome: cacheHome)
    #expect(report.hits.map(\.id) == ["ev-aaa", "ev-zzz"])
  }

  @Test("no matches is exit 0 with a clear message, not an error")
  func noMatchesIsGreen() async throws {
    let repository = try Repository()
    defer { repository.remove() }
    let cacheHome = try repository.freshCacheHome()

    let report = EvidenceFindRun.run(
      query: "nothing-will-match-this", pkg: nil, root: repository.root, cacheHome: cacheHome)
    #expect(report.verdict == .green)
    #expect(report.hits.isEmpty)
    #expect(report.message.contains("no matches"))
  }
}
