import Foundation
import SwiftGateDomain
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
    id: String, loc: String, pin: String?, quote: String? = nil,
    status: Claim.Status = .supported
  ) throws -> String {
    let claim = Claim(
      id: id, lane: "packages", text: "some claim text",
      citation: Citation(kind: .file, loc: loc, pin: pin, quote: quote), status: status)
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
  }

  // MARK: - Bad `--role`

  @Test("an unknown --role names it and never falls through to a role's builder — exit 2")
  func unknownRoleIsInvalid() throws {
    let repository = try Repository()
    defer { repository.remove() }
    let outcome = ContextPackRun.run(
      role: "not-a-role", options: ContextPackGatherInputs(), root: repository.root)
    guard case .invalid(let message) = outcome else {
      Issue.record("expected .invalid, got \(outcome)")
      return
    }
    #expect(message.contains("not-a-role"))
  }

  // MARK: - Missing input, never a silent fallback

  @Test("an unreadable required input names its path — exit 2, never a silent fallback")
  func unreadableRequiredInputIsInvalid() throws {
    let repository = try Repository()
    defer { repository.remove() }
    var options = ContextPackGatherInputs()
    options.design = "docs/does-not-exist.md"
    options.ledger = "ledger.json"
    options.taskID = "whatever"
    let outcome = ContextPackRun.run(role: "worker", options: options, root: repository.root)
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
  func missingStandardsAnchorIsAViolation() throws {
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

    let outcome = ContextPackRun.run(
      role: "standards-reviewer", options: options, root: repository.root)
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
  func absentOptionalInputIsNoted() throws {
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

    let outcome = ContextPackRun.run(role: "worker", options: options, root: repository.root)
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
  func workerPackHasExpectedSections() throws {
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

    let outcome = ContextPackRun.run(role: "worker", options: options, root: repository.root)
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
    // The Decision section isn't covered by this task, so its content never leaks in.
    #expect(!text.contains("Client-side queue [ev-tca-effect-run-supports-cancellation]"))
  }

  // MARK: - Research lane: same-pin cache hits, plus its briefs

  @Test("research-lane pack holds its briefs and only same-pin claim cache hits")
  func researchLanePackHasExpectedSections() throws {
    let repository = try Repository()
    defer { repository.remove() }
    let matchingPin = "swift-composable-architecture@1.26.2"
    let hit = try Self.claimLine(id: "ev-hit", loc: "Sources/Hit.swift:L1-L1", pin: matchingPin)
    let miss = try Self.claimLine(
      id: "ev-miss", loc: "Sources/Miss.swift:L1-L1", pin: "some-other-package@2.0.0")
    let claimsPath = try repository.write("\(hit)\n\(miss)\n", at: "claims.jsonl")
    let briefPath = try repository.write(
      "Q: which module owns retry?\nA: OrderQueueCore.", at: "frame-answers.md")

    var options = ContextPackGatherInputs()
    options.brief = [briefPath]
    options.pin = matchingPin
    options.claims = claimsPath

    let outcome = ContextPackRun.run(role: "research-lane", options: options, root: repository.root)
    guard case .written(let written) = outcome else {
      Issue.record("expected .written, got \(outcome)")
      return
    }
    let text = try repository.packText(written.relativePath)
    #expect(text.contains("which module owns retry"))
    #expect(text.contains(hit))
    #expect(!text.contains(miss))
  }

  // MARK: - Claim checker: cited ranges only

  @Test("claim-checker pack holds only its claims' cited ranges, never the whole cited file")
  func claimCheckerPackHasExpectedSections() throws {
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

    let outcome = ContextPackRun.run(role: "claim-checker", options: options, root: repository.root)
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

  // MARK: - Drafter: only supported claims, plus an absent optional probe-verdicts note

  @Test(
    "drafter pack holds its template, frame answers, only supported claims, its standards anchors, and notes an absent --probe-verdicts"
  )
  func drafterPackHasExpectedSections() throws {
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

    let outcome = ContextPackRun.run(role: "drafter", options: options, root: repository.root)
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

  // MARK: - Evidence auditor: only the given doc sections and their cited claims

  @Test("evidence-auditor pack holds only its given doc sections and their cited claim excerpts")
  func evidenceAuditorPackHasExpectedSections() throws {
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

    let outcome = ContextPackRun.run(
      role: "evidence-auditor", options: options, root: repository.root)
    guard case .written(let written) = outcome else {
      Issue.record("expected .written, got \(outcome)")
      return
    }
    let text = try repository.packText(written.relativePath)
    #expect(text.contains("Client-side queue [ev-tca-effect-run-supports-cancellation]"))
    #expect(text.contains("public func cancellable"))
    #expect(!text.contains("Guests on flaky Wi-Fi"))
  }

  // MARK: - Standards reviewer: Module kinds, Decision, Test plan, plus given anchors

  @Test(
    "standards-reviewer pack holds Module kinds, Decision and Test plan, and the given standards anchor"
  )
  func standardsReviewerPackHasExpectedSections() throws {
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

    let outcome = ContextPackRun.run(
      role: "standards-reviewer", options: options, root: repository.root)
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
  func challengerPackHasExpectedSections() throws {
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

    let outcome = ContextPackRun.run(role: "challenger", options: options, root: repository.root)
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
    "decomposer pack holds Requirements, Module kinds and Test plan, plus the module graph and sizing bounds"
  )
  func decomposerPackHasExpectedSections() throws {
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

    let outcome = ContextPackRun.run(role: "decomposer", options: options, root: repository.root)
    guard case .written(let written) = outcome else {
      Issue.record("expected .written, got \(outcome)")
      return
    }
    let text = try repository.packText(written.relativePath)
    #expect(text.contains("req-offline-queue-drains-on-reconnect"))
    #expect(text.contains("OrderQueueFeature -> OrderQueueCore"))
    #expect(text.contains("estLines 40-400"))
    #expect(!text.contains("Client-side queue [ev-tca-effect-run-supports-cancellation]"))
  }
}
