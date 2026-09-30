import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

/// Every test builds fixture agents and seeds in a temp repository root and answers through a
/// recorded runner: the real `claude -p` result envelope captured for the judge, with only its
/// `result` (an agent's reply) or `structured_output` (the judge's) swapped per case. Nothing
/// calls the real `claude` CLI.
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

    func agent(_ name: String, body: String, model: String? = nil) throws {
      let pinned = model.map { "model: \($0)\n" } ?? ""
      try write(
        "plugin/agents/\(name).md",
        "---\nname: \(name)\ndescription: fixture agent\ntools: Read\n\(pinned)---\n\n\(body)\n")
    }

    /// A case whose input carries `token`, so the recorded runner can tell cases apart. Its
    /// label checks that the returned verdict for `ev-case` has status `expected`.
    func seed(
      agent: String, name: String, token: String, expected: String, label: Bool = true
    ) throws {
      try seed(
        agent: agent, name: name, token: token,
        label: label
          ? """
          {
            "schemaVersion": 2,
            "checks": [
              {
                "id": "verdict",
                "kind": "value",
                "array": "verdicts",
                "where": [{"path": "id", "oneOf": ["ev-case"]}],
                "field": "status",
                "expected": "\(expected)"
              }
            ]
          }
          """ : nil)
    }

    func seed(agent: String, name: String, token: String, label: String?) throws {
      let directory = "\(DesignCalibrationLayout.seedsDirectory)/\(agent)/\(name)"
      try write("\(directory)/input.md", Self.input(token))
      if let label { try write("\(directory)/label.json", label) }
    }

    static func input(_ token: String) -> String {
      "Case \(token): the design says X; the evidence says Y.\n"
    }

    /// Two design agents, one case each, both labelled `overstated`. The claim checker pins opus
    /// in its frontmatter; the challenger pins nothing.
    static func calibrated() throws -> Repository {
      let repository = try Repository()
      try repository.agent(
        "design-claim-checker", body: "You check claims. CLAIM-CHECKER-BODY", model: "opus")
      try repository.agent("design-challenger", body: "You challenge options.")
      try repository.write("plugin/workflows/design-review.js", "export const steps = [];\n")
      try repository.seed(
        agent: "design-claim-checker", name: "overstated-claim", token: "TOKEN-A",
        expected: "overstated")
      try repository.seed(
        agent: "design-challenger", name: "refuted-api", token: "TOKEN-B", expected: "overstated")
      return repository
    }

    /// Adds a drafter whose one case is judged: `interval-tag` expects `expected`.
    func judgedDrafter(expected: String) throws {
      try agent("design-drafter", body: "You draft designs.", model: "opus")
      try seed(
        agent: "design-drafter", name: "unbacked-point", token: "TOKEN-J",
        label: """
          {
            "schemaVersion": 2,
            "checks": [
              {
                "id": "interval-tag",
                "kind": "judge",
                "text": "What tag does the Decision bullet on the sync interval carry?",
                "options": ["ev-claim", "unverified", "none"],
                "expected": "\(expected)"
              }
            ]
          }
          """)
    }
  }

  /// The real envelope from `Judge/claude-result.json` with `result` or `structured_output`
  /// replaced.
  static func envelope(result: String? = nil, structured: [String: Any]? = nil) -> String {
    guard
      let data = try? Fixture.data("Judge/claude-result.json"),
      var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return "" }
    if let result { object["result"] = result }
    object["structured_output"] = structured
    let encoded = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    return String(decoding: encoded, as: UTF8.self)
  }

  static func isJudge(_ invocation: ProcessInvocation) -> Bool {
    invocation.arguments.contains("--json-schema")
  }

  static func stdin(_ invocation: ProcessInvocation) -> String {
    String(decoding: invocation.standardInput ?? Data(), as: UTF8.self)
  }

  /// Plays each agent: returns `ev-case` with `statuses[token]` for the case whose stdin carries
  /// that token, fenced as models often do. Plays the judge too: `interval-tag` gets `judged`
  /// with probability `judgedProbability`.
  static func recorded(
    _ statuses: [String: String], judged: String = "unverified", judgedProbability: Double = 0.9
  ) -> FakeProcessRunner {
    FakeProcessRunner { invocation throws(ProcessRunnerError) in
      let stdin = Self.stdin(invocation)
      if Self.isJudge(invocation) {
        var answer: [String: Any] = ["rationale": "recorded"]
        let options = ["ev-claim", "unverified", "none"]
        for option in options {
          answer[option] =
            option == judged
            ? judgedProbability : (1 - judgedProbability) / Double(options.count - 1)
        }
        return ProcessOutput(
          status: .exited(0), stdout: envelope(structured: ["interval-tag": answer]))
      }
      if stdin.contains("TOKEN-J") {
        return ProcessOutput(
          status: .exited(0),
          stdout: envelope(
            result: "# Sync\n\n## Decision\n\n- Sync every 15 minutes [UNVERIFIED]\n"))
      }
      guard let (_, status) = statuses.first(where: { stdin.contains($0.key) }) else {
        return ProcessOutput(status: .exited(1), stdout: "", stderr: "unscripted case")
      }
      let reply =
        #"{"verdicts": [{"id": "ev-case", "status": "\#(status)", "reason": "r"}], "skipped": []}"#
      return ProcessOutput(
        status: .exited(0), stdout: envelope(result: "```json\n\(reply)\n```"))
    }
  }

  static func run(
    _ repository: Repository, runner: FakeProcessRunner,
    replies: DesignCalibrationReplies? = nil
  ) async -> StaticCheckOutcome {
    await CalibrateDesignRun.run(
      root: repository.root, runner: runner, model: "sonnet", now: passedAt, replies: replies)
  }

  /// The record as the JSON push reads.
  static func recordJSON(_ repository: Repository) throws -> [String: Any] {
    let data = try #require(repository.data(DesignCalibrationLayout.recordPath))
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  /// `agent/case model` for each recorded case.
  static func recordedModels(_ repository: Repository) throws -> [String] {
    let cases = try #require(try recordJSON(repository)["cases"] as? [[String: Any]])
    return cases.map { "\($0["agent"] ?? "")/\($0["case"] ?? "") \($0["model"] ?? "none")" }
  }

  static func exitCode(_ outcome: StaticCheckOutcome) throws -> Int32 {
    try StaticCheckReport.make(runID: "test", durationMilliseconds: 0, outcome: outcome)
      .verdict.exitCode
  }

  static func findings(_ outcome: StaticCheckOutcome) -> [Finding] {
    guard case .checked(let result) = outcome else { return [] }
    return result.findings
  }

  static func model(_ runner: FakeProcessRunner, token: String) -> String? {
    guard
      let invocation = runner.invocations.first(where: {
        !isJudge($0) && stdin($0).contains(token)
      }),
      let index = invocation.arguments.firstIndex(of: "--model")
    else { return nil }
    return invocation.arguments[index + 1]
  }

  // MARK: - Runs

  @Test(
    "every label met writes last-pass.json with the current content hash and each case's model — catches a pass recording a stale hash or no model"
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
    #expect(record.schemaVersion == 3)
    #expect(record.contentHash == expectedHash)
    #expect(
      record.hashedFiles == [
        "plugin/agents/design-challenger.md", "plugin/agents/design-claim-checker.md",
        "plugin/workflows/design-review.js",
      ])
    #expect(record.passedAt == Self.passedAt)
    #expect(try Self.recordJSON(repository)["modelOverride"] == nil)
    #expect(
      try Self.recordedModels(repository) == [
        "design-challenger/refuted-api sonnet", "design-claim-checker/overstated-claim opus",
      ])
    #expect(
      record.cases.flatMap(\.answers).allSatisfy {
        $0.answered == "overstated" && $0.expected == "overstated" && $0.probability == 1
      })
  }

  @Test(
    "each agent runs on the model its frontmatter names, and one that names none on the unpinned default — catches an opus agent calibrated on sonnet"
  )
  func runsEachAgentOnItsFrontmatterModel() async throws {
    let repository = try Repository.calibrated()
    let runner = Self.recorded(["TOKEN-A": "overstated", "TOKEN-B": "overstated"])

    _ = await Self.run(repository, runner: runner)

    #expect(Self.model(runner, token: "TOKEN-A") == "opus")
    #expect(Self.model(runner, token: "TOKEN-B") == "sonnet")
  }

  @Test(
    "a --model override runs every agent on it and marks the record — catches an experiment's record passing for the shipped models"
  )
  func overrideIsRecorded() async throws {
    let repository = try Repository.calibrated()
    let bin = repository.root.appending(path: "fake-bin", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: bin.appending(path: "calls"), withIntermediateDirectories: true)
    let reply = #"{"verdicts": [{"id": "ev-case", "status": "overstated", "reason": "r"}]}"#
    try Data(Self.envelope(result: reply).utf8).write(to: bin.appending(path: "reply.json"))
    // A stand-in `claude` that logs its arguments and answers every case alike.
    let claude = bin.appending(path: "claude")
    try Data(
      """
      #!/bin/bash
      here="$(cd "$(dirname "$0")" && pwd)"
      cat > /dev/null
      printf '%s\\n' "$@" > "$(mktemp "$here/calls/call.XXXXXX")"
      cat "$here/reply.json"

      """.utf8
    ).write(to: claude)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claude.path)

    // The same argv parses in process first, so a flag the command lacks fails here by name.
    let parsed = try CalibrateCommand.parseAsRoot(["design", "--model", "haiku"])
    #expect((parsed as? CalibrateDesignCommand)?.model == "haiku")
    let output = try await LiveProcessRunner().run(
      ProcessInvocation(
        executable: Fixture.gateDirectory.appending(path: ".build/debug/swiftgate").path,
        arguments: ["calibrate", "design", "--model", "haiku"],
        environmentOverlay: [
          "PATH": "\(bin.path):\(ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin")",
          "LLVM_PROFILE_FILE": repository.root.appending(path: "swiftgate-%p.profraw").path,
        ],
        workingDirectory: repository.root.path, timeout: .seconds(300)))

    #expect(output.status == .exited(0), "\(output.stdout.text)\(output.stderr.text)")
    let calls = try FileManager.default.contentsOfDirectory(
      at: bin.appending(path: "calls"), includingPropertiesForKeys: nil)
    #expect(calls.count == 2)
    for call in calls {
      let arguments = try String(contentsOf: call, encoding: .utf8).split(separator: "\n")
      let model = try #require(arguments.firstIndex(of: "--model"))
      #expect(arguments[model + 1] == "haiku")
    }
    #expect(try Self.recordJSON(repository)["modelOverride"] as? String == "haiku")
    #expect(
      try Self.recordedModels(repository) == [
        "design-challenger/refuted-api haiku", "design-claim-checker/overstated-claim haiku",
      ])
    let runs = repository.root.appending(path: RunLayout.runsDirectory)
    let reported = try FileManager.default.contentsOfDirectory(atPath: runs.path).filter {
      FileManager.default.fileExists(
        atPath: runs.appending(path: "\($0)/\(RunLayout.reportFileName)").path)
    }
    #expect(reported.count == 1)
    let kept = try #require(
      reported.first.map {
        repository.data(
          "\(RunLayout.runDirectory(for: $0))calibrate-design/design-challenger/refuted-api.txt")
      })
    #expect(kept == Data(reply.utf8))
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
    #expect(missed.first?.message.contains("design-claim-checker/overstated-claim on opus") == true)
    #expect(missed.first?.message.contains("answered `supported`") == true)
  }

  @Test(
    "an agent reply holding no JSON object misses every JSON check instead of blocking — catches prose that ignores the output contract scored as a pass or an outage"
  )
  func replyWithoutJSONMisses() async throws {
    let repository = try Repository.calibrated()
    let runner = FakeProcessRunner { invocation throws(ProcessRunnerError) in
      ProcessOutput(
        status: .exited(0),
        stdout: Self.envelope(result: "The claim looks overstated to me."))
    }

    let outcome = await Self.run(repository, runner: runner)

    #expect(try Self.exitCode(outcome) == 1)
    let missed = Self.findings(outcome).filter { $0.ruleID == "calibrate-design.label-missed" }
    #expect(missed.count == 2)
    #expect(missed.allSatisfy { $0.message.contains("answered `no JSON object`") })
  }

  @Test(
    "the agent gets the case input alone on stdin and nothing from its label — catches a calibration question leading the agent to the planted answer"
  )
  func agentPromptCarriesNoLabel() async throws {
    let repository = try Repository.calibrated()
    let runner = Self.recorded(["TOKEN-A": "overstated", "TOKEN-B": "overstated"])

    _ = await Self.run(repository, runner: runner)

    let agentRuns = runner.invocations.filter { !Self.isJudge($0) }
    #expect(agentRuns.count == 2)
    for invocation in agentRuns {
      let stdin = Self.stdin(invocation)
      #expect(stdin == Repository.input("TOKEN-A") || stdin == Repository.input("TOKEN-B"))
      let everything = ([stdin] + invocation.arguments).joined(separator: "\n")
      #expect(!everything.contains("overstated"))
      #expect(!everything.contains("verdict"))
    }
  }

  @Test(
    "the judge's prompt and schema are the same whichever option the label expects, and hold the agent's output — catches a judge question that leaks the expected answer"
  )
  func judgePromptCarriesNoExpectedLabel() async throws {
    var judgeInvocations: [ProcessInvocation] = []
    for expected in ["unverified", "ev-claim"] {
      let repository = try Repository.calibrated()
      try repository.judgedDrafter(expected: expected)
      let runner = Self.recorded(["TOKEN-A": "overstated", "TOKEN-B": "overstated"])
      _ = await Self.run(repository, runner: runner)
      judgeInvocations.append(try #require(runner.invocations.first(where: Self.isJudge)))
    }
    #expect(judgeInvocations[0].arguments == judgeInvocations[1].arguments)
    #expect(Self.stdin(judgeInvocations[0]) == Self.stdin(judgeInvocations[1]))
    let prompt = Self.stdin(judgeInvocations[0])
    #expect(prompt.contains("- Sync every 15 minutes [UNVERIFIED]"))
    #expect(!prompt.contains("expected"))
    #expect(!prompt.contains("TOKEN-J"))
  }

  @Test(
    "a judged answer on the label's option passes at p = 0.7 and misses at p = 0.6, naming the margin — catches a coin-flip answer recorded as calibrated"
  )
  func judgedAnswerNeedsTheMargin() async throws {
    let repository = try Repository.calibrated()
    try repository.judgedDrafter(expected: "unverified")

    let weak = await Self.run(
      repository,
      runner: Self.recorded(
        ["TOKEN-A": "overstated", "TOKEN-B": "overstated"], judged: "unverified",
        judgedProbability: 0.6))
    #expect(try Self.exitCode(weak) == 1)
    let missed = Self.findings(weak).filter { $0.ruleID == "calibrate-design.label-missed" }
    #expect(missed.count == 1)
    #expect(missed.first?.message.contains("p=0.60, below the 0.70") == true)
    #expect(repository.data(DesignCalibrationLayout.recordPath) == nil)

    let firm = await Self.run(
      repository,
      runner: Self.recorded(
        ["TOKEN-A": "overstated", "TOKEN-B": "overstated"], judged: "unverified",
        judgedProbability: 0.7))
    #expect(try Self.exitCode(firm) == 0)
    let record = try CalibrationRecord.decode(
      try #require(repository.data(DesignCalibrationLayout.recordPath)))
    let drafter = try #require(record.cases.first { $0.agent == "design-drafter" })
    #expect(drafter.answers.map(\.answered) == ["unverified"])
    #expect(drafter.answers.first?.probability == 0.7)
    #expect(try Self.recordedModels(repository).contains("design-drafter/unbacked-point opus"))
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
    "a label with a leading judge question exits 1 naming the file — catches a question that names its answer reaching a run"
  )
  func invalidLabelFails() async throws {
    let repository = try Repository.calibrated()
    try repository.seed(
      agent: "design-challenger", name: "leading", token: "TOKEN-D",
      label: """
        {"schemaVersion": 2, "checks": [{"id": "q", "kind": "judge",
          "text": "Is there a blocker finding about the refuted API?",
          "options": ["yes", "no"], "expected": "yes"}]}
        """)
    let outcome = await Self.run(repository, runner: Self.recorded([:]))
    #expect(try Self.exitCode(outcome) == 1)
    let finding = Self.findings(outcome).first { $0.ruleID == "calibrate-design.invalid-label" }
    #expect(
      finding?.file
        == "\(DesignCalibrationLayout.seedsDirectory)/design-challenger/leading/label.json")
    #expect(finding?.message.contains("asks yes or no") == true)
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
      byRule["calibrate-design.uncalibrated-agent"]?.map(\.file) == [
        "plugin/agents/design-auditor.md"
      ])
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
    "each case runs the agent's prompt body as the system prompt with the case input on stdin, no tools and no calibration schema — catches calibrating a different prompt or contract than the one shipped"
  )
  func invocationCarriesAgentPromptAndCase() async throws {
    let repository = try Repository.calibrated()
    let runner = Self.recorded(["TOKEN-A": "overstated", "TOKEN-B": "overstated"])
    _ = await Self.run(repository, runner: runner)
    let invocation = try #require(
      runner.invocations.first { Self.stdin($0).contains("TOKEN-A") })
    let arguments = invocation.arguments
    #expect(invocation.executable == "claude")
    let systemPrompt = try #require(arguments.firstIndex(of: "--system-prompt"))
    #expect(arguments[systemPrompt + 1] == "You check claims. CLAIM-CHECKER-BODY")
    let tools = try #require(arguments.firstIndex(of: "--tools"))
    #expect(arguments[tools + 1] == "")
    #expect(!arguments.contains("--json-schema"))
    #expect(arguments.contains("--restricted"))
  }

  // MARK: - Kept replies and replay

  static let keptRunID = "20260930T120000Z-0000abcd"

  static func replies(_ repository: Repository, _ mode: DesignCalibrationReplies.Mode)
    -> DesignCalibrationReplies
  {
    DesignCalibrationReplies(root: repository.root, runID: keptRunID, mode: mode)
  }

  static func keptPath(agent: String, seed: String, _ suffix: String) -> String {
    "\(RunLayout.runDirectory(for: keptRunID))calibrate-design/\(agent)/\(seed).\(suffix)"
  }

  static func agentRuns(_ runner: FakeProcessRunner) -> [ProcessInvocation] {
    runner.invocations.filter { !isJudge($0) }
  }

  @Test(
    "a live run keeps each agent's reply byte for byte with the requested and served models, and names both — catches a trimmed, re-encoded or lost reply leaving a miss undiagnosable"
  )
  func liveRunKeepsEachReply() async throws {
    let repository = try Repository.calibrated()
    let replies = [
      "TOKEN-A":
        "  ```json\n{\"verdicts\": [{\"id\": \"ev-case\", \"status\": \"overstated\"}]}\n```\n\n— ✓ done  \n",
      "TOKEN-B": "{\"verdicts\": [{\"id\": \"ev-case\", \"status\": \"overstated\"}]}\r\n\t",
    ]
    let runner = FakeProcessRunner { invocation throws(ProcessRunnerError) in
      let stdin = Self.stdin(invocation)
      guard let (_, reply) = replies.first(where: { stdin.contains($0.key) }) else {
        return ProcessOutput(status: .exited(1), stdout: "", stderr: "unscripted case")
      }
      return ProcessOutput(status: .exited(0), stdout: Self.envelope(result: reply))
    }

    let outcome = await Self.run(
      repository, runner: runner, replies: Self.replies(repository, .keep))

    #expect(try Self.exitCode(outcome) == 0)
    for (agent, seed, token, model) in [
      ("design-claim-checker", "overstated-claim", "TOKEN-A", "opus"),
      ("design-challenger", "refuted-api", "TOKEN-B", "sonnet"),
    ] {
      let kept = repository.data(Self.keptPath(agent: agent, seed: seed, "txt"))
      #expect(kept == Data(try #require(replies[token]).utf8), "\(agent)/\(seed)")
      let metadataData = try #require(
        repository.data(Self.keptPath(agent: agent, seed: seed, "json")))
      let metadata = try #require(
        try JSONSerialization.jsonObject(with: metadataData) as? [String: Any])
      #expect(metadata["requestedModel"] as? String == model)
      #expect(metadata["servedModels"] as? [String] == ["claude-haiku-4-5-20251001"])
      let usage = Self.findings(outcome).first {
        $0.ruleID == "calibrate-design.usage" && $0.message.hasPrefix("\(agent)/\(seed) ")
      }
      #expect(usage?.message.contains("served claude-haiku-4-5-20251001") == true)
      #expect(
        usage?.message.contains(Self.keptPath(agent: agent, seed: seed, "txt")) == true)
    }
  }

  @Test(
    "a replay runs no agent and judges the kept replies to the same answers as the live run — catches a replay that re-runs the agents"
  )
  func replayJudgesKeptReplies() async throws {
    let repository = try Repository.calibrated()
    try repository.judgedDrafter(expected: "unverified")
    let live = await Self.run(
      repository,
      runner: Self.recorded(
        ["TOKEN-A": "supported", "TOKEN-B": "overstated"], judgedProbability: 0.6),
      replies: Self.replies(repository, .keep))
    // Agents that would answer differently, so a replay that re-runs them can't match.
    let replayRunner = Self.recorded(
      ["TOKEN-A": "overstated", "TOKEN-B": "supported"], judgedProbability: 0.6)

    let replay = await Self.run(
      repository, runner: replayRunner, replies: Self.replies(repository, .replay))

    #expect(Self.agentRuns(replayRunner).isEmpty)
    #expect(replayRunner.invocations.filter(Self.isJudge).count == 1)
    #expect(try Self.exitCode(replay) == 1)
    let missed = { (outcome: StaticCheckOutcome) in
      Self.findings(outcome).filter { $0.ruleID == "calibrate-design.label-missed" }.map(\.message)
    }
    #expect(missed(live).count == 2)
    #expect(missed(replay) == missed(live))
  }

  @Test(
    "a replay with a missing reply blocks with exit 2 naming the seed, before any agent runs — catches a gap filled by a live agent run or skipped"
  )
  func replayWithMissingReplyBlocks() async throws {
    let repository = try Repository.calibrated()
    _ = await Self.run(
      repository, runner: Self.recorded(["TOKEN-A": "overstated", "TOKEN-B": "overstated"]),
      replies: Self.replies(repository, .keep))
    let kept = Self.keptPath(agent: "design-challenger", seed: "refuted-api", "txt")
    try #require(repository.data(kept) != nil)
    try FileManager.default.removeItem(at: repository.root.appending(path: kept))
    let runner = Self.recorded(["TOKEN-A": "overstated", "TOKEN-B": "overstated"])

    let outcome = await Self.run(
      repository, runner: runner, replies: Self.replies(repository, .replay))

    #expect(try Self.exitCode(outcome) == 2)
    let reason = try #require(Self.blockedReason(outcome))
    #expect(reason.contains("design-challenger/refuted-api"))
    #expect(reason.contains(Self.keptPath(agent: "design-challenger", seed: "refuted-api", "txt")))
    #expect(Self.agentRuns(runner).isEmpty)
  }

  @Test(
    "a replay whose kept model record is unreadable blocks with exit 2 naming the file — catches a replay reporting a miss on a model nobody recorded"
  )
  func replayWithUnreadableMetadataBlocks() async throws {
    let repository = try Repository.calibrated()
    _ = await Self.run(
      repository, runner: Self.recorded(["TOKEN-A": "overstated", "TOKEN-B": "overstated"]),
      replies: Self.replies(repository, .keep))
    let metadata = Self.keptPath(agent: "design-claim-checker", seed: "overstated-claim", "json")
    try repository.write(
      metadata, #"{"schemaVersion": 2, "requestedModel": "opus", "servedModels": []}"#)

    let outcome = await Self.run(
      repository, runner: Self.recorded([:]), replies: Self.replies(repository, .replay))

    #expect(try Self.exitCode(outcome) == 2)
    #expect(Self.blockedReason(outcome)?.contains(metadata) == true)
  }

  @Test(
    "a passing replay leaves last-pass.json byte-identical and says so — catches stored replies refreshing the record without running the agents"
  )
  func passingReplyLeavesRecordUnchanged() async throws {
    let repository = try Repository.calibrated()
    let live = await Self.run(
      repository, runner: Self.recorded(["TOKEN-A": "overstated", "TOKEN-B": "overstated"]),
      replies: Self.replies(repository, .keep))
    #expect(try Self.exitCode(live) == 0)
    let previous = "{\"previous\": \"record\"}\n"
    try repository.write(DesignCalibrationLayout.recordPath, previous)

    let replay = await Self.run(
      repository, runner: Self.recorded([:]), replies: Self.replies(repository, .replay))

    #expect(try Self.exitCode(replay) == 0)
    #expect(repository.data(DesignCalibrationLayout.recordPath) == Data(previous.utf8))
    let passed = Self.findings(replay).first { $0.ruleID == "calibrate-design.passed" }
    #expect(passed?.message.contains("replay of \(Self.keptRunID)") == true)
    #expect(passed?.message.contains("left untouched") == true)
  }

  @Test(
    "--replay takes a run id and refuses --model or a path — catches a replay claiming an override it never ran, or reading outside .harness/runs"
  )
  func replayOptionValidation() throws {
    let parsed = try CalibrateCommand.parseAsRoot(["design", "--replay", Self.keptRunID])
    #expect((parsed as? CalibrateDesignCommand)?.replay == Self.keptRunID)
    for arguments in [
      ["design", "--replay", Self.keptRunID, "--model", "haiku"],
      ["design", "--replay", "../elsewhere"],
    ] {
      #expect(throws: (any Error).self, "\(arguments)") {
        try CalibrateCommand.parseAsRoot(arguments)
      }
    }
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
    let agent = repository.root.appending(path: "plugin/agents/design-challenger.md")
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: agent.path)
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: agent.path)
    }
    let runner = Self.recorded(["TOKEN-A": "overstated", "TOKEN-B": "overstated"])

    let outcome = await Self.run(repository, runner: runner)

    #expect(try Self.exitCode(outcome) == 2)
    let reason = try #require(Self.blockedReason(outcome))
    #expect(reason.contains("plugin/agents/design-challenger.md"))
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
      "plugin/agents/design-claim-checker.md",
      "---\r\nname: design-claim-checker\r\ntools: Read\r\n---\r\n\r\nCRLF body.\r\n")
    try repository.write(
      "plugin/agents/design-challenger.md", "\nNo frontmatter here.\n---\nstill body\n")
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

  // MARK: - The judge

  /// A reviewer whose one case asks the judge the `tier` question the captured Jev reply answers.
  static func tierRepository() throws -> Repository {
    let repository = try Repository()
    try repository.agent("design-challenger", body: "You challenge options.", model: "opus")
    try repository.write("plugin/workflows/design-review.js", "export const steps = [];\n")
    try repository.seed(
      agent: "design-challenger", name: "tiered-test", token: "TOKEN-T",
      label: """
        {
          "schemaVersion": 2,
          "checks": [
            {
              "id": "tier",
              "kind": "judge",
              "text": "Which tier does the test the output proposes belong in?",
              "options": ["T1", "T2", "T3"],
              "expected": "T1"
            }
          ]
        }
        """)
    return repository
  }

  @Test(
    "--judge-backend jev --replay answers every judged label through Jev and runs no claude — catches a runner still bound to the Claude judge"
  )
  func jevJudgesAReplay() async throws {
    let repository = try Self.tierRepository()
    let kept = await Self.run(
      repository,
      runner: FakeProcessRunner { invocation throws(ProcessRunnerError) in
        guard !Self.isJudge(invocation) else {
          return ProcessOutput(status: .exited(1), stdout: "", stderr: "claude judged")
        }
        return ProcessOutput(
          status: .exited(0), stdout: Self.envelope(result: "Put it in the host unit tests."))
      }, replies: Self.replies(repository, .keep))
    #expect(try Self.exitCode(kept) == 2)
    let transport = FakeHTTPTransport([try FakeHTTPTransport.captured("test-quality")])
    let replayRunner = Self.recorded([:])
    let command = try #require(
      try CalibrateCommand.parseAsRoot([
        "design", "--judge-backend", "jev", "--replay", Self.keptRunID,
      ]) as? CalibrateDesignCommand)

    let replay = await CalibrateDesignRun.run(
      root: repository.root, runner: replayRunner, model: "sonnet", now: Self.passedAt,
      replies: Self.replies(repository, .replay),
      judge: command.judge(
        runner: replayRunner, transport: transport,
        environment: [JevPin.keyVariable: "test-key"]))

    #expect(try Self.exitCode(replay) == 0)
    #expect(replayRunner.invocations.isEmpty)
    #expect(transport.requests.count == 1)
    #expect(
      Self.findings(replay).contains {
        $0.ruleID == "calibrate-design.usage" && $0.message.contains("judged by jev/jev-1.13.0")
      })
  }

  @Test(
    "the judge flags build the named backend on its default model, and no flags build the shipped Claude judge — catches a flag that parses but never reaches the judge"
  )
  func judgeFlagsBuildTheirBackend() throws {
    func identity(_ arguments: [String]) throws -> JudgeIdentity {
      let command = try #require(
        try CalibrateCommand.parseAsRoot(["design"] + arguments) as? CalibrateDesignCommand)
      return command.judge(
        runner: Self.recorded([:]), transport: FakeHTTPTransport([]), environment: [:]
      ).identity
    }

    #expect(try identity([]) == JudgeIdentity(backend: "claude", model: "sonnet"))
    #expect(
      try identity(["--judge-backend", "jev"]) == JudgeIdentity(backend: "jev", model: "jev-1.13.0")
    )
    #expect(
      try identity(["--judge-backend", "claude", "--judge-model", "claude-sonnet-5-5"])
        == JudgeIdentity(backend: "claude", model: "claude-sonnet-5-5"))
  }

  @Test(
    "a full pass records its judge and the ids that served each agent and the judge — catches a record that keeps only the alias, so a moved alias passes unnoticed"
  )
  func passRecordsJudgeAndServedModels() async throws {
    let repository = try Repository.calibrated()
    try repository.judgedDrafter(expected: "unverified")

    let outcome = await Self.run(
      repository, runner: Self.recorded(["TOKEN-A": "overstated", "TOKEN-B": "overstated"]))

    #expect(try Self.exitCode(outcome) == 0)
    let record = try Self.recordJSON(repository)
    let judge = try #require(record["judge"] as? [String: Any])
    #expect(judge["backend"] as? String == "claude")
    #expect(judge["model"] as? String == "sonnet")
    #expect(judge["servedModels"] as? [String] == ["claude-haiku-4-5-20251001"])
    let cases = try #require(record["cases"] as? [[String: Any]])
    #expect(cases.count == 3)
    for recorded in cases {
      #expect(recorded["servedModels"] as? [String] == ["claude-haiku-4-5-20251001"])
    }
    let decoded = try CalibrationRecord.decode(
      try #require(repository.data(DesignCalibrationLayout.recordPath)))
    #expect(decoded.judge?.backend == .claude)
  }

  static func command(_ arguments: [String]) throws -> CalibrateDesignCommand {
    try #require(
      try CalibrateCommand.parseAsRoot(["design"] + arguments) as? CalibrateDesignCommand)
  }

  @Test(
    "--judge-backend jev with no host named, by flag or config, is refused with exit 2 saying what to add — catches replies sent to TypeSafe without the user naming it"
  )
  func jevWithoutHostIsRefused() throws {
    let command = try Self.command(["--judge-backend", "jev"])

    let refusal = try #require(command.egressRefusal(configuredJudge: nil))
    let claudeConfigured = command.egressRefusal(
      configuredJudge: .enabled(
        backend: .claude, thresholds: JudgeThresholds(advisory: 0.5, block: 0.9)))

    #expect(refusal.contains("--send-to api.typesafe.ai"))
    #expect(refusal.contains("send_to = \"api.typesafe.ai\""))
    #expect(claudeConfigured == refusal)
    #expect(try Self.exitCode(.blocked(reason: refusal)) == 2)
  }

  @Test(
    "--send-to naming a lookalike of TypeSafe's host is refused naming the only allowed host — catches a typo'd or hostile host passing as consent"
  )
  func lookalikeHostIsRefused() throws {
    for host in ["api.typesafe.ai.example.com", "typesafe.ai", "api.typesafe.al"] {
      let command = try Self.command(["--judge-backend", "jev", "--send-to", host])

      let refusal = command.egressRefusal(configuredJudge: nil)

      #expect(refusal?.contains("\"\(host)\" is not the host") == true, "\(host)")
      #expect(refusal?.contains("\"api.typesafe.ai\"") == true, "\(host)")
    }
  }

  @Test(
    "jev with --send-to api.typesafe.ai or a [judge] config naming it is accepted, and the Claude judge needs no host — catches consent given but refused"
  )
  func namedHostIsAccepted() throws {
    let flagged = try Self.command(["--judge-backend", "jev", "--send-to", "api.typesafe.ai"])
    let configured = try Self.command(["--judge-backend", "jev"])
    let claude = try Self.command([])

    #expect(flagged.egressRefusal(configuredJudge: nil) == nil)
    #expect(
      configured.egressRefusal(
        configuredJudge: .enabled(
          backend: .jev, thresholds: JudgeThresholds(advisory: 0.5, block: 0.9))) == nil)
    #expect(claude.egressRefusal(configuredJudge: nil) == nil)
    #expect(
      try Self.command(["--send-to", "api.typesafe.ai"]).egressRefusal(configuredJudge: nil)
        != nil)
  }
}
