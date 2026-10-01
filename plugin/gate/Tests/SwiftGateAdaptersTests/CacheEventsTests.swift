import CryptoKit
import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Synchronization
import Testing

/// The manifest and evidence caches write 1 `cache.lookup` per hit, miss, store and tombstone
/// into a scratch project's event store.
@Suite("cache lookup events")
struct CacheEventsTests {
  private static let package = "examples/SampleApp/Packages/GameEngine"

  private static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  /// Counts what it's handed, then refuses it.
  private final class RefusingWriter: HarnessEventWriting {
    private let handed = Mutex(0)

    var count: Int { handed.withLock { $0 } }

    func append(_ event: HarnessEvent) throws(HarnessEventWriteError) {
      handed.withLock { $0 += 1 }
      throw HarnessEventWriteError(path: "cache.jsonl", reason: "disk full")
    }
  }

  private final class Lines: Sendable {
    private let kept = Mutex<[String]>([])

    var all: [String] { kept.withLock { $0 } }

    func append(_ line: String) { kept.withLock { $0.append(line) } }
  }

  /// A scratch project: a package with a manifest, a fake `swift` that answers with captured
  /// output, and the project's event store.
  private struct Project {
    let root: URL
    let runner: FakeProcessRunner
    let describeOutput: String
    let reported = Lines()

    init() throws {
      root = FileManager.default.temporaryDirectory
        .appending(path: "swiftgate-cache-events-\(UUID().uuidString)", directoryHint: .isDirectory)
        .resolvingSymlinksInPath()
      try FileManager.default.createDirectory(
        at: root.appending(path: CacheEventsTests.package), withIntermediateDirectories: true)
      let describe = try Fixture.text("SwiftPM/describe-GameEngine.json")
        .replacingOccurrences(of: Fixture.repositoryRoot, with: root.path)
      let dump = try Fixture.text("SwiftPM/dump-package-main-actor-core.json")
      describeOutput = describe
      runner = FakeProcessRunner { invocation in
        ProcessOutput(
          status: .exited(0), stdout: invocation.arguments.contains("describe") ? describe : dump)
      }
      try write("Package.swift", "// swift-tools-version: 6.2\n")
    }

    func write(_ file: String, _ text: String) throws {
      let url = root.appending(path: "\(CacheEventsTests.package)/\(file)")
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(text.utf8).write(to: url)
    }

    var recorder: CacheEventRecorder {
      let root = self.root
      let reported = self.reported
      return CacheEventRecorder(
        events: { EventWriterFactory.make(root: root, enabled: true) },
        report: { reported.append($0) })
    }

    /// A fresh adapter per call, as every hook and command is a fresh process.
    func swiftPM(recorder: CacheEventRecorder? = nil) -> LiveSwiftPM {
      LiveSwiftPM(
        runner: runner, repositoryRoot: root.path,
        manifestCache: root.appending(path: ".harness/cache/manifests"),
        cacheEvents: recorder ?? self.recorder)
    }

    var manifestCacheDirectory: URL { root.appending(path: ".harness/cache/manifests") }

    var eventsText: String {
      String(
        decoding: FileManager.default.contents(
          atPath: root.appending(path: RunLayout.eventsFile(.cache)).path) ?? Data(),
        as: UTF8.self)
    }

    func lookups() throws -> [CacheLookupEvent] {
      try HarnessEventJSON.decode(Data(eventsText.utf8)).events.map { event in
        guard case .cacheLookup(let lookup) = event.payload else {
          throw NotACacheLookup(kind: event.kind)
        }
        return lookup
      }
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
  }

  private struct NotACacheLookup: Error {
    let kind: HarnessEventKind
  }

  private static func claim(
    _ id: String, text: String = "Effect.run starts a long-living effect.",
    quote: String = "public static func run(", version: String = "1.26.2"
  ) throws -> ReusableClaim {
    let package = "swift-composable-architecture"
    return try ReusableClaim(
      Claim(
        id: id, lane: "packages", text: text,
        citation: Citation(
          kind: .file,
          loc: ".build/checkouts/\(package)/Sources/ComposableArchitecture/Effect.swift:L40-L52",
          pin: "\(package)@\(version)", quote: quote),
        status: .supported))
  }

  private static func evidenceStore(_ project: Project) -> EvidenceCacheStore {
    EvidenceCacheStore(home: project.root.appending(path: "home"), events: project.recorder)
  }

  @Test(
    "a miss, a store and a hit give 3 cache.lookup events under 1 keyHash, the key the cache file holds — catches a keyHash hashed from the raw command"
  )
  func missStoreHit() async throws {
    let project = try Project()
    defer { project.remove() }

    _ = try await project.swiftPM().describe(packageDirectory: Self.package)
    _ = try await project.swiftPM().describe(packageDirectory: Self.package)

    let lookups = try project.lookups()
    #expect(lookups.map(\.cache) == [.manifest, .manifest, .manifest])
    #expect(lookups.map(\.outcome) == [.miss, .store, .hit])
    let answers = try FileManager.default.contentsOfDirectory(
      at: project.manifestCacheDirectory, includingPropertiesForKeys: nil)
    #expect(answers.count == 1)
    let stored = try Data(contentsOf: try #require(answers.first))
    let key = String(decoding: stored.prefix { $0 != UInt8(ascii: "\n") }, as: UTF8.self)
    #expect(Set(lookups.map(\.keyHash)) == [key])
    let answerHash = Self.sha256(Data(project.describeOutput.utf8))
    #expect(lookups.map(\.answerHash) == [nil, answerHash, answerHash])
    #expect(lookups.allSatisfy { $0.tombstoneReason == nil })
    #expect(project.reported.all.isEmpty)
  }

  @Test(
    "describe and dump-package of 1 package are 2 keys — catches a keyHash that leaves out the command"
  )
  func commandsAreSeparateKeys() async throws {
    let project = try Project()
    defer { project.remove() }

    _ = try await project.swiftPM().describe(packageDirectory: Self.package)
    _ = try await project.swiftPM().settings(packageDirectory: Self.package)

    let stores = try project.lookups().filter { $0.outcome == .store }
    #expect(stores.count == 2)
    #expect(Set(stores.map(\.keyHash)).count == 2)
  }

  @Test(
    "a test target added under an unchanged manifest is a hit with the old answerHash — catches a hit recorded without the hash of what it served"
  )
  func staleHitKeepsOldAnswer() async throws {
    let project = try Project()
    defer { project.remove() }

    _ = try await project.swiftPM().describe(packageDirectory: Self.package)
    try project.write("Tests/AddedTests/AddedTests.swift", "import Testing\n")
    _ = try await project.swiftPM().describe(packageDirectory: Self.package)

    let lookups = try project.lookups()
    try #require(lookups.map(\.outcome) == [.miss, .store, .hit])
    let hit = try #require(lookups.last)
    #expect(hit.answerHash == Self.sha256(Data(project.describeOutput.utf8)))
    #expect(hit.answerHash == lookups[1].answerHash)
    #expect(project.runner.invocations.count == 1)
  }

  @Test(
    "an unreadable manifest records nothing and still asks swift — catches a lookup event with no key"
  )
  func noManifestNoEvent() async throws {
    let project = try Project()
    defer { project.remove() }
    let manifest = project.root.appending(path: "\(Self.package)/Package.swift")
    try FileManager.default.removeItem(at: manifest)

    _ = try await project.swiftPM().describe(packageDirectory: Self.package)
    try project.write("Package.swift", "// swift-tools-version: 6.2\n")
    _ = try await project.swiftPM().describe(packageDirectory: Self.package)

    #expect(try project.lookups().map(\.outcome) == [.miss, .store])
    #expect(project.runner.invocations.count == 2)
  }

  @Test(
    "a failed event write leaves the answer and the swift calls as they were and reports 1 line per write — catches telemetry failing or changing a lookup"
  )
  func failedWriteChangesNothing() async throws {
    let project = try Project()
    defer { project.remove() }
    let refusing = RefusingWriter()
    let reported = Lines()
    let recorder = CacheEventRecorder(
      events: { refusing }, report: { reported.append($0) })

    let first = try await project.swiftPM(recorder: recorder).describe(
      packageDirectory: Self.package)
    let second = try await project.swiftPM(recorder: recorder).describe(
      packageDirectory: Self.package)
    let plain = try await LiveSwiftPM(runner: project.runner, repositoryRoot: project.root.path)
      .describe(packageDirectory: Self.package)

    #expect(first == plain)
    #expect(second == plain)
    #expect(project.runner.invocations.count == 2)
    #expect(refusing.count == 3)
    #expect(reported.all.count == 3)
    #expect(reported.all.allSatisfy { $0.contains("cache event not written") })
  }

  @Test(
    "no project writer records nothing — catches a cache that writes events with telemetry off"
  )
  func noWriterNoEvents() async throws {
    let project = try Project()
    defer { project.remove() }
    let recorder = CacheEventRecorder(events: { nil }, report: { project.reported.append($0) })

    _ = try await project.swiftPM(recorder: recorder).describe(packageDirectory: Self.package)
    _ = try await project.swiftPM(recorder: recorder).describe(packageDirectory: Self.package)
    _ = try await project.swiftPM().describe(packageDirectory: Self.package)

    #expect(try project.lookups().map(\.outcome) == [.hit])
    #expect(project.reported.all.isEmpty)
  }

  @Test(
    "an evidence claim's store, reuse and tombstone share 1 keyHash and the tombstone carries its reason — catches a tombstone recorded without why"
  )
  func evidenceClaimLifecycle() async throws {
    let project = try Project()
    defer { project.remove() }
    let store = Self.evidenceStore(project)
    let claim = try Self.claim("ev-effect-run")

    try await store.record(claim, origin: .researchLane)
    try await store.record(claim, origin: .researchLane)
    try await store.markReused(claim)
    try await store.tombstone(claim, reason: .refuted)
    try await store.tombstone(claim, reason: .amended)

    let lookups = try project.lookups()
    #expect(lookups.map(\.cache) == [.evidenceClaim, .evidenceClaim, .evidenceClaim])
    try #require(lookups.map(\.outcome) == [.store, .hit, .tombstone])
    #expect(Set(lookups.map(\.keyHash)).count == 1)
    #expect(lookups[0].answerHash != nil)
    #expect(lookups[1].answerHash == lookups[0].answerHash)
    #expect(lookups[2].answerHash == nil)
    #expect(lookups.map(\.tombstoneReason) == [nil, nil, .refuted])
  }

  @Test(
    "1 claim under 2 pins is 2 keys — catches an evidence keyHash that leaves out the cache file"
  )
  func pinsAreSeparateKeys() async throws {
    let project = try Project()
    defer { project.remove() }
    let store = Self.evidenceStore(project)

    try await store.record(try Self.claim("ev-a", version: "1.26.2"), origin: .researchLane)
    try await store.record(try Self.claim("ev-b", version: "1.27.0"), origin: .researchLane)

    let lookups = try project.lookups()
    #expect(lookups.map(\.outcome) == [.store, .store])
    #expect(Set(lookups.map(\.keyHash)).count == 2)
  }

  @Test(
    "a verdict's store and reuse share 1 keyHash and answerHash, apart from its claim's — catches verdicts counted as claims"
  )
  func evidenceVerdict() async throws {
    let project = try Project()
    defer { project.remove() }
    let store = Self.evidenceStore(project)
    let claim = try Self.claim("ev-effect-run")
    let refutedClaim = try Self.claim("ev-other", text: "Effect.run is synchronous.")

    try await store.recordVerdict(.supported, for: claim, origin: .claimChecker)
    try await store.markVerdictReused(claim.fingerprint)
    try await store.recordVerdict(.refuted, for: refutedClaim, origin: .claimChecker)

    let lookups = try project.lookups()
    #expect(lookups.map(\.cache) == [.evidenceVerdict, .evidenceVerdict, .evidenceVerdict])
    try #require(lookups.map(\.outcome) == [.store, .hit, .store])
    #expect(lookups[0].keyHash == lookups[1].keyHash)
    #expect(lookups[1].answerHash == lookups[0].answerHash)
    #expect(lookups[2].answerHash != lookups[0].answerHash)
    #expect(lookups[2].keyHash != lookups[0].keyHash)
  }

  @Test(
    "no command, package path, root or claim text is in the cache stream — catches a payload that carries what it hashed"
  )
  func noSourceTextInFile() async throws {
    let project = try Project()
    defer { project.remove() }
    let store = Self.evidenceStore(project)
    let claim = try Self.claim("ev-effect-run")

    _ = try await project.swiftPM().describe(packageDirectory: Self.package)
    _ = try await project.swiftPM().settings(packageDirectory: Self.package)
    _ = try await project.swiftPM().describe(packageDirectory: Self.package)
    try await store.record(claim, origin: .researchLane)
    try await store.markReused(claim)
    try await store.tombstone(claim, reason: .amended)

    let text = project.eventsText
    #expect(try project.lookups().count == 8)
    for secret in [
      "describe", "dump-package", Self.package, "GameEngine", project.root.path,
      "swift-composable-architecture", "Effect.run", "public static func run", "ev-effect-run",
    ] {
      #expect(!text.contains(secret), "\(secret) is in the cache stream")
    }
  }
}
