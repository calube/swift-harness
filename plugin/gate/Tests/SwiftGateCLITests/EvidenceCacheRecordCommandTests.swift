import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

/// `evidence cache record` runs through the built binary, the way the design skill calls it, and
/// the reuse it promises is read back through a second built command (`context-pack --role
/// research-lane`) in a different design. Every repository and cache home is a fresh temp
/// directory, so no test touches this checkout or the real `~/.swift-harness`.
@Suite("swiftgate evidence cache record")
struct EvidenceCacheRecordCommandTests {
  private static let packagePin = "swift-composable-architecture@1.26.2"
  private static let firstDesign = "docs/checkout/designs/offline-order-queue.md"
  private static let secondDesign = "docs/payments/designs/card-retry.md"

  private static let gitEnvironment: [String: String] = [
    "PATH": "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin",
    "HOME": TestTemporaryDirectory.sharedHome.path,
    "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
    "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.com",
    "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.com",
  ]

  // MARK: - Fixtures

  private struct Repository {
    let root: URL
    let runner = LiveProcessRunner(baseEnvironment: EvidenceCacheRecordCommandTests.gitEnvironment)

    init() throws {
      root = TestTemporaryDirectory.root
        .appending(path: "swiftgate-cache-record-\(UUID().uuidString)", directoryHint: .isDirectory)
        .resolvingSymlinksInPath()
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    var cacheHome: String { root.appending(path: "cache-home").path }
    var cacheRoot: URL { URL(filePath: EvidenceCacheLayout(home: cacheHome).root) }

    func remove() { TestTemporaryDirectory.remove(root) }

    func write(_ contents: String, at relativePath: String) throws {
      let url = root.appending(path: relativePath)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(contents.utf8).write(to: url)
    }

    func writeClaims(_ claims: [Claim], design: String) throws {
      let lines = try claims.map { String(decoding: try ClaimJSON.encodeLine($0), as: UTF8.self) }
      try write(lines.joined(), at: EvidenceLayout(designDocPath: design).claimsFile)
    }

    /// The minimum `context-pack --role research-lane` needs to write a pack: a config naming one
    /// real package (the module graph is loaded with `swift package describe`), frame answers
    /// touching no module, a graph dump and a brief.
    func seedResearchInputs() throws {
      try write(
        """
        schema = 1
        xcode = "26.2"
        app_scheme = "Sample"
        packages = ["Sample"]

        [simulator]
        device = "iPhone 17"
        os = "26.2"
        """, at: ConfigLoader.fileName)
      try write(
        """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(name: "Sample", targets: [.target(name: "Core")])
        """, at: "Sample/Package.swift")
      try write("public let core = 1\n", at: "Sample/Sources/Core/Core.swift")
      try write(
        "{\"schemaVersion\": 1, \"touchedModules\": [], \"newModules\": [], "
          + "\"newDependencies\": []}", at: "frame-answers.json")
      try write("Core", at: "module-graph.txt")
      try write("How does the store scope child state?", at: "lane-brief.md")
    }

    @discardableResult
    func git(_ arguments: [String]) async throws -> ProcessOutput {
      let output = try await runner.run(
        ProcessInvocation(
          executable: "git", arguments: arguments, workingDirectory: root.path,
          timeout: .seconds(60)))
      #expect(output.status.isSuccess, "git \(arguments): \(output.stderr.text)")
      return output
    }

    func swiftgate(_ arguments: [String]) async throws -> ProcessOutput {
      let binary = Fixture.gateDirectory.appending(path: ".build/debug/swiftgate").path
      return try await runner.run(
        ProcessInvocation(
          executable: binary, arguments: arguments,
          environmentOverlay: [
            "LLVM_PROFILE_FILE": root.appending(path: "swiftgate-%p.profraw").path
          ],
          workingDirectory: root.path, timeout: .seconds(300)))
    }

    /// The same argv first parses in process to the `record` leaf, so a command the binary
    /// doesn't have fails here by name rather than as an opaque exit code.
    func record(_ design: String, extra: [String] = []) async throws -> ProcessOutput {
      let arguments =
        ["evidence", "cache", "record", "--design", design, "--cache-home", cacheHome, "--json"]
        + extra
      do {
        let parsed = try await SwiftGate.asyncParseAsRoot(arguments)
        #expect(type(of: parsed).configuration.commandName == "record")
      } catch {
        Issue.record("`swiftgate \(arguments.joined(separator: " "))` doesn't parse: \(error)")
      }
      return try await swiftgate(arguments)
    }

    /// The research-lane pack a second design gets for `pin`: the text a lane would read.
    func researchPack(pin: String, design: String = EvidenceCacheRecordCommandTests.secondDesign)
      async throws -> String
    {
      let output = try await swiftgate([
        "context-pack", "--role", "research-lane", "--key", "packages", "--design", design,
        "--pin", pin, "--frame-answers", "frame-answers.json", "--area", "payments",
        "--module-graph", "module-graph.txt", "--brief", "lane-brief.md", "--cache-home",
        cacheHome,
      ])
      #expect(
        output.status == .exited(0), "context-pack: \(output.stdout.text)\(output.stderr.text)")
      return try String(
        contentsOf: root.appending(path: ".harness/context-pack/research-lane-packages.md"),
        encoding: .utf8)
    }

    /// Every cache file's bytes by path relative to the cache root, lock files excluded.
    func cacheFiles() throws -> [String: Data] {
      var files: [String: Data] = [:]
      guard
        let walker = FileManager.default.enumerator(
          at: cacheRoot, includingPropertiesForKeys: [.isRegularFileKey])
      else { return files }
      for case let url as URL in walker where url.pathExtension == "jsonl" {
        let relative = String(
          url.resolvingSymlinksInPath().path.dropFirst(
            cacheRoot.resolvingSymlinksInPath().path.count + 1))
        files[relative] = try Data(contentsOf: url)
      }
      return files
    }
  }

  private static func packageClaim(
    id: String, text: String, quote: String, status: Claim.Status, pin: String = packagePin
  ) -> Claim {
    let package = String(pin.prefix { $0 != "@" })
    return Claim(
      id: id, lane: "packages", text: text,
      citation: Citation(
        kind: .file, loc: ".build/checkouts/\(package)/Sources/Store.swift:L10-L12", pin: pin,
        quote: quote),
      status: status)
  }

  private static let scopes = packageClaim(
    id: "ev-store-scopes-child-state", text: "Store.scope derives a child store from a key path",
    quote: "public func scope<ChildState, ChildAction>(", status: .supported)
  private static let refutedSharing = packageClaim(
    id: "ev-store-shares-reducer-instance", text: "Scoped stores share one reducer instance",
    quote: "let reducer: Reducer", status: .refuted)
  private static let codebase = Claim(
    id: "ev-order-queue-drains-fifo", lane: "codebase",
    text: "OrderQueue drains its pending orders first in first out",
    citation: Citation(
      kind: .file, loc: "Sources/OrderQueue/OrderQueue.swift:L3-L5",
      pin: "0123456789abcdef0123456789abcdef01234567", quote: "pending.removeFirst()"),
    status: .supported)
  private static let snapshot = Claim(
    id: "ev-navigation-stack-takes-path", lane: "apple-docs",
    text: "NavigationStack takes a binding to a path",
    citation: Citation(
      kind: .snapshot, loc: "snapshots/navigationstack.md", pin: "26.2",
      quote: "init(path: Binding<Data>"),
    status: .supported)

  private static func report(_ output: ProcessOutput) throws -> [String: Any] {
    let object = try JSONSerialization.jsonObject(with: output.stdout.bytes)
    return try #require(object as? [String: Any], "not a JSON object: \(output.stdout.text)")
  }

  // MARK: - Reuse across designs

  @Test(
    "after record, a second design's research-lane pack for the same package pin serves the supported claim — catches a verify phase that never writes the reuse cache"
  )
  func recordedClaimIsAHitForAnotherDesign() async throws {
    let repo = try Repository()
    defer { repo.remove() }
    try repo.seedResearchInputs()
    try repo.writeClaims([Self.scopes, Self.codebase, Self.snapshot], design: Self.firstDesign)

    let before = try await repo.researchPack(pin: Self.packagePin)
    #expect(before.contains("no cache hits for \(Self.packagePin)"))

    let output = try await repo.record(Self.firstDesign)
    #expect(output.status == .exited(0), "\(output.stdout.text)\(output.stderr.text)")

    let after = try await repo.researchPack(pin: Self.packagePin)
    #expect(!after.contains("no cache hits for \(Self.packagePin)"), "\(after)")
    #expect(after.contains(Self.scopes.id))
    #expect(after.contains(Self.scopes.text))

    let store = EvidenceCacheStore(home: URL(filePath: repo.cacheHome, directoryHint: .isDirectory))
    let sdk = try store.contents(of: .sdk(pin: "26.2"))
    #expect(sdk.claims.map(\.claim.claim.id) == [Self.snapshot.id])
    #expect(sdk.claims.first?.origin == .researchLane)
    let verdicts = try store.contents(of: .verdicts)
    #expect(
      verdicts.verdict(text: Self.scopes.text, quote: Self.scopes.citation.quote ?? "")
        == CachedVerdict(verdict: .supported, origin: .claimChecker, reuseCount: 0))
  }

  // MARK: - Refuted claims

  @Test(
    "a refuted claim is tombstoned in its pin's file, so another design's supported copy stops being served — catches a refuted fact reused as a hit"
  )
  func refutedClaimIsTombstonedAndNotServed() async throws {
    let repo = try Repository()
    defer { repo.remove() }
    try repo.seedResearchInputs()
    let supportedElsewhere = Self.packageClaim(
      id: "ev-store-shares-reducer-instance", text: Self.refutedSharing.text,
      quote: Self.refutedSharing.citation.quote ?? "", status: .supported)
    try repo.writeClaims([supportedElsewhere], design: Self.secondDesign)
    let seeded = try await repo.record(Self.secondDesign)
    #expect(seeded.status == .exited(0), "\(seeded.stdout.text)")
    #expect(try await repo.researchPack(pin: Self.packagePin).contains(supportedElsewhere.id))

    try repo.writeClaims([Self.scopes, Self.refutedSharing], design: Self.firstDesign)
    let output = try await repo.record(Self.firstDesign)
    #expect(output.status == .exited(0), "\(output.stdout.text)\(output.stderr.text)")

    let pack = try await repo.researchPack(pin: Self.packagePin)
    #expect(pack.contains(Self.scopes.id))
    #expect(!pack.contains(Self.refutedSharing.id), "\(pack)")
    #expect(!pack.contains(Self.refutedSharing.text), "\(pack)")

    let store = EvidenceCacheStore(home: URL(filePath: repo.cacheHome, directoryHint: .isDirectory))
    let bucket = try store.contents(of: .package(pin: Self.packagePin))
    let fingerprint = try ReusableClaim(Self.refutedSharing).fingerprint
    #expect(bucket.tombstones[fingerprint] == .refuted)
  }

  // MARK: - Codebase claims

  @Test(
    "a codebase claim reaches no cache file, neither as a claim nor as a verdict — catches code facts cached across commits"
  )
  func codebaseClaimsAreNeverRecorded() async throws {
    let repo = try Repository()
    defer { repo.remove() }
    try repo.writeClaims([Self.codebase, Self.scopes], design: Self.firstDesign)

    let output = try await repo.record(Self.firstDesign)
    #expect(output.status == .exited(0), "\(output.stdout.text)\(output.stderr.text)")

    let files = try repo.cacheFiles()
    #expect(!files.isEmpty, "the package claim beside it should have been recorded")
    let textHash = EvidenceFingerprint(text: Self.codebase.text, quote: nil).textHash
    for (path, data) in files {
      let text = String(decoding: data, as: UTF8.self)
      #expect(!text.contains(Self.codebase.id), "\(path) holds the codebase claim")
      #expect(!text.contains(textHash), "\(path) holds the codebase claim's verdict")
    }
    let skipped = try #require(try Self.report(output)["skipped"] as? [[String: Any]])
    #expect(
      skipped.contains {
        $0["claimId"] as? String == Self.codebase.id && $0["reason"] as? String == "codebase"
      }, "\(skipped)")
  }

  // MARK: - Idempotence

  @Test(
    "a second record run over the same claims leaves every cache file byte for byte as it was — catches duplicate entries piling up per verify run"
  )
  func secondRunIsIdempotent() async throws {
    let repo = try Repository()
    defer { repo.remove() }
    try repo.writeClaims(
      [Self.scopes, Self.refutedSharing, Self.codebase, Self.snapshot], design: Self.firstDesign)

    let first = try await repo.record(Self.firstDesign)
    #expect(first.status == .exited(0), "\(first.stdout.text)\(first.stderr.text)")
    let afterFirst = try repo.cacheFiles()
    #expect(afterFirst.count == 3, "\(afterFirst.keys.sorted())")

    let second = try await repo.record(Self.firstDesign)
    #expect(second.status == .exited(0), "\(second.stdout.text)\(second.stderr.text)")
    #expect(try repo.cacheFiles() == afterFirst)
    let writes = try #require(try Self.report(second)["writes"] as? [[String: Any]])
    #expect(!writes.isEmpty)
    #expect(writes.allSatisfy { $0["outcome"] as? String != "appended" }, "\(writes)")
  }

  // MARK: - Amends

  @Test(
    "with --base, a claim an amend replaced is tombstoned and its replacement served — catches the superseded fact outliving the amend"
  )
  func amendReplacedClaimIsTombstoned() async throws {
    let repo = try Repository()
    defer { repo.remove() }
    try repo.seedResearchInputs()
    try await repo.git(["init", "-q", "-b", "main"])
    try await repo.git(["config", "commit.gpgsign", "false"])
    let original = Self.packageClaim(
      id: "ev-store-scopes-child-state", text: "Store.scope takes a state key path",
      quote: "public func scope<ChildState>(state:", status: .supported)
    try repo.writeClaims([original], design: Self.firstDesign)
    #expect(try await repo.record(Self.firstDesign).status == .exited(0))
    try await repo.git(["add", "-A"])
    try await repo.git(["commit", "-q", "-m", "approved"])
    #expect(try await repo.researchPack(pin: Self.packagePin).contains(original.text))

    try repo.writeClaims([Self.scopes], design: Self.firstDesign)
    let output = try await repo.record(Self.firstDesign, extra: ["--base", "main"])
    #expect(output.status == .exited(0), "\(output.stdout.text)\(output.stderr.text)")

    let pack = try await repo.researchPack(pin: Self.packagePin)
    #expect(pack.contains(Self.scopes.text))
    #expect(!pack.contains(original.text), "\(pack)")
    let store = EvidenceCacheStore(home: URL(filePath: repo.cacheHome, directoryHint: .isDirectory))
    let bucket = try store.contents(of: .package(pin: Self.packagePin))
    #expect(bucket.tombstones[try ReusableClaim(original).fingerprint] == .amended)
  }

  // MARK: - Bad input

  @Test(
    "a design with no claims file exits 2 and writes no cache — catches a record run that reports success over nothing"
  )
  func missingClaimsFileIsBlocked() async throws {
    let repo = try Repository()
    defer { repo.remove() }
    let output = try await repo.record(Self.firstDesign)
    #expect(output.status == .exited(2), "\(output.stdout.text)")
    #expect(try Self.report(output)["verdict"] as? String == "BLOCKED")
    #expect(try repo.cacheFiles().isEmpty)
  }
}
