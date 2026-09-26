import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

/// Every test builds fixture agents and seeds in a temp repository root and answers through a
/// recorded runner: the real `claude -p` result envelope captured for the judge, with only its
/// `structured_output` swapped per case. Nothing calls the real `claude` CLI.
@Suite("swiftgate calibrate design")
struct CalibrateDesignCommandTests {
  static let passedAt = Date(timeIntervalSince1970: 1_790_000_000)

  struct Repository {
    let root: URL

    init() throws {
      root = FileManager.default.temporaryDirectory
        .appending(
          path: "swiftgate-calibrate-design-\(UUID().uuidString)", directoryHint: .isDirectory
        )
        .resolvingSymlinksInPath()
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func write(_ path: String, _ text: String) throws {
      let url = root.appending(path: path)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(text.utf8).write(to: url)
    }

    func data(_ path: String) -> Data? { try? Data(contentsOf: root.appending(path: path)) }

    func agent(_ name: String, body: String) throws {
      try write(
        "agents/\(name).md",
        "---\nname: \(name)\ndescription: fixture agent\ntools: Read\n---\n\n\(body)\n")
    }

    /// A case whose input carries `token`, so the recorded runner can tell cases apart.
    func seed(
      agent: String, name: String, token: String, expected: String, label: Bool = true
    ) throws {
      let directory = "\(DesignCalibrationLayout.seedsDirectory)/\(agent)/\(name)"
      try write("\(directory)/input.md", "Case \(token): the design says X; the evidence says Y.\n")
      if label {
        try write(
          "\(directory)/label.json",
          """
          {
            "schemaVersion": 1,
            "questions": [
              {
                "id": "verdict",
                "text": "Is the claim supported by the quoted evidence?",
                "options": ["supported", "overstated"],
                "expected": "\(expected)"
              }
            ]
          }
          """)
      }
    }

    /// Two design agents, one case each, both labelled `overstated`.
    static func calibrated() throws -> Repository {
      let repository = try Repository()
      try repository.agent("design-claim-checker", body: "You check claims. CLAIM-CHECKER-BODY")
      try repository.agent("design-challenger", body: "You challenge options.")
      try repository.write("workflows/design-review.js", "export const steps = [];\n")
      try repository.seed(
        agent: "design-claim-checker", name: "overstated-claim", token: "TOKEN-A",
        expected: "overstated")
      try repository.seed(
        agent: "design-challenger", name: "refuted-api", token: "TOKEN-B", expected: "overstated")
      return repository
    }
  }

  /// The real envelope from `Judge/claude-result.json` with `structured_output` replaced.
  static func envelope(_ structured: [String: Any]) -> String {
    guard
      let data = try? Fixture.data("Judge/claude-result.json"),
      var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return "" }
    object["structured_output"] = structured
    let encoded = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    return String(decoding: encoded, as: UTF8.self)
  }

  /// Answers `verdict` with probability 0.9 on `answers[token]` for the case whose stdin carries
  /// that token.
  static func recorded(_ answers: [String: String]) -> FakeProcessRunner {
    FakeProcessRunner { invocation throws(ProcessRunnerError) in
      let stdin = String(decoding: invocation.standardInput ?? Data(), as: UTF8.self)
      guard let (_, option) = answers.first(where: { stdin.contains($0.key) }) else {
        return ProcessOutput(status: .exited(1), stdout: "", stderr: "unscripted case")
      }
      let other = option == "supported" ? "overstated" : "supported"
      return ProcessOutput(
        status: .exited(0),
        stdout: envelope([
          "verdict": [option: 0.9, other: 0.1, "rationale": "recorded"] as [String: Any]
        ]))
    }
  }

  static func run(_ repository: Repository, runner: FakeProcessRunner) async
    -> StaticCheckOutcome
  {
    await CalibrateDesignRun.run(
      root: repository.root, runner: runner, model: "sonnet", now: passedAt)
  }

  static func exitCode(_ outcome: StaticCheckOutcome) throws -> Int32 {
    try StaticCheckReport.make(runID: "test", durationMilliseconds: 0, outcome: outcome)
      .verdict.exitCode
  }

  static func findings(_ outcome: StaticCheckOutcome) -> [Finding] {
    guard case .checked(let result) = outcome else { return [] }
    return result.findings
  }

  // MARK: - Runs

  @Test(
    "every label met writes last-pass.json with the current content hash — catches a pass recording a stale or missing hash"
  )
  func fullPassWritesRecord() async throws {
    let repository = try Repository.calibrated()
    let outcome = await Self.run(
      repository, runner: Self.recorded(["TOKEN-A": "overstated", "TOKEN-B": "overstated"]))
    #expect(try Self.exitCode(outcome) == 0)
    let data = try #require(repository.data(DesignCalibrationLayout.recordPath))
    let record = try CalibrationRecord.decode(data)
    let expectedHash = DesignCalibrationHash.hash(
      try DesignCalibrationHash.discover(root: repository.root))
    #expect(record.schemaVersion == 1)
    #expect(record.contentHash == expectedHash)
    #expect(
      record.hashedFiles == [
        "agents/design-challenger.md", "agents/design-claim-checker.md",
        "workflows/design-review.js",
      ])
    #expect(record.passedAt == Self.passedAt)
    #expect(record.model == "sonnet")
    #expect(
      record.cases.map { "\($0.agent)/\($0.caseName)" } == [
        "design-challenger/refuted-api", "design-claim-checker/overstated-claim",
      ])
    #expect(
      record.cases.flatMap(\.answers).allSatisfy {
        $0.answered == "overstated" && $0.expected == "overstated"
      })
  }

  @Test(
    "one missed label exits 1 and leaves last-pass.json byte-identical — catches a regressed prompt passing calibration"
  )
  func missLeavesRecordUntouched() async throws {
    let repository = try Repository.calibrated()
    let previous = "{\"previous\": \"record\"}\n"
    try repository.write(DesignCalibrationLayout.recordPath, previous)
    let outcome = await Self.run(
      repository, runner: Self.recorded(["TOKEN-A": "supported", "TOKEN-B": "overstated"]))
    #expect(try Self.exitCode(outcome) == 1)
    #expect(repository.data(DesignCalibrationLayout.recordPath) == Data(previous.utf8))
    let missed = Self.findings(outcome).filter { $0.ruleID == "calibrate-design.label-missed" }
    #expect(missed.count == 1)
    #expect(missed.first?.message.contains("design-claim-checker/overstated-claim") == true)
    #expect(missed.first?.message.contains("supported") == true)
  }

  @Test(
    "a case without a label exits 1 naming the case before any agent runs — catches an unlabelled seed counting as met"
  )
  func missingLabelFails() async throws {
    let repository = try Repository.calibrated()
    try repository.seed(
      agent: "design-challenger", name: "unlabelled", token: "TOKEN-C", expected: "", label: false)
    let runner = Self.recorded(["TOKEN-A": "overstated", "TOKEN-B": "overstated"])
    let outcome = await Self.run(repository, runner: runner)
    #expect(try Self.exitCode(outcome) == 1)
    let finding = Self.findings(outcome).first { $0.ruleID == "calibrate-design.missing-label" }
    #expect(
      finding?.file == "\(DesignCalibrationLayout.seedsDirectory)/design-challenger/unlabelled")
    #expect(runner.invocations.isEmpty)
    #expect(repository.data(DesignCalibrationLayout.recordPath) == nil)
  }

  @Test(
    "a label whose expected answer isn't one of its options exits 1 naming the file — catches a typo'd label that no agent can meet"
  )
  func invalidLabelFails() async throws {
    let repository = try Repository.calibrated()
    try repository.seed(
      agent: "design-challenger", name: "typo", token: "TOKEN-D", expected: "overstatd")
    let outcome = await Self.run(repository, runner: Self.recorded([:]))
    #expect(try Self.exitCode(outcome) == 1)
    let finding = Self.findings(outcome).first { $0.ruleID == "calibrate-design.invalid-label" }
    #expect(
      finding?.file
        == "\(DesignCalibrationLayout.seedsDirectory)/design-challenger/typo/label.json")
  }

  @Test(
    "a design agent with no seeds, or seeds for an agent that doesn't exist, exits 1 — catches an uncalibrated prompt covered by the hash"
  )
  func agentsAndSeedsMustMatch() async throws {
    let repository = try Repository.calibrated()
    try repository.agent("design-auditor", body: "You audit.")
    try repository.seed(
      agent: "design-ghost", name: "case", token: "TOKEN-E", expected: "supported")
    let outcome = await Self.run(repository, runner: Self.recorded([:]))
    #expect(try Self.exitCode(outcome) == 1)
    let byRule = Dictionary(grouping: Self.findings(outcome), by: \.ruleID)
    #expect(
      byRule["calibrate-design.uncalibrated-agent"]?.map(\.file) == ["agents/design-auditor.md"])
    #expect(
      byRule["calibrate-design.unknown-agent"]?.map(\.file) == [
        "\(DesignCalibrationLayout.seedsDirectory)/design-ghost"
      ])
  }

  @Test("no seeds at all exits 1 — catches an empty calibration recording a pass")
  func noSeedsFails() async throws {
    let repository = try Repository()
    let outcome = await Self.run(repository, runner: Self.recorded([:]))
    #expect(try Self.exitCode(outcome) == 1)
    #expect(Self.findings(outcome).contains { $0.ruleID == "calibrate-design.no-seeds" })
    #expect(repository.data(DesignCalibrationLayout.recordPath) == nil)
  }

  @Test(
    "a claude error envelope blocks with exit 2 and writes nothing — catches a backend outage read as a missed label"
  )
  func backendErrorBlocks() async throws {
    let repository = try Repository.calibrated()
    let errorEnvelope = try Fixture.text("Judge/claude-unknown-model.json")
    let runner = FakeProcessRunner { _ throws(ProcessRunnerError) in
      ProcessOutput(status: .exited(1), stdout: errorEnvelope)
    }
    let outcome = await Self.run(repository, runner: runner)
    #expect(try Self.exitCode(outcome) == 2)
    guard case .blocked(let reason) = outcome else {
      Issue.record("expected blocked, got \(outcome)")
      return
    }
    #expect(reason.contains("no-such-model"))
    #expect(repository.data(DesignCalibrationLayout.recordPath) == nil)
  }

  @Test(
    "each case runs the agent's prompt body as the system prompt with the case input on stdin and no tools — catches calibrating a different prompt than the one shipped"
  )
  func invocationCarriesAgentPromptAndCase() async throws {
    let repository = try Repository.calibrated()
    let runner = Self.recorded(["TOKEN-A": "overstated", "TOKEN-B": "overstated"])
    _ = await Self.run(repository, runner: runner)
    let invocation = try #require(
      runner.invocations.first {
        String(decoding: $0.standardInput ?? Data(), as: UTF8.self).contains("TOKEN-A")
      })
    let arguments = invocation.arguments
    #expect(invocation.executable == "claude")
    let systemPrompt = try #require(arguments.firstIndex(of: "--system-prompt"))
    #expect(arguments[systemPrompt + 1] == "You check claims. CLAIM-CHECKER-BODY")
    let tools = try #require(arguments.firstIndex(of: "--tools"))
    #expect(arguments[tools + 1] == "")
    let model = try #require(arguments.firstIndex(of: "--model"))
    #expect(arguments[model + 1] == "sonnet")
    #expect(arguments.contains("--json-schema"))
  }

  // MARK: - Seed and runner failures

  static func blockedReason(_ outcome: StaticCheckOutcome) -> String? {
    guard case .blocked(let reason) = outcome else { return nil }
    return reason
  }

  @Test(
    "a case with a label but no input exits 1 naming the case before any agent runs — catches a label scored against an empty prompt"
  )
  func missingInputFails() async throws {
    let repository = try Repository.calibrated()
    let directory = "\(DesignCalibrationLayout.seedsDirectory)/design-challenger/no-input"
    try repository.seed(
      agent: "design-challenger", name: "no-input", token: "TOKEN-F", expected: "supported")
    try FileManager.default.removeItem(at: repository.root.appending(path: "\(directory)/input.md"))
    let runner = Self.recorded([:])

    let outcome = await Self.run(repository, runner: runner)

    #expect(try Self.exitCode(outcome) == 1)
    let finding = Self.findings(outcome).first { $0.ruleID == "calibrate-design.missing-input" }
    #expect(finding?.file == directory)
    #expect(runner.invocations.isEmpty)
  }

  @Test(
    "a seed input that isn't UTF-8 blocks with exit 2 naming the file, before any agent runs — catches an unreadable seed skipped as if absent"
  )
  func unreadableInputBlocks() async throws {
    let repository = try Repository.calibrated()
    let input = "\(DesignCalibrationLayout.seedsDirectory)/design-challenger/refuted-api/input.md"
    try Data([0xFF, 0xFE, 0xFD]).write(to: repository.root.appending(path: input))
    let runner = Self.recorded(["TOKEN-A": "overstated"])

    let outcome = await Self.run(repository, runner: runner)

    #expect(try Self.exitCode(outcome) == 2)
    #expect(Self.blockedReason(outcome)?.contains("can't read \(input)") == true)
    #expect(runner.invocations.isEmpty)
    #expect(repository.data(DesignCalibrationLayout.recordPath) == nil)
  }

  @Test(
    "an agent's seed directory that can't be listed blocks with exit 2 naming it — catches its cases silently dropped from the pass"
  )
  func unlistableSeedDirectoryBlocks() async throws {
    let repository = try Repository.calibrated()
    let directory = "\(DesignCalibrationLayout.seedsDirectory)/design-challenger"
    let url = repository.root.appending(path: directory)
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    let outcome = await Self.run(repository, runner: Self.recorded(["TOKEN-A": "overstated"]))

    #expect(try Self.exitCode(outcome) == 2)
    #expect(Self.blockedReason(outcome)?.contains("can't read \(directory)") == true)
    #expect(repository.data(DesignCalibrationLayout.recordPath) == nil)
  }

  @Test(
    "a design agent prompt that can't be read blocks with exit 2 — catches calibrating without the prompt the hash covers"
  )
  func unreadableAgentBlocks() async throws {
    let repository = try Repository.calibrated()
    let agent = repository.root.appending(path: "agents/design-challenger.md")
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: agent.path)
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: agent.path)
    }
    let runner = Self.recorded(["TOKEN-A": "overstated", "TOKEN-B": "overstated"])

    let outcome = await Self.run(repository, runner: runner)

    #expect(try Self.exitCode(outcome) == 2)
    let reason = try #require(Self.blockedReason(outcome))
    #expect(reason.contains("agents/design-challenger.md"))
    #expect(reason.contains("can't list the design agents"))
    #expect(runner.invocations.isEmpty)
  }

  @Test(
    "claude failing to launch blocks with exit 2 naming the case and writes nothing — catches a missing CLI read as a missed label"
  )
  func launchFailureBlocks() async throws {
    let repository = try Repository.calibrated()
    let runner = FakeProcessRunner { invocation throws(ProcessRunnerError) in
      throw .launchFailed(executable: invocation.executable, reason: "not on PATH")
    }

    let outcome = await Self.run(repository, runner: runner)

    #expect(try Self.exitCode(outcome) == 2)
    let reason = try #require(Self.blockedReason(outcome))
    #expect(reason.contains("design-challenger/refuted-api"))
    #expect(reason.contains("not on PATH"))
    #expect(runner.invocations.count == 1)
    #expect(repository.data(DesignCalibrationLayout.recordPath) == nil)
  }

  @Test(
    "a full pass whose record can't be written blocks with exit 2 — catches a pass reported green that left no record for push"
  )
  func unwritableRecordBlocks() async throws {
    let repository = try Repository.calibrated()
    let seeds = repository.root.appending(path: DesignCalibrationLayout.seedsDirectory)
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: seeds.path)
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: seeds.path)
    }

    let outcome = await Self.run(
      repository, runner: Self.recorded(["TOKEN-A": "overstated", "TOKEN-B": "overstated"]))

    #expect(try Self.exitCode(outcome) == 2)
    #expect(
      Self.blockedReason(outcome)?.contains("can't write \(DesignCalibrationLayout.recordPath)")
        == true)
  }

  @Test(
    "seeds for a non-design agent are unknown, while stray files and dot-entries are ignored — catches a reviewer outside the hash counted as calibrated"
  )
  func nonDesignAgentAndStrayEntries() async throws {
    let repository = try Repository.calibrated()
    try repository.agent("verifier", body: "You verify.")
    try repository.seed(agent: "verifier", name: "case", token: "TOKEN-G", expected: "supported")
    let seeds = DesignCalibrationLayout.seedsDirectory
    try repository.write("\(seeds)/notes.txt", "not a seed\n")
    try repository.write("\(seeds)/.cache/case/input.md", "hidden\n")
    try repository.write("\(seeds)/design-challenger/notes.txt", "not a case\n")
    try repository.write("\(seeds)/design-challenger/.draft/input.md", "hidden\n")

    let outcome = await Self.run(repository, runner: Self.recorded([:]))

    #expect(try Self.exitCode(outcome) == 1)
    #expect(
      Self.findings(outcome).map { "\($0.ruleID) \($0.file)" } == [
        "calibrate-design.unknown-agent \(seeds)/verifier"
      ])
  }

  @Test(
    "a prompt's CRLF frontmatter is stripped and a prompt with none is sent whole — catches frontmatter calibrated as prompt text or a body dropped"
  )
  func systemPromptBodyVariants() async throws {
    let repository = try Repository.calibrated()
    try repository.write(
      "agents/design-claim-checker.md",
      "---\r\nname: design-claim-checker\r\ntools: Read\r\n---\r\n\r\nCRLF body.\r\n")
    try repository.write("agents/design-challenger.md", "\nNo frontmatter here.\n---\nstill body\n")
    let runner = Self.recorded(["TOKEN-A": "overstated", "TOKEN-B": "overstated"])

    _ = await Self.run(repository, runner: runner)

    func systemPrompt(_ token: String) -> String? {
      guard
        let invocation = runner.invocations.first(where: {
          String(decoding: $0.standardInput ?? Data(), as: UTF8.self).contains(token)
        }),
        let index = invocation.arguments.firstIndex(of: "--system-prompt")
      else { return nil }
      return invocation.arguments[index + 1]
    }
    #expect(systemPrompt("TOKEN-A") == "CRLF body.")
    #expect(systemPrompt("TOKEN-B") == "No frontmatter here.\n---\nstill body")
  }
}
