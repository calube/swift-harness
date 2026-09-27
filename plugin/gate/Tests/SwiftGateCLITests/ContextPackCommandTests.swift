import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

/// `context-pack` gathers a role's raw inputs from real files under a temp repo root and hands
/// them to the existing domain slicers (`SwiftGateDomain/Context/ContextPack.swift`). These tests
/// never touch this checkout's own files — every fixture lives under a fresh temp directory
/// (worker-brief pitfall 7).
@Suite("swiftgate context-pack")
struct ContextPackCommandTests {
  // MARK: - Fixtures

  /// The repo's real, spec-compliant design doc, read once so every test's copy matches the
  /// document `DesignDocument`/`MarkdownAnchorSlicer` are also tested against.
  private let designFixtureText: String

  init() throws {
    let url = URL(filePath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appending(path: "Fixtures/design/valid.md")
    designFixtureText = try String(contentsOf: url, encoding: .utf8)
  }

  private static func claimLine(
    id: String, kind: Citation.Kind = .file, loc: String, pin: String?, quote: String? = nil,
    status: Claim.Status = .supported
  ) throws -> String {
    let claim = Claim(
      id: id, lane: "packages", text: "some claim text",
      citation: Citation(kind: kind, loc: loc, pin: pin, quote: quote), status: status)
    let data = try JSONEncoder().encode(claim)
    return String(decoding: data, as: UTF8.self)
  }

  private struct Repository {
    let root: URL

    init() throws {
      root = FileManager.default.temporaryDirectory
        .appending(
          path: "swiftgate-context-pack-\(UUID().uuidString)", directoryHint: .isDirectory
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

    func packText(_ relativePath: String) throws -> String {
      try String(contentsOf: root.appending(path: relativePath), encoding: .utf8)
    }

    func packExists(_ relativePath: String) -> Bool {
      FileManager.default.fileExists(atPath: root.appending(path: relativePath).path)
    }

    /// Seeds a `.swiftgate.toml` and one package (`OrderQueueCore` depended on by
    /// `OrderQueueFeature`) so `context-pack --role research-lane` can validate touched-module
    /// names against a real module graph, the same way `design-scope` does — through
    /// `ConfigLoader`/`ModuleGraphLoader` against a scripted `FakeSwiftPM`, never a live
    /// `swift package describe`.
    static let modulePackagePath = "Sample"

    @discardableResult
    func seedModuleGraph() throws -> FakeSwiftPM {
      let package = root.appending(path: Self.modulePackagePath, directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
      try Data("// swift-tools-version: 6.2\n".utf8).write(
        to: package.appending(path: "Package.swift"))
      try write(
        """
        schema = 1
        xcode = "26.2"
        app_scheme = "Sample"
        packages = ["\(Self.modulePackagePath)"]

        [simulator]
        device = "iPhone 17"
        os = "26.2"
        """, at: ConfigLoader.fileName)
      let manifest = PackageManifest(
        name: "Sample", path: Self.modulePackagePath,
        targets: [
          PackageTarget(
            name: "OrderQueueCore", type: .library,
            path: "\(Self.modulePackagePath)/Sources/OrderQueueCore"),
          PackageTarget(
            name: "OrderQueueFeature", type: .library,
            path: "\(Self.modulePackagePath)/Sources/OrderQueueFeature",
            targetDependencies: ["OrderQueueCore"]),
        ])
      return FakeSwiftPM(serving: [manifest])
    }
  }

  /// Unused by every role except research lane; a placeholder so those tests don't have to seed
  /// a module graph they never read.
  private static let unusedSwiftPM = FakeSwiftPM(serving: [])

  // MARK: - Bad `--role`

  @Test("an unknown --role names it and never falls through to a role's builder — exit 2")
  func unknownRoleIsInvalid() async throws {
    let repository = try Repository()
    defer { repository.remove() }
    let outcome = await ContextPackRun.run(
      role: "not-a-role", options: ContextPackGatherInputs(), root: repository.root,
      swiftPM: Self.unusedSwiftPM)
    guard case .invalid(let message) = outcome else {
      Issue.record("expected .invalid, got \(outcome)")
      return
    }
    #expect(message.contains("not-a-role"))
  }

  // MARK: - Missing input, never a silent fallback

  @Test("an unreadable required input names its path — exit 2, never a silent fallback")
  func unreadableRequiredInputIsInvalid() async throws {
    let repository = try Repository()
    defer { repository.remove() }
    var options = ContextPackGatherInputs()
    options.design = "docs/does-not-exist.md"
    options.ledger = "ledger.json"
    options.taskID = "whatever"
    let outcome = await ContextPackRun.run(
      role: "worker", options: options, root: repository.root, swiftPM: Self.unusedSwiftPM)
    guard case .invalid(let message) = outcome else {
      Issue.record("expected .invalid, got \(outcome)")
      return
    }
    #expect(message.contains("docs/does-not-exist.md"))
  }

  // MARK: - Missing anchor: a violation, never a thin pack

  @Test(
    "a missing standards anchor is a violation naming the anchor and its source — exit 1, never an empty pack"
  )
  func missingStandardsAnchorIsAViolation() async throws {
    let repository = try Repository()
    defer { repository.remove() }
    let designPath = try repository.write(
      designFixtureText, at: "docs/checkout/designs/offline-order-queue.md")
    let standardsPath = try repository.write(
      "## Existing heading\n\nSome text.\n", at: "docs/standards.md")

    var options = ContextPackGatherInputs()
    options.design = designPath
    options.standards = standardsPath
    options.standardsAnchor = ["not-a-real-anchor"]

    let outcome = await ContextPackRun.run(
      role: "standards-reviewer", options: options, root: repository.root,
      swiftPM: Self.unusedSwiftPM)
    guard case .violation(let message) = outcome else {
      Issue.record("expected .violation, got \(outcome)")
      return
    }
    #expect(message.contains("not-a-real-anchor"))
    #expect(message.contains(standardsPath))
    #expect(!repository.packExists(".harness/context-pack/standards-reviewer.md"))
  }

  // MARK: - Optional input absent: noted, never silently dropped

  @Test("an absent optional input (claims) is named as a note, and the pack is still written")
  func absentOptionalInputIsNoted() async throws {
    let repository = try Repository()
    defer { repository.remove() }
    let designPath = try repository.write(
      designFixtureText, at: "docs/checkout/designs/offline-order-queue.md")
    let task = LedgerTask(
      id: "task-1", deps: [], writeSet: ["Packages/A/"], gate: .push, tests: [], covers: [],
      estLines: 40, status: .pending, worktree: "../a-task-1")
    let ledgerData = try LedgerJSON.encode(
      Ledger(schemaVersion: 1, resume: "resume", maxParallel: 3, tasks: [task], waves: [["task-1"]])
    )
    let ledgerPath = try repository.write(
      String(decoding: ledgerData, as: UTF8.self), at: "ledger.json")

    var options = ContextPackGatherInputs()
    options.design = designPath
    options.ledger = ledgerPath
    options.taskID = task.id

    let outcome = await ContextPackRun.run(
      role: "worker", options: options, root: repository.root, swiftPM: Self.unusedSwiftPM)
    guard case .written(let written) = outcome else {
      Issue.record("expected .written, got \(outcome)")
      return
    }
    #expect(written.notes.contains { $0.contains("--claims not given") })
    let text = try repository.packText(written.relativePath)
    #expect(text.contains("--claims not given"))
  }

  // MARK: - Worker: the fixture task's expected sections

  @Test(
    "worker pack for a fixture task holds its covered design sections, cited claims, standards anchor and gate tier"
  )
  func workerPackHasExpectedSections() async throws {
    let repository = try Repository()
    defer { repository.remove() }
    let designPath = try repository.write(
      designFixtureText, at: "docs/checkout/designs/offline-order-queue.md")

    let hit = try Self.claimLine(id: "ev-cited", loc: "Sources/Hit.swift:L1-L1", pin: "p")
    let miss = try Self.claimLine(id: "ev-not-cited", loc: "Sources/Miss.swift:L1-L1", pin: "p")
    let claimsPath = try repository.write(
      "\(hit)\n\(miss)\n",
      at: "docs/checkout/designs/offline-order-queue.evidence/claims.jsonl")

    let standardsPath = try repository.write(
      "## 2. Architecture\n\nCore modules hold logic, features own screens.\n",
      at: "docs/standards.md")

    let task = LedgerTask(
      id: "offline-queue-core-reducer", deps: [],
      writeSet: ["Packages/OrderQueue/Sources/OrderQueueCore/"], gate: .push,
      tests: ["test-queued-orders-replay-in-submit-order"],
      covers: [
        "req-offline-queue-drains-on-reconnect", "test-queued-orders-replay-in-submit-order",
      ],
      estLines: 180, status: .pending,
      worktree: "../myapp-offline-queue-core-reducer")
    let ledgerData = try LedgerJSON.encode(
      Ledger(
        schemaVersion: 1, resume: "resume", maxParallel: 3, tasks: [task],
        waves: [[task.id]]))
    let ledgerPath = try repository.write(
      String(decoding: ledgerData, as: UTF8.self), at: "ledger.json")

    var options = ContextPackGatherInputs()
    options.design = designPath
    options.ledger = ledgerPath
    options.taskID = task.id
    options.claims = claimsPath
    options.claimID = ["ev-cited"]
    options.moduleKind = ["feature"]
    options.standards = standardsPath

    let outcome = await ContextPackRun.run(
      role: "worker", options: options, root: repository.root, swiftPM: Self.unusedSwiftPM)
    guard case .written(let written) = outcome else {
      Issue.record("expected .written, got \(outcome)")
      return
    }
    #expect(written.relativePath == ".harness/context-pack/worker-offline-queue-core-reducer.md")
    #expect(written.notes.isEmpty)
    #expect(written.tokens > 0)

    let text = try repository.packText(written.relativePath)
    #expect(text.contains("req-offline-queue-drains-on-reconnect"))
    #expect(text.contains("test-queued-orders-replay-in-submit-order"))
    #expect(text.contains("\"gate\" : \"push\""))
    #expect(text.contains(hit))
    #expect(!text.contains(miss))
    #expect(text.contains("Core modules hold logic, features own screens."))
    // Every worker gets the Decision section, covered or not.
    #expect(text.contains("Client-side queue [ev-tca-effect-run-supports-cancellation]"))
  }

  // MARK: - Research lane: all 5 spec §5.10 parts, plus the evidence reuse cache

  /// A `--cache-home` unique to the calling test, so cache reads/writes never touch a real
  /// `$HOME` (worker-brief pitfall 7) and tests never see each other's cache files.
  private static func freshCacheHome(_ repository: Repository) throws -> String {
    try repository.write("", at: "cache-home/.keep")
    return repository.root.appending(path: "cache-home").path
  }

  private static func packageClaim(id: String, pin: String) -> Claim {
    Claim(
      id: id, lane: "packages", text: "some claim text",
      citation: Citation(
        kind: .file, loc: ".build/checkouts/swift-composable-architecture/Sources/X.swift:L1-L1",
        pin: pin), status: .supported)
  }

  /// The exact frame-answers JSON `design-scope` already decodes (Wave 8's
  /// `{schemaVersion, touchedModules, newModules, newDependencies}`); research-lane reuses that
  /// decoder rather than taking touched-module names as a second, independently-typed CLI input.
  private static func frameAnswersJSON(touching modules: [String]) -> String {
    let names = modules.map { "\"\($0)\"" }.joined(separator: ", ")
    return
      "{\"schemaVersion\": 1, \"touchedModules\": [\(names)], \"newModules\": [], "
      + "\"newDependencies\": []}"
  }

  /// The design being researched; research happens before the doc is drafted, so the file need
  /// not exist.
  private static let researchDesignPath = "docs/checkout/designs/offline-order-queue.md"

  /// `repository.seedModuleGraph()`'s package has `OrderQueueCore` and `OrderQueueFeature`, so
  /// `"OrderQueueCore"` is always a valid touched module here; `--module-graph` still names its
  /// own separate opaque dump (the pack's verbatim text source), same as decomposer's.
  private static func baseResearchLaneOptions(
    repository: Repository, pin: String, cacheHome: String,
    touching modules: [String] = ["OrderQueueCore"], key: String = "packages"
  ) throws -> (options: ContextPackGatherInputs, swiftPM: FakeSwiftPM) {
    let swiftPM = try repository.seedModuleGraph()
    let frameAnswersPath = try repository.write(
      Self.frameAnswersJSON(touching: modules), at: "frame-answers.json")
    let moduleGraphPath = try repository.write(
      "OrderQueueFeature -> OrderQueueCore\nUnrelatedFeature -> UnrelatedCore",
      at: "module-graph.txt")
    let briefPath = try repository.write(
      "Investigate retry semantics.", at: "lane-brief.md")

    var options = ContextPackGatherInputs()
    options.frameAnswers = frameAnswersPath
    options.area = "checkout"
    options.moduleGraph = moduleGraphPath
    options.brief = [briefPath]
    options.pin = pin
    options.cacheHome = cacheHome
    options.key = key
    options.design = Self.researchDesignPath
    return (options, swiftPM)
  }

  @Test(
    "research-lane pack holds all 5 spec parts: frame answers, area, the touched-module graph slice, repo and reuse-cache claim hits, and the lane brief"
  )
  func researchLanePackHasExpectedSections() async throws {
    let repository = try Repository()
    defer { repository.remove() }
    let matchingPin = "swift-composable-architecture@1.26.2"
    let hit = try Self.claimLine(id: "ev-hit", loc: "Sources/Hit.swift:L1-L1", pin: matchingPin)
    let miss = try Self.claimLine(
      id: "ev-miss", loc: "Sources/Miss.swift:L1-L1", pin: "some-other-package@2.0.0")
    let claimsPath = try repository.write("\(hit)\n\(miss)\n", at: "claims.jsonl")

    let cacheHome = try Self.freshCacheHome(repository)
    let store = EvidenceCacheStore(home: URL(filePath: cacheHome, directoryHint: .isDirectory))
    let liveClaim = try ReusableClaim(Self.packageClaim(id: "ev-cache-hit", pin: matchingPin))
    try await store.record(liveClaim, origin: .researchLane)

    var (options, swiftPM) = try Self.baseResearchLaneOptions(
      repository: repository, pin: matchingPin, cacheHome: cacheHome)
    options.claims = claimsPath

    let outcome = await ContextPackRun.run(
      role: "research-lane", options: options, root: repository.root, swiftPM: swiftPM)
    guard case .written(let written) = outcome else {
      Issue.record("expected .written, got \(outcome)")
      return
    }
    #expect(!written.notes.contains { $0.contains("no cache hits") })
    let text = try repository.packText(written.relativePath)
    #expect(text.contains(Self.frameAnswersJSON(touching: ["OrderQueueCore"])))  // frame answers
    #expect(text.contains("checkout"))  // area
    #expect(text.contains("OrderQueueFeature -> OrderQueueCore"))  // touched-module graph slice
    #expect(!text.contains("UnrelatedFeature -> UnrelatedCore"))  // an untouched module is excluded
    #expect(text.contains(hit))  // repo same-pin claim
    #expect(!text.contains(miss))
    #expect(text.contains("ev-cache-hit"))  // evidence reuse cache hit
    #expect(text.contains("Investigate retry semantics."))  // lane brief
  }

  @Test("a touched module the frame answers don't name is not in the module-graph slice")
  func researchLanePackSlicesExactlyTheNamedTouchedModules() async throws {
    let repository = try Repository()
    defer { repository.remove() }
    let cacheHome = try Self.freshCacheHome(repository)
    let (options, swiftPM) = try Self.baseResearchLaneOptions(
      repository: repository, pin: "swift-composable-architecture@1.26.2", cacheHome: cacheHome,
      touching: ["OrderQueueCore"])

    let outcome = await ContextPackRun.run(
      role: "research-lane", options: options, root: repository.root, swiftPM: swiftPM)
    guard case .written(let written) = outcome else {
      Issue.record("expected .written, got \(outcome)")
      return
    }
    let text = try repository.packText(written.relativePath)
    #expect(text.contains("OrderQueueFeature -> OrderQueueCore"))
    #expect(!text.contains("UnrelatedFeature -> UnrelatedCore"))
  }

  @Test(
    "a touched module the frame answers name that isn't in the module graph fails loudly, naming it — exit 2"
  )
  func researchLaneUnknownTouchedModuleFailsWithExitTwo() async throws {
    let repository = try Repository()
    defer { repository.remove() }
    let cacheHome = try Self.freshCacheHome(repository)
    let (options, swiftPM) = try Self.baseResearchLaneOptions(
      repository: repository, pin: "swift-composable-architecture@1.26.2", cacheHome: cacheHome,
      touching: ["Ghost"])

    let outcome = await ContextPackRun.run(
      role: "research-lane", options: options, root: repository.root, swiftPM: swiftPM)
    guard case .invalid(let message) = outcome else {
      Issue.record("expected .invalid, got \(outcome)")
      return
    }
    #expect(message.contains("Ghost"))
    #expect(!repository.packExists(".harness/context-pack/research-lane-packages.md"))
  }

  @Test("a tombstoned evidence-cache claim is absent from the research-lane pack")
  func researchLanePackExcludesTombstonedCacheClaims() async throws {
    let repository = try Repository()
    defer { repository.remove() }
    let pin = "swift-composable-architecture@1.26.2"
    let cacheHome = try Self.freshCacheHome(repository)
    let store = EvidenceCacheStore(home: URL(filePath: cacheHome, directoryHint: .isDirectory))

    let tombstoned = try ReusableClaim(Self.packageClaim(id: "ev-refuted", pin: pin))
    try await store.record(tombstoned, origin: .researchLane)
    try await store.tombstone(tombstoned, reason: .refuted)
    let live = try ReusableClaim(
      Claim(
        id: "ev-still-live", lane: "packages", text: "a different claim",
        citation: Citation(
          kind: .file,
          loc: ".build/checkouts/swift-composable-architecture/Sources/Y.swift:L1-L1", pin: pin),
        status: .supported))
    try await store.record(live, origin: .researchLane)

    let (options, swiftPM) = try Self.baseResearchLaneOptions(
      repository: repository, pin: pin, cacheHome: cacheHome)
    let outcome = await ContextPackRun.run(
      role: "research-lane", options: options, root: repository.root, swiftPM: swiftPM)
    guard case .written(let written) = outcome else {
      Issue.record("expected .written, got \(outcome)")
      return
    }
    #expect(!written.notes.contains { $0.contains("no cache hits") })
    let text = try repository.packText(written.relativePath)
    #expect(text.contains("ev-still-live"))
    #expect(!text.contains("ev-refuted"))
  }

  @Test(
    "an empty evidence reuse cache is a note, not a silently omitted section — the pack is still written"
  )
  func researchLanePackNotesEmptyReuseCache() async throws {
    let repository = try Repository()
    defer { repository.remove() }
    let pin = "swift-composable-architecture@1.26.2"
    let cacheHome = try Self.freshCacheHome(repository)

    let (options, swiftPM) = try Self.baseResearchLaneOptions(
      repository: repository, pin: pin, cacheHome: cacheHome)
    let outcome = await ContextPackRun.run(
      role: "research-lane", options: options, root: repository.root, swiftPM: swiftPM)
    guard case .written(let written) = outcome else {
      Issue.record("expected .written, got \(outcome)")
      return
    }
    #expect(written.notes.contains { $0.contains("no cache hits for \(pin)") })
    let text = try repository.packText(written.relativePath)
    #expect(text.contains("no cache hits for \(pin)"))
  }

  @Test(
    "a codebase lane's commit pin builds its pack and names why no cache applies — catches a commit sha read as a package pin"
  )
  func researchLaneCommitPinSkipsTheReuseCache() async throws {
    let repository = try Repository()
    defer { repository.remove() }
    let commit = "6ee32101d306b2fc36641d5001b89f0d1627618c"
    let cacheHome = try Self.freshCacheHome(repository)
    let (options, swiftPM) = try Self.baseResearchLaneOptions(
      repository: repository, pin: commit, cacheHome: cacheHome, key: "codebase")

    let outcome = await ContextPackRun.run(
      role: "research-lane", options: options, root: repository.root, swiftPM: swiftPM)
    guard case .written(let written) = outcome else {
      Issue.record("expected .written, got \(outcome)")
      return
    }
    #expect(written.notes.contains { $0.contains("\(commit) is a commit") })
    let text = try repository.packText(written.relativePath)
    #expect(text.contains(commit))
  }

  @Test(
    "an SDK pin reads the SDK bucket at the bare version its claims carry — catches an apple-docs pin read as a package pin, or keyed by a string evidence check never compares"
  )
  func researchLaneSDKPinReadsTheSDKBucket() async throws {
    let repository = try Repository()
    defer { repository.remove() }
    let sdk = "iphonesimulator26.2"
    let cacheHome = try Self.freshCacheHome(repository)
    let store = EvidenceCacheStore(home: URL(filePath: cacheHome, directoryHint: .isDirectory))
    let snapshot = try ReusableClaim(
      Claim(
        id: "ev-sdk-snapshot-hit", lane: "apple-docs", text: "a snapshot claim",
        citation: Citation(
          kind: .snapshot, loc: "snapshots/userdefaults.md", pin: "26.2", quote: "UserDefaults"),
        status: .supported))
    try await store.record(snapshot, origin: .researchLane)
    let (options, swiftPM) = try Self.baseResearchLaneOptions(
      repository: repository, pin: sdk, cacheHome: cacheHome, key: "apple-docs")

    let outcome = await ContextPackRun.run(
      role: "research-lane", options: options, root: repository.root, swiftPM: swiftPM)
    guard case .written(let written) = outcome else {
      Issue.record("expected .written, got \(outcome)")
      return
    }
    let text = try repository.packText(written.relativePath)
    #expect(text.contains("ev-sdk-snapshot-hit"))
  }

  @Test(
    "each research lane's pack is written under its own key — catches lanes overwriting one pack"
  )
  func researchLanePackIsWrittenPerLane() async throws {
    let repository = try Repository()
    defer { repository.remove() }
    let cacheHome = try Self.freshCacheHome(repository)
    var (options, swiftPM) = try Self.baseResearchLaneOptions(
      repository: repository, pin: "swift-composable-architecture@1.26.2", cacheHome: cacheHome)
    options.key = "packages"

    let outcome = await ContextPackRun.run(
      role: "research-lane", options: options, root: repository.root, swiftPM: swiftPM)
    guard case .written(let written) = outcome else {
      Issue.record("expected .written, got \(outcome)")
      return
    }
    #expect(written.relativePath == ".harness/context-pack/research-lane-packages.md")
  }

  @Test(
    "the research-lane pack names its pin, the pin its claims carry and the design doc path — catches a lane that can't pin its claims or find its evidence directory"
  )
  func researchLanePackCarriesPinAndDesignPath() async throws {
    let repository = try Repository()
    defer { repository.remove() }
    let cacheHome = try Self.freshCacheHome(repository)
    let (options, swiftPM) = try Self.baseResearchLaneOptions(
      repository: repository, pin: "iphonesimulator26.2", cacheHome: cacheHome, key: "apple-docs")

    let outcome = await ContextPackRun.run(
      role: "research-lane", options: options, root: repository.root, swiftPM: swiftPM)
    guard case .written(let written) = outcome else {
      Issue.record("expected .written, got \(outcome)")
      return
    }
    let text = try repository.packText(written.relativePath)
    #expect(text.contains("pin: iphonesimulator26.2"))
    #expect(text.contains("citation.pin: 26.2"))
    #expect(text.contains("design doc: \(Self.researchDesignPath)"))
    #expect(text.contains("evidence directory: docs/checkout/designs/offline-order-queue.evidence"))
  }

  @Test(
    "the research-lane pack lists the snapshots and captures already stored, and notes when there are none — catches a lane citing a snapshot nobody stored"
  )
  func researchLanePackListsStoredEvidence() async throws {
    let repository = try Repository()
    defer { repository.remove() }
    let cacheHome = try Self.freshCacheHome(repository)
    let (options, swiftPM) = try Self.baseResearchLaneOptions(
      repository: repository, pin: "iphonesimulator26.2", cacheHome: cacheHome, key: "apple-docs")

    let empty = await ContextPackRun.run(
      role: "research-lane", options: options, root: repository.root, swiftPM: swiftPM)
    guard case .written(let bare) = empty else {
      Issue.record("expected .written, got \(empty)")
      return
    }
    #expect(bare.notes.contains { $0.contains("no snapshots or captures stored") })

    let evidence = "docs/checkout/designs/offline-order-queue.evidence"
    try repository.write("Observation text", at: "\(evidence)/snapshots/observation.md")
    try repository.write("out", at: "\(evidence)/captures/\(String(repeating: "a", count: 64)).txt")
    let stored = await ContextPackRun.run(
      role: "research-lane", options: options, root: repository.root, swiftPM: swiftPM)
    guard case .written(let written) = stored else {
      Issue.record("expected .written, got \(stored)")
      return
    }
    let text = try repository.packText(written.relativePath)
    #expect(text.contains("snapshots/observation.md"))
    #expect(text.contains("captures/\(String(repeating: "a", count: 64)).txt"))
    #expect(!written.notes.contains { $0.contains("no snapshots or captures stored") })
  }

  @Test(
    "a short commit sha is read as a commit, not an SDK — catches the codebase lane's pin reading the SDK cache bucket"
  )
  func researchLaneShortShaIsACommit() async throws {
    let repository = try Repository()
    defer { repository.remove() }
    let cacheHome = try Self.freshCacheHome(repository)
    let (options, swiftPM) = try Self.baseResearchLaneOptions(
      repository: repository, pin: "6ee3210", cacheHome: cacheHome, key: "codebase")

    let outcome = await ContextPackRun.run(
      role: "research-lane", options: options, root: repository.root, swiftPM: swiftPM)
    guard case .written(let written) = outcome else {
      Issue.record("expected .written, got \(outcome)")
      return
    }
    #expect(written.notes.contains { $0.contains("6ee3210 is a commit") })
  }

  @Test(
    "a research-lane --key must name a lane, and the lane's pin must be its kind — exit 2 — catches a pack no lane reads, or a lane pinned to another lane's evidence",
    arguments: [
      ("web", "swift-composable-architecture@1.26.2"),
      ("codebase", "swift-composable-architecture@1.26.2"),
      ("packages", "6ee3210"),
      ("apple-docs", "swift-composable-architecture@1.26.2"),
      ("prior-decisions", "iphonesimulator26.2"),
    ])
  func researchLaneKeyAndPinMustMatchALane(key: String, pin: String) async throws {
    let repository = try Repository()
    defer { repository.remove() }
    let cacheHome = try Self.freshCacheHome(repository)
    let (options, swiftPM) = try Self.baseResearchLaneOptions(
      repository: repository, pin: pin, cacheHome: cacheHome, key: key)

    let outcome = await ContextPackRun.run(
      role: "research-lane", options: options, root: repository.root, swiftPM: swiftPM)
    guard case .invalid(let message) = outcome else {
      Issue.record("expected .invalid, got \(outcome)")
      return
    }
    #expect(message.contains(key) || message.contains(pin))
    #expect(!repository.packExists(".harness/context-pack/research-lane-\(key).md"))
  }

  @Test(
    "a research-lane pack needs --key, --design and a recognised --pin — exit 2 naming what's wrong"
  )
  func researchLaneRequiresKeyDesignAndKnownPin() async throws {
    let repository = try Repository()
    defer { repository.remove() }
    let cacheHome = try Self.freshCacheHome(repository)
    let (base, swiftPM) = try Self.baseResearchLaneOptions(
      repository: repository, pin: "iphonesimulator26.2", cacheHome: cacheHome, key: "apple-docs")
    var noKey = base
    noKey.key = nil
    var noDesign = base
    noDesign.design = nil
    var badPin = base
    badPin.pin = "26.2"
    for (options, expected) in [(noKey, "--key"), (noDesign, "--design"), (badPin, "`26.2`")] {
      let outcome = await ContextPackRun.run(
        role: "research-lane", options: options, root: repository.root, swiftPM: swiftPM)
      guard case .invalid(let message) = outcome else {
        Issue.record("expected .invalid for \(expected), got \(outcome)")
        continue
      }
      #expect(message.contains(expected))
    }
  }

  @Test(
    "a --key that is not one safe path component exits 2 and writes nothing, for every role — catches a pack overwriting a file outside the pack directory",
    arguments: ["/../x", "../../docs/checkout/designs/offline-order-queue", ".hidden", "a/b"])
  func unsafeKeyIsInvalid(key: String) async throws {
    let repository = try Repository()
    defer { repository.remove() }
    let designPath = try repository.write(
      designFixtureText, at: "docs/checkout/designs/offline-order-queue.md")
    let questionsPath = try repository.write("1. Is this the best design?", at: "questions.md")
    var options = ContextPackGatherInputs()
    options.design = designPath
    options.questionSet = questionsPath
    options.docAnchor = ["decision"]
    options.key = key

    let outcome = await ContextPackRun.run(
      role: "challenger", options: options, root: repository.root, swiftPM: Self.unusedSwiftPM)
    guard case .invalid(let message) = outcome else {
      Issue.record("expected .invalid, got \(outcome)")
      return
    }
    #expect(message.contains("--key"))
    #expect(!repository.packExists(".harness/x.md"))
    #expect(try repository.packText(designPath) == designFixtureText)
    let packDirectory = repository.root.appending(path: ".harness/context-pack")
    #expect(!FileManager.default.fileExists(atPath: packDirectory.path))
  }

  // MARK: - Claim checker: cited ranges only

  @Test("claim-checker pack holds only its claims' cited ranges, never the whole cited file")
  func claimCheckerPackHasExpectedSections() async throws {
    let repository = try Repository()
    defer { repository.remove() }
    let designPath = try repository.write(
      designFixtureText, at: "docs/checkout/designs/offline-order-queue.md")
    let citedFile = """
      line 1 — never cited
      line 2 — never cited
      line 3 — cited start
      line 4 — cited middle
      line 5 — cited end
      line 6 — never cited
      """
    let citedPath = try repository.write(citedFile, at: "Sources/Example.swift")
    let claimLine = try Self.claimLine(id: "ev-example", loc: "\(citedPath):L3-L5", pin: "abc123")
    let claimsPath = try repository.write(claimLine + "\n", at: "claims.jsonl")

    var options = ContextPackGatherInputs()
    options.design = designPath
    options.claims = claimsPath
    options.claimID = ["ev-example"]

    let outcome = await ContextPackRun.run(
      role: "claim-checker", options: options, root: repository.root, swiftPM: Self.unusedSwiftPM)
    guard case .written(let written) = outcome else {
      Issue.record("expected .written, got \(outcome)")
      return
    }
    let text = try repository.packText(written.relativePath)
    #expect(text.contains("cited start"))
    #expect(text.contains("cited middle"))
    #expect(text.contains("cited end"))
    #expect(!text.contains("never cited"))
  }

  @Test(
    "claim-checker packs split by --key land in separate files, each with only its own claims — catches one lane's pack overwriting another's"
  )
  func claimCheckerPackDiffersPerKey() async throws {
    let repository = try Repository()
    defer { repository.remove() }
    let designPath = try repository.write(
      designFixtureText, at: "docs/checkout/designs/offline-order-queue.md")
    let citedPath = try repository.write("alpha line\nbeta line\n", at: "Sources/Example.swift")
    let alpha = try Self.claimLine(id: "ev-alpha", loc: "\(citedPath):L1-L1", pin: "abc1234")
    let beta = try Self.claimLine(id: "ev-beta", loc: "\(citedPath):L2-L2", pin: "abc1234")
    let claimsPath = try repository.write("\(alpha)\n\(beta)\n", at: "claims.jsonl")

    var paths: [String] = []
    for (key, id) in [("codebase", "ev-alpha"), ("packages", "ev-beta")] {
      var options = ContextPackGatherInputs()
      options.design = designPath
      options.claims = claimsPath
      options.claimID = [id]
      options.key = key
      let outcome = await ContextPackRun.run(
        role: "claim-checker", options: options, root: repository.root,
        swiftPM: Self.unusedSwiftPM)
      guard case .written(let written) = outcome else {
        Issue.record("expected .written, got \(outcome)")
        return
      }
      paths.append(written.relativePath)
    }
    #expect(
      paths == [
        ".harness/context-pack/claim-checker-codebase.md",
        ".harness/context-pack/claim-checker-packages.md",
      ])
    let codebase = try repository.packText(paths[0])
    let packages = try repository.packText(paths[1])
    #expect(codebase.contains("ev-alpha") && !codebase.contains("ev-beta"))
    #expect(packages.contains("ev-beta") && !packages.contains("ev-alpha"))
  }

  @Test(
    "an evidence-auditor pack keyed for the pre-mortem is its own file holding the doc and the claims it cites — catches the pre-mortem reading a pack with no claims"
  )
  func preMortemPackCarriesCitedClaims() async throws {
    let repository = try Repository()
    defer { repository.remove() }
    let citedPath = try repository.write(
      "public func cancellable() -> Self {\n  fatalError()\n}\n", at: "Sources/Cancel.swift")
    let claim = Claim(
      id: "ev-tca-effect-run-supports-cancellation", lane: "packages", text: "some claim text",
      citation: Citation(kind: .file, loc: "\(citedPath):L1-L1", pin: "abc1234"),
      status: .supported)
    var options = try auditorOptions(repository: repository, claim: claim)
    options.key = "pre-mortem"

    let outcome = await ContextPackRun.run(
      role: "evidence-auditor", options: options, root: repository.root,
      swiftPM: Self.unusedSwiftPM)
    guard case .written(let written) = outcome else {
      Issue.record("expected .written, got \(outcome)")
      return
    }
    #expect(written.relativePath == ".harness/context-pack/evidence-auditor-pre-mortem.md")
    let text = try repository.packText(written.relativePath)
    #expect(text.contains("Client-side queue [ev-tca-effect-run-supports-cancellation]"))
    #expect(text.contains("public func cancellable"))
  }

  // MARK: - Drafter: only supported claims, plus an absent optional probe-verdicts note

  @Test(
    "drafter pack holds its template, frame answers, only supported claims, its standards anchors, and notes an absent --probe-verdicts"
  )
  func drafterPackHasExpectedSections() async throws {
    let repository = try Repository()
    defer { repository.remove() }
    let templatePath = try repository.write("## Problem\n\n## Requirements\n", at: "template.md")
    let frameAnswersPath = try repository.write("Q: …\nA: …", at: "frame-answers.md")
    let standardsPath = try repository.write(
      "## 2. Architecture\n\nDrafter standards guidance.\n", at: "docs/standards.md")
    let supported = try Self.claimLine(
      id: "ev-supported", loc: "Sources/A.swift:L1-L1", pin: "p", status: .supported)
    let notYetChecked = try Self.claimLine(
      id: "ev-new", loc: "Sources/B.swift:L1-L1", pin: "p", status: .new)
    let claimsPath = try repository.write("\(supported)\n\(notYetChecked)\n", at: "claims.jsonl")

    var options = ContextPackGatherInputs()
    options.template = templatePath
    options.frameAnswers = frameAnswersPath
    options.standards = standardsPath
    options.claims = claimsPath
    options.moduleKind = ["feature"]

    let outcome = await ContextPackRun.run(
      role: "drafter", options: options, root: repository.root, swiftPM: Self.unusedSwiftPM)
    guard case .written(let written) = outcome else {
      Issue.record("expected .written, got \(outcome)")
      return
    }
    #expect(written.notes.contains { $0.contains("--probe-verdicts not given") })
    let text = try repository.packText(written.relativePath)
    #expect(text.contains("## Problem"))
    #expect(text.contains(supported))
    #expect(!text.contains(notYetChecked))
    #expect(text.contains("Drafter standards guidance."))
  }

  @Test(
    "drafter pack at --tier sketch carries the quote-ok answer claims and the repo's word budgets from .swiftgate.toml — catches the sketch drafter missing the user's answers and the budget it will be linted against"
  )
  func sketchDrafterPackCarriesAnswersAndBudgets() async throws {
    let repository = try Repository()
    defer { repository.remove() }
    _ = try repository.write(
      """
      schema = 1
      xcode = "26.2"
      app_scheme = "App"
      packages = ["Packages/*"]

      [simulator]
      device = "iPhone 17"
      os = "26.2"

      [docs.budgets]
      design = 950
      """, at: ".swiftgate.toml")
    let templatePath = try repository.write("## Problem\n", at: "template.md")
    let frameAnswersPath = try repository.write("Q: …\nA: …", at: "frame-answers.md")
    let standardsPath = try repository.write(
      "## 2. Architecture\n\nDrafter standards guidance.\n", at: "docs/standards.md")
    let answer = try Self.claimLine(
      id: "ev-user-picks-both", kind: .answer, loc: "answers.jsonl#design-run/1", pin: nil,
      quote: "Which area?", status: .quoteOk)
    let claimsPath = try repository.write("\(answer)\n", at: "claims.jsonl")

    var options = ContextPackGatherInputs()
    options.template = templatePath
    options.frameAnswers = frameAnswersPath
    options.standards = standardsPath
    options.claims = claimsPath
    options.moduleKind = ["feature"]
    options.tier = "sketch"

    let outcome = await ContextPackRun.run(
      role: "drafter", options: options, root: repository.root, swiftPM: Self.unusedSwiftPM)
    guard case .written(let written) = outcome else {
      Issue.record("expected .written, got \(outcome)")
      return
    }
    let text = try repository.packText(written.relativePath)
    #expect(text.contains(answer))
    #expect(text.contains("950 prose words"))
    #expect(text.contains("architecture: 80"))
  }

  @Test("an unknown --tier fails the drafter pack by name — catches a typo reading as not-sketch")
  func unknownTierFailsDrafterPack() async throws {
    let repository = try Repository()
    defer { repository.remove() }
    var options = ContextPackGatherInputs()
    options.template = try repository.write("## Problem\n", at: "template.md")
    options.frameAnswers = try repository.write("Q: …", at: "frame-answers.md")
    options.standards = try repository.write("## 2. Architecture\n\nx\n", at: "docs/standards.md")
    options.moduleKind = ["feature"]
    options.tier = "skecth"

    let outcome = await ContextPackRun.run(
      role: "drafter", options: options, root: repository.root, swiftPM: Self.unusedSwiftPM)
    guard case .invalid(let message) = outcome else {
      Issue.record("expected .invalid, got \(outcome)")
      return
    }
    #expect(message.contains("skecth"))
  }

  // MARK: - Evidence auditor: only the given doc sections and their cited claims

  @Test("evidence-auditor pack holds only its given doc sections and their cited claim excerpts")
  func evidenceAuditorPackHasExpectedSections() async throws {
    let repository = try Repository()
    defer { repository.remove() }
    let designPath = try repository.write(
      designFixtureText, at: "docs/checkout/designs/offline-order-queue.md")
    let citedPath = try repository.write(
      "public func cancellable() -> Self {\n  fatalError()\n}\n", at: "Sources/Cancel.swift")
    let claimLine = try Self.claimLine(
      id: "ev-tca-effect-run-supports-cancellation", loc: "\(citedPath):L1-L1", pin: "p",
      quote: nil)
    let claimsPath = try repository.write(claimLine + "\n", at: "claims.jsonl")

    var options = ContextPackGatherInputs()
    options.design = designPath
    options.docAnchor = ["decision"]
    options.claims = claimsPath
    options.claimID = ["ev-tca-effect-run-supports-cancellation"]

    let outcome = await ContextPackRun.run(
      role: "evidence-auditor", options: options, root: repository.root,
      swiftPM: Self.unusedSwiftPM)
    guard case .written(let written) = outcome else {
      Issue.record("expected .written, got \(outcome)")
      return
    }
    let text = try repository.packText(written.relativePath)
    #expect(text.contains("Client-side queue [ev-tca-effect-run-supports-cancellation]"))
    #expect(text.contains("public func cancellable"))
    #expect(!text.contains("Guests on flaky Wi-Fi"))
  }

  private func auditorOptions(
    repository: Repository, claim: Claim
  ) throws -> ContextPackGatherInputs {
    let designPath = try repository.write(
      designFixtureText, at: "docs/checkout/designs/offline-order-queue.md")
    let line = String(decoding: try JSONEncoder().encode(claim), as: UTF8.self)
    var options = ContextPackGatherInputs()
    options.design = designPath
    options.docAnchor = ["decision"]
    options.claims = try repository.write(line + "\n", at: "claims.jsonl")
    options.claimID = [claim.id]
    return options
  }

  @Test(
    "an evidence-auditor pack carries a cited probe's whole snippet and its verdict — catches review stopping on a probe claim, which has no line range or quote"
  )
  func evidenceAuditorPackCarriesProbeSnippetAndVerdict() async throws {
    let repository = try Repository()
    defer { repository.remove() }
    let evidence = "docs/checkout/designs/offline-order-queue.evidence"
    let id = "ev-tca-effect-run-supports-cancellation"
    _ = try repository.write(
      "import ComposableArchitecture\nenum Probe_ev_tca_effect_run_supports_cancellation {\n"
        + "  static let effect = Effect<Int>.run { _ in }.cancellable(id: 1)\n}\n",
      at: "\(evidence)/probes/Probe_ev_tca_effect_run_supports_cancellation.swift")
    _ = try repository.write(
      "{\n  \"claimId\" : \"\(id)\",\n  \"diagnostics\" : [],\n  \"pins\" : {},\n"
        + "  \"sdk\" : \"iphonesimulator26.2\",\n  \"verdict\" : \"pass\"\n}\n",
      at: "\(evidence)/probes/Probe_ev_tca_effect_run_supports_cancellation.verdict.json")
    let claim = Claim(
      id: id, lane: "packages", text: "Effect.run supports cancellation.",
      citation: Citation(
        kind: .probe, loc: "probes/Probe_ev_tca_effect_run_supports_cancellation.swift",
        pin: "swift-composable-architecture@1.26.2"), status: .supported)
    let options = try auditorOptions(repository: repository, claim: claim)

    let outcome = await ContextPackRun.run(
      role: "evidence-auditor", options: options, root: repository.root,
      swiftPM: Self.unusedSwiftPM)
    guard case .written(let written) = outcome else {
      Issue.record("expected .written, got \(outcome)")
      return
    }
    let text = try repository.packText(written.relativePath)
    #expect(text.contains("import ComposableArchitecture"))
    #expect(text.contains(".cancellable(id: 1)"))
    #expect(text.contains("\"verdict\" : \"pass\""))
  }

  @Test(
    "an evidence-auditor pack for a probe claim with no verdict file fails, naming the file — catches an auditor judging a probe that never ran"
  )
  func evidenceAuditorPackProbeWithoutVerdictFails() async throws {
    let repository = try Repository()
    defer { repository.remove() }
    let evidence = "docs/checkout/designs/offline-order-queue.evidence"
    _ = try repository.write(
      "enum Probe_ev_tca_effect_run_supports_cancellation {}\n",
      at: "\(evidence)/probes/Probe_ev_tca_effect_run_supports_cancellation.swift")
    let claim = Claim(
      id: "ev-tca-effect-run-supports-cancellation", lane: "packages", text: "some claim text",
      citation: Citation(
        kind: .probe, loc: "probes/Probe_ev_tca_effect_run_supports_cancellation.swift",
        pin: "swift-composable-architecture@1.26.2"), status: .supported)
    let options = try auditorOptions(repository: repository, claim: claim)

    let outcome = await ContextPackRun.run(
      role: "evidence-auditor", options: options, root: repository.root,
      swiftPM: Self.unusedSwiftPM)
    guard case .invalid(let message) = outcome else {
      Issue.record("expected .invalid, got \(outcome)")
      return
    }
    #expect(message.contains("Probe_ev_tca_effect_run_supports_cancellation.verdict.json"))
  }

  @Test(
    "an answer claim whose quote holds a double quote finds its line in answers.jsonl — catches a quote matched only against the JSON-escaped line"
  )
  func answerQuoteWithDoubleQuoteMatches() async throws {
    let repository = try Repository()
    defer { repository.remove() }
    let evidence = "docs/checkout/designs/offline-order-queue.evidence"
    let answer =
      #"{"runId":"design-20260926T125113Z","question":"What does \"history\" mean?","answer":"the list of \"count changes\""}"#
    _ = try repository.write(answer + "\n", at: "\(evidence)/answers.jsonl")
    let claim = Claim(
      id: "ev-tca-effect-run-supports-cancellation", lane: "prior-decisions",
      text: "History means the list of count changes.",
      citation: Citation(
        kind: .answer, loc: "answers.jsonl#design-20260926T125113Z/1", pin: nil,
        quote: #"the list of "count changes""#), status: .supported)
    let options = try auditorOptions(repository: repository, claim: claim)

    let outcome = await ContextPackRun.run(
      role: "evidence-auditor", options: options, root: repository.root,
      swiftPM: Self.unusedSwiftPM)
    guard case .written(let written) = outcome else {
      Issue.record("expected .written, got \(outcome)")
      return
    }
    #expect(try repository.packText(written.relativePath).contains(answer))
  }

  // MARK: - Standards reviewer: Module kinds, Decision, Test plan, plus given anchors

  @Test(
    "standards-reviewer pack holds Module kinds, Decision and Test plan, and the given standards anchor"
  )
  func standardsReviewerPackHasExpectedSections() async throws {
    let repository = try Repository()
    defer { repository.remove() }
    let designPath = try repository.write(
      designFixtureText, at: "docs/checkout/designs/offline-order-queue.md")
    let standardsPath = try repository.write(
      "## Feature kind\n\nFeature guidance text.\n", at: "docs/standards.md")

    var options = ContextPackGatherInputs()
    options.design = designPath
    options.standards = standardsPath
    options.standardsAnchor = ["feature-kind"]

    let outcome = await ContextPackRun.run(
      role: "standards-reviewer", options: options, root: repository.root,
      swiftPM: Self.unusedSwiftPM)
    guard case .written(let written) = outcome else {
      Issue.record("expected .written, got \(outcome)")
      return
    }
    let text = try repository.packText(written.relativePath)
    #expect(text.contains("OrderQueueFeature"))  // Module kinds
    // Decision
    #expect(text.contains("Client-side queue [ev-tca-effect-run-supports-cancellation]"))
    #expect(text.contains("test-queued-orders-replay-in-submit-order"))  // Test plan
    #expect(text.contains("Feature guidance text."))
    #expect(!text.contains("Guests on flaky Wi-Fi"))  // Problem never leaks in
  }

  // MARK: - Challenger: only the given doc sections, plus the question set

  @Test("challenger pack holds only its given doc sections, plus the question set")
  func challengerPackHasExpectedSections() async throws {
    let repository = try Repository()
    defer { repository.remove() }
    let designPath = try repository.write(
      designFixtureText, at: "docs/checkout/designs/offline-order-queue.md")
    let questionSetPath = try repository.write(
      "Does the decision follow from the evidence?", at: "questions.md")

    var options = ContextPackGatherInputs()
    options.design = designPath
    options.docAnchor = ["options"]
    options.questionSet = questionSetPath

    let outcome = await ContextPackRun.run(
      role: "challenger", options: options, root: repository.root, swiftPM: Self.unusedSwiftPM)
    guard case .written(let written) = outcome else {
      Issue.record("expected .written, got \(outcome)")
      return
    }
    let text = try repository.packText(written.relativePath)
    #expect(text.contains("Client-side queue with a TCA reducer"))
    #expect(text.contains("Does the decision follow from the evidence?"))
    #expect(!text.contains("Guests on flaky Wi-Fi"))
  }

  // MARK: - Decomposer: Requirements, Module kinds, Test plan, plus module graph and bounds

  @Test(
    "decomposer pack holds Requirements, Decision, Architecture, Module kinds, Test plan and Risks, plus the module graph and sizing bounds"
  )
  func decomposerPackHasExpectedSections() async throws {
    let repository = try Repository()
    defer { repository.remove() }
    let designPath = try repository.write(
      designFixtureText, at: "docs/checkout/designs/offline-order-queue.md")
    let moduleGraphPath = try repository.write(
      "OrderQueueFeature -> OrderQueueCore", at: "module-graph.txt")
    let boundsPath = try repository.write(
      "estLines 40-400; max 2 modules per task", at: "bounds.txt")

    var options = ContextPackGatherInputs()
    options.design = designPath
    options.moduleGraph = moduleGraphPath
    options.taskSizingBounds = boundsPath

    let outcome = await ContextPackRun.run(
      role: "decomposer", options: options, root: repository.root, swiftPM: Self.unusedSwiftPM)
    guard case .written(let written) = outcome else {
      Issue.record("expected .written, got \(outcome)")
      return
    }
    let text = try repository.packText(written.relativePath)
    #expect(text.contains("req-offline-queue-drains-on-reconnect"))
    #expect(text.contains("OrderQueueFeature -> OrderQueueCore"))
    #expect(text.contains("estLines 40-400"))
    #expect(text.contains("Client-side queue [ev-tca-effect-run-supports-cancellation]"))
  }
}
