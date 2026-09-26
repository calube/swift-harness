import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import Testing

/// Claims shaped like spec §5.2 examples. Every package claim cites a `.build/checkouts` path at
/// a `<pkg>@<version>` pin; the codebase claim cites the repository's own source at a commit.
private enum Claims {
  static let package = "swift-composable-architecture"

  static func packageClaim(
    _ id: String, text: String, quote: String, version: String = "1.26.2",
    lines: String = "L40-L52"
  ) -> Claim {
    Claim(
      id: id, lane: "packages", text: text,
      citation: Citation(
        kind: .file,
        loc: ".build/checkouts/\(package)/Sources/ComposableArchitecture/Effect.swift:\(lines)",
        pin: "\(package)@\(version)", quote: quote),
      status: .supported)
  }

  static func reusable(_ claim: Claim) throws -> ReusableClaim {
    try ReusableClaim(claim)
  }

  static let codebase = Claim(
    id: "ev-feature-store-uses-effect-run", lane: "codebase",
    text: "FeatureStore starts its load with Effect.run.",
    citation: Citation(
      kind: .file, loc: "Sources/Feature/FeatureStore.swift:L10-L14",
      pin: "3f2a9c1d0e7b6a5f4c3b2a1908f7e6d5c4b3a291", quote: "return .run { send in"),
    status: .supported)
}

/// A scratch home standing in for `~`, so no test reads or writes the real user cache.
private struct ScratchHome {
  let url: URL

  init() throws {
    url = FileManager.default.temporaryDirectory
      .appending(path: "swiftgate-evidence-cache-\(UUID().uuidString)", directoryHint: .isDirectory)
      .resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  }

  /// A real one-slot lock, polling faster than production so contended tests don't sleep.
  func store() -> EvidenceCacheStore {
    let layout = EvidenceCacheLayout(home: url.path)
    return EvidenceCacheStore(
      home: url,
      lock: FileCountingLock(
        directory: URL(filePath: layout.root), name: EvidenceCacheStore.lockName, capacity: 1,
        pollInterval: .milliseconds(2)))
  }

  func remove() { try? FileManager.default.removeItem(at: url) }
}

/// Relaunches this test bundle under the swift-testing helper that is running it, so a test can
/// drive real separate processes through the production store.
private enum SelfRelaunch {
  static let homeVariable = "SWIFTGATE_EVIDENCE_CACHE_CHILD_HOME"
  static let writerVariable = "SWIFTGATE_EVIDENCE_CACHE_CHILD_WRITER"
  static let claimsPerWriter = 6

  static let bundlePath: String? = {
    let arguments = ProcessInfo.processInfo.arguments
    guard let flag = arguments.firstIndex(of: "--test-bundle-path"), flag + 1 < arguments.count
    else { return nil }
    return arguments[flag + 1]
  }()

  static var isAvailable: Bool { bundlePath != nil }
  static var isChild: Bool { ProcessInfo.processInfo.environment[homeVariable] != nil }

  static func claim(writer: Int, index: Int) -> Claim {
    Claims.packageClaim(
      "ev-writer-\(writer)-claim-\(index)", text: "Writer \(writer) claim \(index) holds.",
      quote: "quote \(writer).\(index)")
  }
}

@Suite("Evidence reuse cache")
struct EvidenceCacheStoreTests {
  @Test(
    "a codebase claim is refused at construction and on decode — catches reused stale code facts"
  )
  func codebaseClaimRefused() async throws {
    #expect(throws: EvidenceCacheRefusal.codebaseClaim(claimID: Claims.codebase.id)) {
      try ReusableClaim(Claims.codebase)
    }
    let mismatched = Claim(
      id: "ev-other-package-mislabelled-pin", lane: "packages", text: "t",
      citation: Citation(
        kind: .file, loc: ".build/checkouts/swift-dependencies/Sources/D.swift:L1-L2",
        pin: "swift-composable-architecture@1.26.2", quote: "q"),
      status: .supported)
    #expect(throws: EvidenceCacheRefusal.codebaseClaim(claimID: mismatched.id)) {
      try ReusableClaim(mismatched)
    }
    let escaping = Claim(
      id: "ev-escaped-checkout-path-claim", lane: "packages", text: "t",
      citation: Citation(
        kind: .file, loc: ".build/checkouts/swift-dependencies/../../Sources/App.swift:L1-L2",
        pin: "swift-dependencies@1.0.0", quote: "q"),
      status: .supported)
    #expect(throws: EvidenceCacheRefusal.codebaseClaim(claimID: escaping.id)) {
      try ReusableClaim(escaping)
    }
    let capture = Claim(
      id: "ev-build-log-shows-warning", lane: "codebase", text: "t",
      citation: Citation(kind: .capture, loc: "captures/build.txt", pin: "abc", quote: "q"),
      status: .supported)
    #expect(throws: EvidenceCacheRefusal.notReusable(claimID: capture.id, kind: .capture)) {
      try ReusableClaim(capture)
    }
    let accepted = try Claims.reusable(
      Claims.packageClaim("ev-effect-run-is-cancellable", text: "t", quote: "q"))
    #expect(accepted.kind == .package)
    #expect(accepted.bucket == .package(pin: "swift-composable-architecture@1.26.2"))
    let snapshot = try ReusableClaim(
      Claim(
        id: "ev-list-selection-binding-semantics", lane: "apple-docs", text: "t",
        citation: Citation(
          kind: .snapshot, loc: "snapshots/list.md", pin: "iphoneos26.0", quote: "q"),
        status: .supported))
    #expect(snapshot.kind == .snapshot)
    #expect(
      try EvidenceCacheLayout(home: "/h").file(snapshot.bucket)
        == "/h/.swift-harness/evidence-cache/sdk/iphoneos26.0.jsonl")

    // A codebase claim written into a cache file by hand never comes back out as an entry.
    let home = try ScratchHome()
    defer { home.remove() }
    let store = home.store()
    let file = try store.layout.file(.package(pin: "swift-composable-architecture@1.26.2"))
    try FileManager.default.createDirectory(
      atPath: URL(filePath: file).deletingLastPathComponent().path,
      withIntermediateDirectories: true)
    let smuggled = try JSONSerialization.data(withJSONObject: [
      "type": "claim", "origin": "research-lane",
      "claim": try JSONSerialization.jsonObject(with: JSONEncoder().encode(Claims.codebase)),
    ])
    try smuggled.write(to: URL(filePath: file))

    let contents = try store.contents(of: .package(pin: "swift-composable-architecture@1.26.2"))
    #expect(contents.claims.isEmpty)
    #expect(contents.findings.map(\.ruleID) == [EvidenceCacheContents.corruptLineRuleID])
  }

  @Test(
    "a tombstone hides a refuted claim only in its own pin — catches a refuted fact served again")
  func tombstoneHidesRefutedClaim() async throws {
    let home = try ScratchHome()
    defer { home.remove() }
    let store = home.store()
    let refuted = try Claims.reusable(
      Claims.packageClaim(
        "ev-effect-run-retries-on-failure", text: "Effect.run retries on failure.",
        quote: "public static func run("))
    let kept = try Claims.reusable(
      Claims.packageClaim(
        "ev-effect-run-is-cancellable", text: "Effect.run can be cancelled.",
        quote: "public func cancellable<ID"))
    let samePinElsewhere = try Claims.reusable(
      Claims.packageClaim(
        "ev-effect-run-retries-on-failure", text: "Effect.run retries on failure.",
        quote: "public static func run(", version: "1.27.0"))

    #expect(try await store.record(refuted, origin: .researchLane) == .appended)
    #expect(try await store.record(kept, origin: .researchLane) == .appended)
    #expect(try await store.record(samePinElsewhere, origin: .researchLane) == .appended)
    try await store.tombstone(refuted, reason: .refuted)

    let contents = try store.contents(of: refuted.bucket)
    #expect(contents.claims.map(\.claim) == [kept])
    #expect(contents.tombstones[refuted.fingerprint] == .refuted)
    #expect(try await store.record(refuted, origin: .researchLane) == .tombstoned(.refuted))
    #expect(
      try store.contents(of: samePinElsewhere.bucket).claims.map(\.claim) == [samePinElsewhere])
  }

  @Test("reuse increments the count of the entry reused — catches a cache hit that isn't counted")
  func reuseCountIncrements() async throws {
    let home = try ScratchHome()
    defer { home.remove() }
    let store = home.store()
    let claim = try Claims.reusable(
      Claims.packageClaim(
        "ev-effect-run-is-cancellable", text: "Effect.run can be cancelled.",
        quote: "public func cancellable<ID"))
    let other = try Claims.reusable(
      Claims.packageClaim(
        "ev-effect-send-is-main-actor", text: "Send is MainActor.", quote: "@MainActor"))
    try await store.record(claim, origin: .researchLane)
    try await store.record(other, origin: .researchLane)
    try await store.recordVerdict(.supported, for: claim, origin: .claimChecker)

    try await store.markReused(claim)
    try await store.markReused(claim)
    try await store.markVerdictReused(claim.fingerprint)

    let contents = try store.contents(of: claim.bucket)
    #expect(contents.claim(claim.fingerprint)?.reuseCount == 2)
    #expect(contents.claim(other.fingerprint)?.reuseCount == 0)
    let verdict = try store.contents(of: .verdicts).verdict(
      text: "Effect.run can be cancelled.", quote: "public func cancellable<ID")
    #expect(verdict == CachedVerdict(verdict: .supported, origin: .claimChecker, reuseCount: 1))

    let uncached = try Claims.reusable(
      Claims.packageClaim("ev-never-recorded-claim-here", text: "never", quote: "never"))
    await #expect(throws: EvidenceCacheStoreError.notCached(uncached.fingerprint)) {
      try await store.markReused(uncached)
    }
  }

  @Test(
    "sixteen concurrent writers' appends all land and every line parses — catches a lost update from an unlocked rewrite"
  )
  func concurrentAppendsAllLand() async throws {
    let writers = 16
    let perWriter = 4
    // `swift test` 6.2 can't repeat a test, so the race is exercised by looping here instead.
    for iteration in 0..<5 {
      let home = try ScratchHome()
      defer { home.remove() }
      await withTaskGroup(of: Void.self) { group in
        for writer in 0..<writers {
          group.addTask {
            let store = home.store()
            for index in 0..<perWriter {
              do {
                let claim = try ReusableClaim(SelfRelaunch.claim(writer: writer, index: index))
                let write = try await store.record(claim, origin: .researchLane)
                #expect(write == .appended)
              } catch {
                Issue.record("iteration \(iteration) writer \(writer) failed: \(error)")
              }
            }
          }
        }
      }
      try Self.expectEveryWriterLanded(home: home, writers: writers, perWriter: perWriter)
    }
  }

  @Test(
    "eight writer processes appending to one cache lose nothing — catches a lock that only serialises within a process",
    .enabled(
      if: SelfRelaunch.isAvailable, "needs the swift-testing helper to relaunch this bundle"),
    .disabled(if: SelfRelaunch.isChild, "a relaunched child runs only its writer"))
  func crossProcessAppendsAllLand() async throws {
    let helper = ProcessInfo.processInfo.arguments[0]
    let bundle = try #require(SelfRelaunch.bundlePath)
    let home = try ScratchHome()
    defer { home.remove() }
    let writers = 8
    let runner = LiveProcessRunner()

    let outputs = await withTaskGroup(of: (Int, ProcessOutput?).self) { group in
      for writer in 0..<writers {
        group.addTask {
          let invocation = ProcessInvocation(
            executable: helper,
            arguments: [
              "--test-bundle-path", bundle, bundle, "--testing-library", "swift-testing",
              "--filter", "crossProcessWriterChild",
            ],
            environmentOverlay: [
              SelfRelaunch.homeVariable: home.url.path,
              SelfRelaunch.writerVariable: String(writer),
              "LLVM_PROFILE_FILE": home.url.appending(path: "child-%p.profraw").path,
            ],
            timeout: .seconds(300))
          do throws(ProcessRunnerError) {
            return (writer, try await runner.run(invocation))
          } catch {
            Issue.record(error, "writer \(writer) didn't run")
            return (writer, nil)
          }
        }
      }
      return await group.reduce(into: [:]) { $0[$1.0] = $1.1 }
    }

    for (writer, output) in outputs.sorted(by: { $0.key < $1.key }) {
      #expect(
        output.status.isSuccess,
        "writer \(writer) exited \(output.status): \(output.stdout.text) \(output.stderr.text)")
    }
    try Self.expectEveryWriterLanded(
      home: home, writers: writers, perWriter: SelfRelaunch.claimsPerWriter)
  }

  @Test(
    "a relaunched writer process appends its own claims — catches a child that wrote nothing",
    .enabled(if: SelfRelaunch.isChild, "runs only when relaunched by the cross-process test"))
  func crossProcessWriterChild() async throws {
    let environment = ProcessInfo.processInfo.environment
    let home = URL(
      filePath: try #require(environment[SelfRelaunch.homeVariable]), directoryHint: .isDirectory)
    let writer = try #require(environment[SelfRelaunch.writerVariable].flatMap { Int($0) })
    let layout = EvidenceCacheLayout(home: home.path)
    let store = EvidenceCacheStore(
      home: home,
      lock: FileCountingLock(
        directory: URL(filePath: layout.root), name: EvidenceCacheStore.lockName, capacity: 1,
        pollInterval: .milliseconds(2)))
    for index in 0..<SelfRelaunch.claimsPerWriter {
      let claim = try ReusableClaim(SelfRelaunch.claim(writer: writer, index: index))
      #expect(try await store.record(claim, origin: .researchLane) == .appended)
    }
  }

  @Test(
    "a checker verdict recorded from one repo is reused by another sharing the home — catches a verdict keyed by repo or claim id"
  )
  func verdictReusedAcrossRepos() async throws {
    let home = try ScratchHome()
    defer { home.remove() }
    let firstRepo = try ScratchHome()
    let secondRepo = try ScratchHome()
    defer {
      firstRepo.remove()
      secondRepo.remove()
    }
    let text = "Effect.run returns an effect that can be cancelled by id."
    let quote = "public func cancellable<ID: Hashable & Sendable>(id: ID) -> Self"
    // Each repo's claim has its own id and line range; only the text and quote are shared.
    let fromFirst = try Claims.reusable(
      Claims.packageClaim("ev-first-repo-effect-cancels", text: text, quote: quote))
    let fromSecond = try Claims.reusable(
      Claims.packageClaim(
        "ev-second-repo-effect-cancels", text: text, quote: quote, lines: "L90-L99"))

    let firstStore = EvidenceCacheStore(home: home.url)
    #expect(
      try await firstStore.recordVerdict(.supported, for: fromFirst, origin: .claimChecker)
        == .appended)

    let secondStore = EvidenceCacheStore(home: home.url)
    let verdicts = try secondStore.contents(of: .verdicts)
    #expect(verdicts.verdicts[fromSecond.fingerprint]?.verdict == .supported)
    #expect(verdicts.verdict(text: text, quote: quote)?.origin == .claimChecker)
    #expect(verdicts.verdict(text: text, quote: quote + " ") == nil)
    #expect(verdicts.verdict(text: text + ".", quote: quote) == nil)
    #expect(
      try secondStore.layout.file(.verdicts)
        == home.url.path + "/.swift-harness/evidence-cache/verdicts.jsonl")
    #expect(FileManager.default.subpaths(atPath: firstRepo.url.path) == [])
    #expect(FileManager.default.subpaths(atPath: secondRepo.url.path) == [])
  }

  @Test(
    "a corrupt cache line is reported by file and line and kept on the next write — catches corruption silently dropped"
  )
  func corruptLineSurfaces() async throws {
    let home = try ScratchHome()
    defer { home.remove() }
    let store = home.store()
    let good = try Claims.reusable(
      Claims.packageClaim("ev-effect-run-is-cancellable", text: "good", quote: "good"))
    try await store.record(good, origin: .researchLane)
    let file = try store.layout.file(good.bucket)
    let handle = try FileHandle(forWritingTo: URL(filePath: file))
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("{\"type\":\"gossip\"}\n{\"type\":\"claim\",\"orig".utf8))
    try handle.close()
    let damaged = try Data(contentsOf: URL(filePath: file))

    let contents = try store.contents(of: good.bucket)
    #expect(contents.claims.map(\.claim) == [good])
    #expect(contents.findings.map(\.file) == [file, file])
    #expect(contents.findings.map(\.line) == [2, 3])
    #expect(contents.findings.allSatisfy { $0.severity == .minor })

    let next = try Claims.reusable(
      Claims.packageClaim("ev-effect-send-is-main-actor", text: "next", quote: "next"))
    try await store.record(next, origin: .researchLane)
    let rewritten = try Data(contentsOf: URL(filePath: file))
    #expect(rewritten.starts(with: damaged))
    let after = try store.contents(of: good.bucket)
    #expect(after.claims.map(\.claim) == [good, next])
    #expect(after.findings.map(\.line) == [2, 3])
  }

  @Test(
    "a quoteless verdict, a pin that is a path, and a second tombstone write nothing — catches cache files named or keyed by bad input"
  )
  func refusedWritesLeaveCacheUntouched() async throws {
    let home = try ScratchHome()
    defer { home.remove() }
    let store = home.store()
    let probe = try ReusableClaim(
      Claim(
        id: "ev-navigation-stack-path-init-exists", lane: "apple-docs", text: "t",
        citation: Citation(kind: .probe, loc: "probes/Probe_x.swift", pin: "iphoneos26.0"),
        status: .supported))
    await #expect(throws: EvidenceCacheStoreError.missingQuote(claimID: probe.claim.id)) {
      try await store.recordVerdict(.supported, for: probe, origin: .probe)
    }
    #expect(throws: EvidenceCacheStoreError.invalidBucket(.invalidPin("../escape@1"))) {
      try store.contents(of: .package(pin: "../escape@1"))
    }
    #expect(FileSystemConditions.contents(of: home.url.path).isEmpty)

    try await store.record(probe, origin: .probe)
    try await store.tombstone(probe, reason: .amended)
    let before = try Data(contentsOf: URL(filePath: try store.layout.file(probe.bucket)))
    try await store.tombstone(probe, reason: .refuted)
    #expect(try Data(contentsOf: URL(filePath: try store.layout.file(probe.bucket))) == before)
    #expect(try store.contents(of: probe.bucket).tombstones[probe.fingerprint] == .amended)
  }

  private static func expectEveryWriterLanded(home: ScratchHome, writers: Int, perWriter: Int)
    throws
  {
    let store = home.store()
    let bucket = EvidenceCacheBucket.package(pin: "\(Claims.package)@1.26.2")
    let data = try Data(contentsOf: URL(filePath: try store.layout.file(bucket)))
    let lines = data.split(separator: UInt8(ascii: "\n"))
    #expect(lines.count == writers * perWriter, "lost or extra lines")
    for line in lines {
      #expect(throws: Never.self) {
        try JSONDecoder().decode(EvidenceCacheRecord.self, from: Data(line))
      }
    }
    let contents = try store.contents(of: bucket)
    #expect(contents.findings.isEmpty)
    let expected = Set(
      (0..<writers).flatMap { writer in
        (0..<perWriter).map { "ev-writer-\(writer)-claim-\($0)" }
      })
    #expect(Set(contents.claims.map(\.claim.claim.id)) == expected)
  }
}
