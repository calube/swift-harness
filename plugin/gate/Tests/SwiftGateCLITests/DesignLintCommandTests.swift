import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

/// A temp repository root with one design doc (and, optionally, its `claims.jsonl`) for
/// `design-lint`'s own tests. Every test here uses ``FakeGit`` (never real git) and a
/// ``LiveProcessRunner`` whose `PATH` is under this suite's own control, so nothing touches this
/// checkout's shared git state and nothing depends on whether `mmdc` happens to be installed on
/// the machine running the test.
private struct DesignLintRepository {
  let root: URL

  /// A `PATH` that can never resolve `mmdc`, however the host machine is set up — the
  /// deterministic way to exercise the "not on PATH" branch spec §5.3 requires.
  static let mmdcAbsentRunner = LiveProcessRunner(
    baseEnvironment: ["PATH": "/swiftgate-test-path-with-no-mmdc"])

  init() throws {
    root = TestTemporaryDirectory.root
      .appending(path: "swiftgate-design-lint-\(UUID().uuidString)", directoryHint: .isDirectory)
      .resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  func write(_ path: String, _ text: String) throws {
    let url = root.appending(path: path)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
  }

  func remove() { TestTemporaryDirectory.remove(root) }

  func report(
    docPath: String, git: any Git = FakeGit(), processRunner: any ProcessRunner = mmdcAbsentRunner
  ) async throws -> RunReport {
    try StaticCheckReport.make(
      runID: "r", durationMilliseconds: 1,
      outcome: await DesignLintCheck.run(
        root: root, docPath: docPath, git: git, processRunner: processRunner))
  }
}

@Suite("swiftgate design-lint")
struct DesignLintCommandTests {
  /// A complete, spec-compliant design doc: every §5.3 section, in order, every Evidence/Decision/
  /// Perf & scale bullet tagged, every `[UNVERIFIED]` bullet restated in Risks or Open questions,
  /// two known-type mermaid diagrams, and prose clean under every `ProseRules` check — the same
  /// baseline the sections/evidence/diagrams suites each already prove clean under their own
  /// family. Individual tests perturb one piece of it.
  static let wellFormed = """
    ---
    status: approved
    area: checkout
    tier: standard
    ---

    # Offline order queue

    ## Problem

    Guests on flaky Wi-Fi lose their cart when the app can't reach checkout. The client should queue
    the order on the device and submit it once the network returns, instead of showing a dead end.

    ## Requirements

    - req-offline-queue-drains-on-reconnect: The client resubmits queued orders once connectivity returns.
    - req-queue-survives-app-relaunch: A queued order is still present after the app is force-quit and reopened.

    ## Evidence

    - [ev-tca-effect-run-supports-cancellation] `.cancellable(id:)` lets a caller cancel an in-flight `Effect.run` effect by id.
    - [UNVERIFIED] The App Store review guidelines allow silent background submission of a queued order.

    ## Options

    ### Option 1: Client-side queue with a TCA reducer

    Trade-offs: no server changes, but the client owns retry and dedupe logic.

    ### Option 2: Server-side draft orders

    Trade-offs: the server owns retry, but every draft consumes an order row until it's confirmed.

    ## Decision

    - Client-side queue [ev-tca-effect-run-supports-cancellation]

    ## Architecture

    ```mermaid
    flowchart TD
      A[OrderQueueReducer] --> B[SubmitOrderEffect]
      B --> C[Checkout API]
    ```

    ```mermaid
    sequenceDiagram
      participant Client
      participant Queue
      participant API
      Client->>Queue: enqueue(order)
      Queue->>API: submit(order)
    ```

    ## Module kinds

    | Module | Kind | Reason |
    |---|---|---|
    | OrderQueueFeature | feature | owns the reducer and queue state |
    | OrderQueueCore | library | pure queue model, no I/O |

    ## Test plan by tier

    - test-queued-orders-replay-in-submit-order: a queued order resubmits after reconnect \u{2014} tier T1
    - test-queue-persists-across-relaunch: a queued order survives a simulated relaunch \u{2014} tier T2

    ## Observability

    The client logs every enqueue, submit attempt and drop, with the queue depth at that point.

    - Structured log on enqueue, submit success, submit failure and drop.

    ## Perf & scale

    - throughput: up to 5 queued orders per device at once [UNVERIFIED]
    - tail latency: submit retries back off up to 30s [UNVERIFIED]
    - fan-out: 1 submit effect per queued order, run in sequence [UNVERIFIED]
    - failure isolation: a failed submit doesn't block the rest of the queue [UNVERIFIED]
    - resources: queue persists to on-device storage, bounded to 5 entries [UNVERIFIED]
    - backpressure: a full queue rejects new orders with a clear error [UNVERIFIED]
    - 10\u{d7}: 50 queued orders still drain within a single retry window [UNVERIFIED]

    ## Risks

    - The App Store review guidelines allow silent background submission of a queued order; see Open questions.
    - Tail latency: submit retries back off up to 30s under sustained load; needs a longer soak test before launch.

    ## Open questions

    - Throughput: up to 5 queued orders per device at once; to confirm in the first build's T2 run.
    - Fan-out: 1 submit effect per queued order, run in sequence; to confirm in the first build's T2 run.
    - Failure isolation: a failed submit doesn't block the rest of the queue; to confirm in the first build's T2 run.
    - Resources: queue persists to on-device storage, bounded to 5 entries; to confirm in the first build's T2 run.
    - Backpressure: a full queue rejects new orders with a clear error; to confirm in the first build's T2 run.
    - Does silent background submission need explicit guest consent?
    - 10\u{d7}: 50 queued orders still drain within a single retry window; confirm under real device thermal throttling.

    ## Changelog

    - 2026-09-25: drafted
    """

  static let wellFormedClaims = """
    {"citation":{"kind":"file","loc":".build/checkouts/swift-composable-architecture/Sources/ComposableArchitecture/Effects/Cancellation.swift:L4-L4","pin":"swift-composable-architecture@1.26.2","quote":"public func cancellable<ID: Hashable & Sendable>(id: ID, cancelInFlight: Bool = false) -> Self"},"id":"ev-tca-effect-run-supports-cancellation","lane":"packages","status":"supported","text":"Effect.run returns an effect that can be cancelled by id via .cancellable(id:)."}

    """

  // MARK: - The repo's own shared valid design, under every family together

  @Test(
    "the repo's shared valid design doc has no gating findings across every rule family plus prose in one run — catches the fixture regressing under any single family"
  )
  func sharedValidDesignHasNoGatingFindings() async throws {
    let fixturesRoot = URL(filePath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appending(path: "Fixtures/design", directoryHint: .isDirectory)
    let report = try await StaticCheckReport.make(
      runID: "r", durationMilliseconds: 1,
      outcome: DesignLintCheck.run(
        root: fixturesRoot, docPath: "valid.md", git: FakeGit(),
        processRunner: DesignLintRepository.mmdcAbsentRunner))
    #expect(report.verdict.exitCode == 0)
    #expect(report.findings.allSatisfy { !$0.severity.failsGate })
  }

  // MARK: - Sections/ids: untagged Decision bullet

  @Test(
    "an untagged Decision bullet exits 1, naming Decision in the finding — catches a decision reaching the doc with no citation"
  )
  func untaggedDecisionBulletExitsOne() async throws {
    let repo = try DesignLintRepository()
    defer { repo.remove() }
    let text = Self.wellFormed.replacingOccurrences(
      of: "- Client-side queue [ev-tca-effect-run-supports-cancellation]",
      with: "- Client-side queue")
    try repo.write("design.md", text)
    try repo.write("design.evidence/claims.jsonl", Self.wellFormedClaims)
    let report = try await repo.report(docPath: "design.md")
    #expect(report.verdict.exitCode == 1)
    let finding = report.findings.first { $0.ruleID == "design-lint.untagged-bullet" }
    #expect(finding != nil)
    #expect(finding?.message.contains("Decision") == true)
  }

  // MARK: - A parsed `.unknown` status

  @Test(
    "a frontmatter status outside proposed/approved/built/superseded-by is flagged and exits 1 — catches a typo'd or invented status reading as approved"
  )
  func unknownStatusExitsOne() async throws {
    let repo = try DesignLintRepository()
    defer { repo.remove() }
    let text = Self.wellFormed.replacingOccurrences(of: "status: approved", with: "status: draft")
    try repo.write("design.md", text)
    try repo.write("design.evidence/claims.jsonl", Self.wellFormedClaims)
    let report = try await repo.report(docPath: "design.md")
    #expect(report.verdict.exitCode == 1)
    let finding = report.findings.first { $0.ruleID == "design-lint.status-unknown" }
    #expect(finding?.message.contains("draft") == true)
  }

  // MARK: - A missing claims.jsonl despite tagged bullets

  @Test(
    "a missing claims.jsonl for a doc with tagged bullets is surfaced, not silently passed — catches evidence tags going unchecked because the file was never captured"
  )
  func missingClaimsFileIsSurfaced() async throws {
    let repo = try DesignLintRepository()
    defer { repo.remove() }
    try repo.write("design.md", Self.wellFormed)
    // No claims.jsonl written at all.
    let report = try await repo.report(docPath: "design.md")
    #expect(report.verdict.exitCode == 1)
    #expect(report.findings.contains { $0.ruleID == "design-lint.claims-file-missing" })
  }

  @Test(
    "claims.jsonl lines that don't parse are a non-gating finding naming the count, never a silent drop"
  )
  func unreadableClaimsLinesAreNonGatingFinding() async throws {
    let repo = try DesignLintRepository()
    defer { repo.remove() }
    try repo.write("design.md", Self.wellFormed)
    try repo.write("design.evidence/claims.jsonl", Self.wellFormedClaims + "not json\n")
    let report = try await repo.report(docPath: "design.md")
    let finding = report.findings.first { $0.ruleID == "design-lint.claims-file-unreadable-lines" }
    #expect(finding != nil)
    #expect(finding?.severity == .minor)
    #expect(finding?.message.contains("1") == true)
  }

  // MARK: - Prose runs in the same pass

  @Test(
    "a prose violation in the doc is reported in the same run as the design-lint families — catches prose never being wired into design-lint"
  )
  func proseViolationInTheSameRun() async throws {
    let repo = try DesignLintRepository()
    defer { repo.remove() }
    let text = Self.wellFormed.replacingOccurrences(
      of: "The client should queue", with: "The client should quickly queue")
    try repo.write("design.md", text)
    try repo.write("design.evidence/claims.jsonl", Self.wellFormedClaims)
    let report = try await repo.report(docPath: "design.md")
    #expect(report.verdict.exitCode == 1)
    #expect(report.findings.contains { $0.ruleID == "prose.adverb" })
  }

  // MARK: - mmdc

  @Test(
    "mmdc not on PATH is a non-gating note, exit 0, never blocked — catches a missing dev tool blocking the gate"
  )
  func mmdcAbsentIsNonGatingNote() async throws {
    let repo = try DesignLintRepository()
    defer { repo.remove() }
    try repo.write("design.md", Self.wellFormed)
    try repo.write("design.evidence/claims.jsonl", Self.wellFormedClaims)
    let report = try await repo.report(
      docPath: "design.md", processRunner: DesignLintRepository.mmdcAbsentRunner)
    #expect(report.verdict.exitCode == 0)
    #expect(report.tiers.map(\.verdict) == [.green])
    let finding = report.findings.first { $0.ruleID == "design-lint.mmdc-unavailable" }
    #expect(finding != nil)
    #expect(finding?.severity == .minor)
  }

  // MARK: - Unreadable input

  @Test(
    "a design doc that doesn't exist exits 2, blocked — never a red finding about a phantom file")
  func missingDocExitsTwoBlocked() async throws {
    let repo = try DesignLintRepository()
    defer { repo.remove() }
    let report = try await repo.report(docPath: "nowhere.md")
    #expect(report.verdict.exitCode == 2)
    #expect(report.tiers.map(\.verdict) == [.blocked])
  }

  // MARK: - Ids unique repo-wide, through the built binary

  private static let gitEnvironment: [String: String] = [
    "PATH": "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin",
    "HOME": TestTemporaryDirectory.sharedHome.path,
    "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
    "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.com",
    "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.com",
  ]

  private static func runChecked(
    _ runner: LiveProcessRunner, _ executable: String, _ arguments: [String], in root: URL,
    overlay: [String: String?] = [:]
  ) async throws -> ProcessOutput {
    try await runner.run(
      ProcessInvocation(
        executable: executable, arguments: arguments, environmentOverlay: overlay,
        workingDirectory: root.path, timeout: .seconds(300)))
  }

  /// Runs the built `swiftgate design-lint <doc> --json` from `root`, as the shim would.
  private static func lintWithBinary(_ doc: String, in root: URL, runner: LiveProcessRunner)
    async throws -> RunReport
  {
    let binary = Fixture.gateDirectory.appending(path: ".build/debug/swiftgate").path
    let output = try await runChecked(
      runner, binary, ["design-lint", doc, "--json"], in: root,
      overlay: [
        "PATH": "/swiftgate-test-path-with-no-mmdc:/usr/bin:/bin",
        "LLVM_PROFILE_FILE": root.appending(path: "swiftgate-%p.profraw").path,
      ])
    return try RunReportJSON.decode(output.stdout.bytes)
  }

  @Test(
    "a req- id another committed design already defines turns the second doc red through the built command — catches the doc's own ids masking a repo-wide duplicate"
  )
  func crossDocDuplicateRequirementIsRedThroughTheCommand() async throws {
    let repo = try DesignLintRepository()
    defer { repo.remove() }
    let runner = LiveProcessRunner(baseEnvironment: Self.gitEnvironment)
    _ = try await Self.runChecked(runner, "git", ["init", "-q", "-b", "main"], in: repo.root)
    _ = try await Self.runChecked(
      runner, "git", ["config", "commit.gpgsign", "false"], in: repo.root)

    let first = "docs/checkout/designs/offline-queue.md"
    try repo.write(first, Self.wellFormed)
    try repo.write(
      "docs/checkout/designs/offline-queue.evidence/claims.jsonl", Self.wellFormedClaims)
    _ = try await Self.runChecked(runner, "git", ["add", "-A"], in: repo.root)
    _ = try await Self.runChecked(runner, "git", ["commit", "-q", "-m", "first"], in: repo.root)

    let alone = try await Self.lintWithBinary(first, in: repo.root, runner: runner)
    #expect(!alone.findings.contains { $0.ruleID == "design-lint.requirement-id-duplicate" })

    let second = "docs/ordering/designs/order-retry.md"
    let secondText = Self.wellFormed
      .replacingOccurrences(
        of: "req-queue-survives-app-relaunch", with: "req-retry-survives-app-relaunch"
      )
      .replacingOccurrences(of: "test-queued-orders", with: "test-retried-orders")
      .replacingOccurrences(of: "test-queue-persists", with: "test-retry-persists")
    try repo.write(second, secondText)
    try repo.write("docs/ordering/designs/order-retry.evidence/claims.jsonl", Self.wellFormedClaims)
    _ = try await Self.runChecked(runner, "git", ["add", "-A"], in: repo.root)
    _ = try await Self.runChecked(runner, "git", ["commit", "-q", "-m", "second"], in: repo.root)

    let report = try await Self.lintWithBinary(second, in: repo.root, runner: runner)
    let duplicates = report.findings.filter {
      $0.ruleID == "design-lint.requirement-id-duplicate"
    }
    #expect(report.verdict.exitCode == 1)
    #expect(duplicates.count == 1)
    #expect(duplicates.first?.message.contains("req-offline-queue-drains-on-reconnect") == true)
    #expect(duplicates.first?.message.contains(first) == true)
  }

  // MARK: - mmdc present (skipped where the tool isn't installed)

  private static func onPath(_ name: String) -> Bool {
    let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
    return path.split(separator: ":").contains {
      FileManager.default.isExecutableFile(atPath: "\($0)/\(name)")
    }
  }

  @Test(
    "a real mmdc validates every fence, flagging a malformed one and passing a well-formed one",
    .enabled(if: onPath("mmdc"), "needs mmdc on PATH"))
  func mmdcValidatesFencesWhenPresent() async throws {
    let outcome = await MermaidValidation.validate(
      fences: [
        (heading: "Architecture", index: 0, source: "flowchart TD\n  A --> B"),
        (heading: "Architecture", index: 1, source: "not a mermaid diagram at all"),
      ],
      runner: LiveProcessRunner())
    guard case .validated(let failures) = outcome else {
      Issue.record("expected mmdc to be found on PATH")
      return
    }
    #expect(failures.map(\.index) == [1])
  }
}
