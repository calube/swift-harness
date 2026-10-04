import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

/// Every test copies this checkout's build agents and `calibrate-build` seeds into a temp root and
/// plays the agent with a fake `claude`: it lays the seed's known correct diff (`solution/`) over
/// the sandbox, commits, records a green gate run and returns a `TaskReturn` inside the real
/// `claude -p` result envelope captured for the judge. Git and `swift test` are real, so the judge
/// checks a real repository.
@Suite("swiftgate calibrate build")
struct CalibrateBuildTests {
  static let passedAt = Date(timeIntervalSince1970: 1_790_000_000)
  static let seeds = CalibrationSuite.build.seedsDirectory
  static let workerCase = "\(seeds)/build-worker/formal-greeting"
  static let fixerCase = "\(seeds)/build-fixer/formal-greeting-meets-farewell"

  struct Repository {
    let root: URL

    /// The build agents and seeds as this checkout has them, without its pass record.
    init(agents: [String] = ["build-worker", "build-fixer"]) throws {
      root = TestTemporaryDirectory.root
        .appending(
          path: "swiftgate-calibrate-build-\(UUID().uuidString)", directoryHint: .isDirectory
        )
        .resolvingSymlinksInPath()
      let fileManager = FileManager.default
      try fileManager.createDirectory(
        at: root.appending(path: CalibrationSuite.agentsDirectory),
        withIntermediateDirectories: true)
      try fileManager.createDirectory(
        at: root.appending(path: seeds), withIntermediateDirectories: true)
      let checkout = Fixture.harnessCheckout
      for agent in agents {
        let agentFile = "\(CalibrationSuite.agentsDirectory)/\(agent).md"
        try fileManager.copyItem(
          at: checkout.appending(path: agentFile), to: root.appending(path: agentFile))
        try fileManager.copyItem(
          at: checkout.appending(path: "\(seeds)/\(agent)"),
          to: root.appending(path: "\(seeds)/\(agent)"))
      }
    }

    func write(_ path: String, _ text: String) throws {
      let url = root.appending(path: path)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(text.utf8).write(to: url)
    }

    func data(_ path: String) -> Data? { try? Data(contentsOf: root.appending(path: path)) }

    func remove() { TestTemporaryDirectory.remove(root) }
  }

  // MARK: - The fake agent

  struct GitFailed: Error, CustomStringConvertible {
    let description: String
  }

  @discardableResult
  static func git(_ arguments: [String], in directory: String) async throws -> String {
    var environment = ProcessInfo.processInfo.environment
    for key in ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR"] {
      environment[key] = nil
    }
    let output = try await LiveProcessRunner(baseEnvironment: environment).run(
      ProcessInvocation(
        executable: "/usr/bin/git",
        arguments: [
          "-C", directory, "-c", "user.name=fake agent", "-c", "user.email=agent@example.invalid",
        ] + arguments,
        timeout: .seconds(60)))
    let text = output.stdout.text + output.stderr.text
    guard output.status.isSuccess else {
      throw GitFailed(description: "git \(arguments.joined(separator: " ")): \(text)")
    }
    return output.stdout.text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// What the fake agent does beyond the known correct diff.
  enum Misstep: Sendable, Equatable {
    case none
    /// Commits the diff to `main` too, as a fixer that merged its own branch would.
    case commitToMain
    /// Cites a gate that ran neither prove nor mutate, as a worker on the old contract would.
    case gateWithoutProof
    /// Cites a gate that skipped the task gate's impact, coverage and app-build steps.
    case gateWithoutTaskGateSteps
  }

  /// The real envelope from `Judge/claude-result.json` with `result` replaced.
  static func envelope(result: String) -> String {
    guard
      let data = try? Fixture.data("Judge/claude-result.json"),
      var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return "" }
    object["result"] = result
    object["structured_output"] = nil
    let encoded = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    return String(decoding: encoded, as: UTF8.self)
  }

  /// Plays whichever build agent the system prompt names, in the sandbox the invocation runs in.
  static func agent(_ repository: Repository, misstep: Misstep = .none) -> FakeProcessRunner {
    FakeProcessRunner(asyncHandler: { invocation async throws(ProcessRunnerError) in
      do {
        return try await play(invocation, repository: repository, misstep: misstep)
      } catch {
        return ProcessOutput(status: .exited(1), stdout: "", stderr: "fake agent: \(error)")
      }
    })
  }

  static func play(_ invocation: ProcessInvocation, repository: Repository, misstep: Misstep)
    async throws -> ProcessOutput
  {
    let arguments = invocation.arguments
    let systemPrompt =
      arguments.firstIndex(of: "--system-prompt").map { arguments[$0 + 1] } ?? ""
    let fixer = systemPrompt.contains("You repair 1 merge")
    let caseDirectory = repository.root.appending(path: fixer ? fixerCase : workerCase)
    guard let worktree = invocation.workingDirectory else {
      throw GitFailed(description: "the agent ran without a working directory")
    }
    let solution = caseDirectory.appending(path: "solution")
    let fileManager = FileManager.default
    for relative in fileManager.subpaths(atPath: solution.path) ?? [] {
      var isDirectory: ObjCBool = false
      let from = solution.appending(path: relative)
      guard fileManager.fileExists(atPath: from.path, isDirectory: &isDirectory),
        !isDirectory.boolValue
      else { continue }
      let to = URL(filePath: worktree).appending(path: relative)
      try? fileManager.removeItem(at: to)
      try fileManager.copyItem(at: from, to: to)
    }
    try await git(["add", "-A"], in: worktree)
    try await git(["commit", "-q", "--no-edit", "-m", "Keep both greetings"], in: worktree)
    let head = try await git(["rev-parse", "HEAD"], in: worktree)
    let branch = try await git(["symbolic-ref", "--short", "HEAD"], in: worktree)
    if case .commitToMain = misstep {
      try await git(["update-ref", "refs/heads/main", head], in: worktree)
    }

    let runID = "20260927T100000Z-0a1b2c3d"
    let report = try RunReport(
      runID: runID, durationMilliseconds: 10,
      tiers: [try TierResult(tier: .t0, verdict: .green, durationMilliseconds: 5, testCounts: nil)],
      findings: [])
    try RunStore(worktreeRoot: URL(filePath: worktree)).record(
      report, finishedAt: passedAt, command: "check fast",
      steps: fixer || misstep == .gateWithoutProof
        ? nil
        : misstep == .gateWithoutTaskGateSteps
          ? ["prove", "mutate"] : ["prove", "mutate", "impact", "coverage", "app-build"],
      headCommit: head, dirty: false)

    let task = String(branch.split(separator: "/").last ?? "")
    let taskReturn = TaskReturn(
      task: fixer ? String(task.dropFirst("fix-".count)) : task, outcome: .readyToMerge,
      commits: [String(head.prefix(10))],
      gate: .init(tier: .fast, verdict: .green, runID: runID), review: nil,
      testsAdded: fixer ? [] : ["test-formal-greeting", "test-informal-greeting"],
      notes: "fake agent", designConflict: nil)
    let json = String(decoding: try TaskReturnJSON.encode(taskReturn), as: UTF8.self)
    return ProcessOutput(
      status: .exited(0), stdout: envelope(result: "```json\n\(json)\n```"))
  }

  static func run(_ repository: Repository, agent: FakeProcessRunner) async
    -> StaticCheckOutcome
  {
    let calibration = BuildCalibrationRunner(
      agent: agent, tools: LiveProcessRunner(), root: repository.root,
      sandboxRoot: repository.root.appending(path: "sandboxes", directoryHint: .isDirectory),
      pluginBin: repository.root.appending(path: "plugin/bin").path, defaultModel: "sonnet")
    return await CalibrateBuildRun.run(
      root: repository.root, calibration: calibration, now: passedAt)
  }

  static func exitCode(_ outcome: StaticCheckOutcome) throws -> Int32 {
    try StaticCheckReport.make(runID: "test", durationMilliseconds: 0, outcome: outcome)
      .verdict.exitCode
  }

  static func findings(_ outcome: StaticCheckOutcome) -> [Finding] {
    guard case .checked(let result) = outcome else { return [] }
    return result.findings
  }

  static func missed(_ outcome: StaticCheckOutcome, question: String) -> Finding? {
    findings(outcome).first {
      $0.ruleID == "calibrate-build.label-missed" && $0.message.contains("`\(question)`")
    }
  }

  // MARK: - Runs

  @Test(
    "the seeds' known correct diffs meet their labels and the pass is keyed by both agents' content hash — catches a seed whose label its own solution can't meet"
  )
  func knownCorrectDiffsPass() async throws {
    let repository = try Repository()
    defer { repository.remove() }

    let outcome = await Self.run(repository, agent: Self.agent(repository))

    let blocked: String? =
      if case .blocked(let reason) = outcome { reason } else { nil }
    #expect(blocked == nil)
    #expect(
      Self.findings(outcome).filter { $0.severity.failsGate }.map(\.message) == [])
    #expect(try Self.exitCode(outcome) == 0)
    let record = try CalibrationRecord.decode(
      try #require(repository.data(CalibrationSuite.build.recordPath)))
    let hashed = try CalibrationHash.discover(root: repository.root, suite: .build)
    #expect(
      record.hashedFiles == ["plugin/agents/build-fixer.md", "plugin/agents/build-worker.md"])
    #expect(record.contentHash == CalibrationHash.hash(hashed))
    let recorded = try #require(repository.data(CalibrationSuite.build.recordPath))
    let json = try #require(try JSONSerialization.jsonObject(with: recorded) as? [String: Any])
    #expect(json["modelOverride"] == nil)
    #expect(
      (json["cases"] as? [[String: Any]])?.compactMap { $0["model"] as? String } == [
        "opus", "sonnet",
      ])
    #expect(
      record.cases.map { "\($0.agent)/\($0.caseName)" } == [
        "build-fixer/formal-greeting-meets-farewell", "build-worker/formal-greeting",
      ])
    #expect(
      record.cases.first?.answers.map(\.question) == [
        "outcome", "return", "scope", "refs", "resolution", "tests",
      ])
  }

  @Test(
    "a worker seed whose label is wrong fails calibration and keeps the record — catches a judge that passes whatever the agent returns"
  )
  func wrongLabelFails() async throws {
    let repository = try Repository(agents: ["build-worker"])
    defer { repository.remove() }
    // The known correct diff touches the test file, and the acceptance tests hold no such test.
    try repository.write(
      "\(Self.workerCase)/label.json",
      """
      {
        "schemaVersion": 1,
        "outcome": "ready-to-merge",
        "gate": "fast",
        "writeSet": ["Sources/Greeter/Greeter.swift"],
        "tests": [
          "GreeterTests.CalibrationAcceptance/formalGreeting()",
          "GreeterTests.CalibrationAcceptance/shoutsTheName()"
        ]
      }
      """)

    let outcome = await Self.run(repository, agent: Self.agent(repository))

    #expect(try Self.exitCode(outcome) == 1)
    #expect(
      Self.missed(outcome, question: "scope")?.message.contains(
        "outside: Tests/GreeterTests/GreeterTests.swift") == true)
    #expect(
      Self.missed(outcome, question: "tests")?.message.contains(
        "not run: GreeterTests.CalibrationAcceptance/shoutsTheName()") == true)
    #expect(Self.missed(outcome, question: "outcome") == nil)
    #expect(Self.missed(outcome, question: "return") == nil)
    #expect(repository.data(CalibrationSuite.build.recordPath) == nil)
    #expect(
      Self.findings(outcome).contains {
        $0.ruleID == "calibrate-build.usage" && $0.message.contains("is kept at")
      })
  }

  @Test(
    "a worker whose gate ran neither prove nor mutate misses the return label — catches calibration passing a worker check-return would refuse"
  )
  func workerWithoutProofFails() async throws {
    let repository = try Repository(agents: ["build-worker"])
    defer { repository.remove() }

    let outcome = await Self.run(
      repository, agent: Self.agent(repository, misstep: .gateWithoutProof))

    #expect(try Self.exitCode(outcome) == 1)
    #expect(
      Self.missed(outcome, question: "return")?.message.contains("gate-missing-proof") == true)
  }

  @Test(
    "a worker whose gate skipped the task gate's impact, coverage and app-build steps misses the return label — catches calibration passing a worker check-return would refuse"
  )
  func workerWithoutTaskGateStepsFails() async throws {
    let repository = try Repository(agents: ["build-worker"])
    defer { repository.remove() }

    let outcome = await Self.run(
      repository, agent: Self.agent(repository, misstep: .gateWithoutTaskGateSteps))

    #expect(try Self.exitCode(outcome) == 1)
    let message = Self.missed(outcome, question: "return")?.message ?? ""
    #expect(message.contains("gate-missing-step"))
    #expect(!message.contains("gate-missing-proof"))
  }

  @Test(
    "a fixer that also moves main misses the refs label — catches a fix committed outside its fix branch passing"
  )
  func fixerCommittingToMainFails() async throws {
    let repository = try Repository(agents: ["build-fixer"])
    defer { repository.remove() }

    let outcome = await Self.run(repository, agent: Self.agent(repository, misstep: .commitToMain))

    #expect(try Self.exitCode(outcome) == 1)
    #expect(
      Self.missed(outcome, question: "refs")?.message.contains("moved refs/heads/main") == true)
    #expect(Self.missed(outcome, question: "resolution") == nil)
    #expect(repository.data(CalibrationSuite.build.recordPath) == nil)
  }

  @Test(
    "a label with an unknown key or a write-set path outside the repository is a seed defect — catches a typo'd label silently checking nothing",
    arguments: [
      #""writeSet": ["../escape.swift"]"#,
      #""writeSet": ["Sources/Greeter/Greeter.swift"], "writeset": []"#,
    ])
  func invalidLabelIsASeedDefect(writeSet: String) async throws {
    let repository = try Repository(agents: ["build-worker"])
    defer { repository.remove() }
    try repository.write(
      "\(Self.workerCase)/label.json",
      """
      {
        "schemaVersion": 1, "outcome": "ready-to-merge", "gate": "fast", \(writeSet),
        "tests": ["GreeterTests.CalibrationAcceptance/formalGreeting()"]
      }
      """)
    let agent = Self.agent(repository)

    let outcome = await Self.run(repository, agent: agent)

    #expect(try Self.exitCode(outcome) == 1)
    #expect(Self.findings(outcome).map(\.ruleID) == ["calibrate-build.invalid-label"])
    #expect(agent.invocations.isEmpty)
  }

  // MARK: - Content hash

  @Test(
    "the build content hash covers exactly the worker and fixer prompts — catches an agent edit that leaves a stale pass looking fresh"
  )
  func hashIsKeyedByTheBuildAgents() throws {
    let repository = try Repository()
    defer { repository.remove() }
    try repository.write("plugin/agents/design-drafter.md", "draft\n")
    try repository.write("plugin/workflows/build-task.js", "export const steps = [];\n")
    let before = CalibrationHash.hash(
      try CalibrationHash.discover(root: repository.root, suite: .build))

    try repository.write("plugin/agents/design-drafter.md", "draft differently\n")
    try repository.write("plugin/workflows/build-task.js", "export const steps = [1];\n")
    #expect(
      CalibrationHash.hash(try CalibrationHash.discover(root: repository.root, suite: .build))
        == before)

    for agent in ["build-worker", "build-fixer"] {
      let path = "plugin/agents/\(agent).md"
      let original = try #require(repository.data(path))
      try repository.write(path, String(decoding: original, as: UTF8.self) + "\nOne more rule.\n")
      #expect(
        CalibrationHash.hash(try CalibrationHash.discover(root: repository.root, suite: .build))
          != before, "\(path)")
      try original.write(to: repository.root.appending(path: path))
    }
  }

  // MARK: - Freshness at push

  @Test(
    "a build agent edited after the last pass makes push's freshness check gate and name calibrate build — catches a changed worker or fixer prompt shipping uncalibrated"
  )
  func editedBuildAgentIsStale() throws {
    let repository = try Repository()
    defer { repository.remove() }
    let hashed = try CalibrationHash.discover(root: repository.root, suite: .build)
    let record: [String: Any] = [
      "schemaVersion": 2, "contentHash": CalibrationHash.hash(hashed),
      "hashedFiles": hashed.map(\.path), "passedAt": "2026-09-21T12:00:00Z",
      "cases": [
        ["agent": "build-fixer", "case": "c", "model": "opus", "answers": []],
        ["agent": "build-worker", "case": "c", "model": "sonnet", "answers": []],
      ],
    ]
    try repository.write(
      CalibrationSuite.build.recordPath,
      String(decoding: try JSONSerialization.data(withJSONObject: record), as: UTF8.self))
    let fresh = try CalibrationFreshness.run(root: repository.root)
    #expect(fresh.map(\.ruleID) == [CalibrationFreshness.summaryRuleID])
    #expect(fresh.first?.message.contains("2 build prompt file(s) match") == true)

    let worker = "plugin/agents/build-worker.md"
    let original = String(decoding: try #require(repository.data(worker)), as: UTF8.self)
    try repository.write(worker, original + "\nOne more rule.\n")
    let stale = try CalibrationFreshness.run(root: repository.root)

    #expect(stale.map(\.ruleID) == [CalibrationFreshness.staleRuleID])
    #expect(stale.first?.file == CalibrationSuite.build.recordPath)
    #expect(stale.first?.message.contains("swiftgate calibrate build") == true)
    #expect(stale.first?.severity.failsGate == true)
  }

  @Test(
    "the build agents with no build pass on record gate push — catches a first build prompt merged without ever calibrating"
  )
  func missingBuildRecordGates() throws {
    let repository = try Repository()
    defer { repository.remove() }

    let findings = try CalibrationFreshness.run(root: repository.root)

    #expect(findings.map(\.ruleID) == [CalibrationFreshness.noRecordRuleID])
    #expect(findings.first?.file == CalibrationSuite.build.recordPath)
  }

  @Test(
    "the committed build last-pass.json is fresh for this checkout's build agents — catches a worker or fixer change merged without a calibration pass"
  )
  func committedBuildRecordIsFresh() throws {
    let checkout = Fixture.harnessCheckout
    let record = try CalibrationRecord.decode(
      try Data(contentsOf: checkout.appending(path: CalibrationSuite.build.recordPath)))
    let hashed = try CalibrationHash.discover(root: checkout, suite: .build)

    #expect(
      hashed.map(\.path) == ["plugin/agents/build-fixer.md", "plugin/agents/build-worker.md"])
    #expect(record.contentHash == CalibrationHash.hash(hashed))
    #expect(record.cases.map(\.agent).sorted() == ["build-fixer", "build-worker"])
  }
}
