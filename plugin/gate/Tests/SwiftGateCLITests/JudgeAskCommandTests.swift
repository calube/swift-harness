import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Synchronization
import Testing

@testable import SwiftGateCLI

@Suite("judge ask, and judge as a command group")
struct JudgeAskCommandTests {
  /// A judge whose every call reports the same usage, so the printed JSON is exact.
  struct MeasuredJudge: Judge {
    let identity = JudgeIdentity(backend: "claude", model: "claude-sonnet-5-5")
    let usage: JudgeUsage?

    func answer(_ subject: JudgeSubject, questions: JudgeQuestionSet) async throws(JudgeError)
      -> [JudgeAnswer]
    {
      questions.questions.map { question in
        let options = question.options
        // Each subject's first option gets a probability its id picks, so 2 subjects differ.
        let first = subject.id == "second" ? 0.25 : 0.75
        var distribution = [options[0]: first]
        for option in options.dropFirst() {
          distribution[option] = (1 - first) / Double(options.count - 1)
        }
        return JudgeAnswer(
          question: question.id, distribution: distribution,
          rationale: subject.id == "second" ? nil : "because")
      }
    }

    func measuredAnswer(_ subject: JudgeSubject, questions: JudgeQuestionSet)
      async throws(JudgeError) -> JudgeReply
    {
      JudgeReply(answers: try await answer(subject, questions: questions), usage: usage)
    }
  }

  static func question(
    _ id: String, kind: String = "binary", options: [String]? = nil, flag: String = "yes"
  ) -> [String: Any] {
    var question: [String: Any] = [
      "id": id, "text": "Is \(id) true?", "kind": kind, "flag": ["option": flag],
    ]
    if let options { question["options"] = options }
    return question
  }

  static func input(
    questions: [[String: Any]] = [question("claims-tests-pass")],
    subjects: [[String: Any]] = [["id": "first", "source": "final message", "context": "diff"]],
    edit: (inout [String: Any]) -> Void = { _ in }
  ) throws -> Data {
    var object: [String: Any] = [
      "schemaVersion": 1,
      "inlineQuestionSet": [
        "id": "guard-evasion", "version": 1, "subjectDescription": "an agent's session",
        "questions": questions,
      ],
      "subjects": subjects,
    ]
    edit(&object)
    return try JSONSerialization.data(withJSONObject: object)
  }

  static func refusal(_ result: Result<Data, JudgeAsk.Refusal>) -> JudgeAsk.Refusal? {
    guard case .failure(let refusal) = result else { return nil }
    return refusal
  }

  // MARK: - The old spelling

  /// The report with its run id and timings removed, which differ on every run.
  static func stable(_ data: Data) throws -> String {
    func strip(_ value: Any) -> Any {
      if let object = value as? [String: Any] {
        return object.filter { $0.key != "runID" && $0.key != "durationMilliseconds" }
          .mapValues(strip)
      }
      if let array = value as? [Any] { return array.map(strip) }
      return value
    }
    let object = strip(try JSONSerialization.jsonObject(with: data))
    return String(
      decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
      as: UTF8.self)
  }

  static func swiftgate(
    _ arguments: [String], in root: URL, input: Data? = nil, path: String? = nil
  ) async throws -> ProcessOutput {
    var overlay: [String: String?] = [
      "LLVM_PROFILE_FILE": root.appending(path: "swiftgate-%p.profraw").path,
      JudgeBackend.jev.keyVariable ?? "": nil,
    ]
    if let path { overlay["PATH"] = path }
    return try await LiveProcessRunner().run(
      ProcessInvocation(
        executable: Fixture.gateDirectory.appending(path: ".build/debug/swiftgate").path,
        arguments: arguments, environmentOverlay: overlay, workingDirectory: root.path,
        standardInput: input, timeout: .seconds(120)))
  }

  @Test(
    "swiftgate judge and judge --ready print the same report and exit status as judge tests, as before the group — catches a group that breaks the old spelling"
  )
  func oldSpellingRunsTheTestQualityCheck() async throws {
    let parsed = try SwiftGate.parseAsRoot(["judge", "--ready", "--base", "main"])
    let tests = try #require(parsed as? JudgeTestsCommand)
    #expect(tests.ready)
    #expect(tests.base == "main")

    let unconfigured = try ProbeRepository(config: nil)
    defer { unconfigured.remove() }
    let disabled = try ProbeRepository()
    defer { disabled.remove() }
    // What `swiftgate judge --json` printed before it became a group.
    let expected = [
      unconfigured.root: (
        status: ExitStatus.exited(1),
        report:
          #"{"allowances":[],"findings":[{"failureScenario":null,"file":".","line":null,"message":"no .swiftgate.toml","rule":"swiftgate.config","severity":"major"}],"schemaVersion":1,"tiers":[{"testCounts":null,"tier":"T0","verdict":"RED"}],"verdict":"RED"}"#
      ),
      disabled.root: (
        status: ExitStatus.exited(0),
        report:
          #"{"allowances":[],"findings":[],"schemaVersion":1,"tiers":[{"testCounts":null,"tier":"T0","verdict":"GREEN"}],"verdict":"GREEN"}"#
      ),
    ]
    for (root, want) in expected {
      for arguments in [
        ["judge", "--json"], ["judge", "--ready", "--json"], ["judge", "tests", "--json"],
        ["judge", "tests", "--ready", "--json"],
      ] {
        let output = try await Self.swiftgate(arguments, in: root)
        #expect(output.status == want.status, "\(arguments): \(output.stderr.text)")
        #expect(try Self.stable(output.stdout.bytes) == want.report, "\(arguments)")
      }
    }
  }

  // MARK: - Input

  @Test(
    "an input with a duplicate question id exits 2 naming it and asks nothing — catches 2 answers under 1 id, where the second silently overwrites the first"
  )
  func duplicateQuestionID() async throws {
    let judge = FakeJudge.answering(flagged: 0.9)
    let result = await JudgeAsk.answer(
      try Self.input(questions: [Self.question("clause"), Self.question("clause")]),
      judge: judge, secrets: [])

    let refusal = try #require(Self.refusal(result))
    #expect(refusal.status == JudgeAsk.badInputStatus)
    #expect(refusal.message.contains("`clause`"), "\(refusal.message)")
    #expect(refusal.message.contains("inlineQuestionSet.questions"), "\(refusal.message)")
    #expect(judge.subjects.isEmpty)
  }

  enum Malformed: String, CaseIterable, Sendable {
    case duplicateSubject, noSubjects, unknownKind, emptyOptions, elevenScoreLevels
    case twoHundredFiftySixChoices, unknownSubjectKey, schemaTwo, bothQuestionSets, notJSON

    /// The start of the refusal's message: the field at fault.
    var field: String {
      switch self {
      case .duplicateSubject: "subjects[1].id"
      case .noSubjects: "subjects"
      case .unknownKind: "inlineQuestionSet"
      case .emptyOptions: "inlineQuestionSet.questions[0]"
      case .elevenScoreLevels, .twoHundredFiftySixChoices: "inlineQuestionSet.questions[0].options"
      case .unknownSubjectKey: "subjects[0]"
      case .schemaTwo: "schemaVersion"
      case .bothQuestionSets: "questionSet"
      case .notJSON: "input"
      }
    }

    func data() throws -> Data {
      typealias T = JudgeAskCommandTests
      switch self {
      case .duplicateSubject:
        return try T.input(subjects: [
          ["id": "same", "source": "a", "context": "b"],
          ["id": "same", "source": "c", "context": "d"],
        ])
      case .noSubjects: return try T.input(subjects: [])
      case .unknownKind: return try T.input(questions: [T.question("q", kind: "scale")])
      case .emptyOptions:
        return try T.input(questions: [T.question("q", kind: "choice", options: [], flag: "a")])
      case .elevenScoreLevels:
        return try T.input(questions: [
          T.question("q", kind: "score", options: (0...10).map { "level \($0)" }, flag: "level 0")
        ])
      case .twoHundredFiftySixChoices:
        return try T.input(questions: [
          T.question(
            "q", kind: "choice", options: (0...255).map { "option \($0)" }, flag: "option 0")
        ])
      case .unknownSubjectKey:
        return try T.input(subjects: [["id": "s", "source": "a", "context": "b", "tier": "T1"]])
      case .schemaTwo: return try T.input { $0["schemaVersion"] = 2 }
      case .bothQuestionSets: return try T.input { $0["questionSet"] = "test-quality@1" }
      case .notJSON: return Data("not json".utf8)
      }
    }
  }

  @Test(
    "each malformed input exits 2 naming the field at fault — catches an input the backend would get half of",
    arguments: Malformed.allCases)
  func malformedInput(_ malformed: Malformed) async throws {
    let (name, field) = (malformed.rawValue, malformed.field)
    let make = malformed.data
    let judge = FakeJudge.answering(flagged: 0.9)
    let result = await JudgeAsk.answer(try make(), judge: judge, secrets: [])
    let refusal = try #require(Self.refusal(result), "\(name) was answered")
    #expect(refusal.status == JudgeAsk.badInputStatus, "\(name)")
    #expect(refusal.message.hasPrefix(field), "\(name): \(refusal.message)")
    #expect(judge.subjects.isEmpty, "\(name)")
  }

  @Test(
    "10 score levels, 255 choice options and a built-in set named by id are all answered — catches a limit off by 1 that refuses a set Jev accepts"
  )
  func limitsAreInclusive() async throws {
    let score = Self.question(
      "graded", kind: "score", options: (0..<10).map { "level \($0)" }, flag: "level 0")
    let choice = Self.question(
      "picked", kind: "choice", options: (0..<255).map { "option \($0)" }, flag: "option 0")
    let inline = await JudgeAsk.answer(
      try Self.input(questions: [score, choice]), judge: FakeJudge.answering(flagged: 0.9),
      secrets: [])
    #expect(Self.refusal(inline) == nil)

    let judge = FakeJudge.answering(flagged: 0.9)
    let named = await JudgeAsk.answer(
      try Self.input {
        $0["inlineQuestionSet"] = nil
        $0["questionSet"] = "test-quality@1"
      }, judge: judge, secrets: [])
    let output = try JSONSerialization.jsonObject(with: try named.get()) as? [String: Any]
    #expect(output?["questionSet"] as? String == "test-quality@1")
    #expect(judge.subjects.map(\.id) == ["first"])
  }

  // MARK: - Output

  @Test(
    "a 2-subject input prints both subjects' distributions and usage in input order under schemaVersion 1 — catches a subject dropped or answers printed without their cost"
  )
  func printsEverySubject() async throws {
    let judge = MeasuredJudge(
      usage: JudgeUsage(
        inputTokens: 120, outputTokens: 8, costUSD: 0.5, wallMilliseconds: 900,
        backendMilliseconds: 700, servedModel: "claude-sonnet-5-5"))
    let data = try Self.input(
      questions: [Self.question("claims-tests-pass")],
      subjects: [
        ["id": "second", "source": "b", "context": "y"],
        ["id": "first", "source": "a", "context": "x", "declaredTier": "T1"],
      ])

    let printed = try await JudgeAsk.answer(data, judge: judge, secrets: []).get()

    let usage =
      #"{"backendMilliseconds":700,"cached":false,"costUSD":0.5,"inputTokens":120,"outputTokens":8,"servedModel":"claude-sonnet-5-5","wallMilliseconds":900}"#
    #expect(
      String(decoding: printed, as: UTF8.self) == """
        {"identity":{"backend":"claude","model":"claude-sonnet-5-5"},"questionSet":"guard-evasion@1",\
        "schemaVersion":1,"subjects":[\
        {"answers":[{"distribution":{"no":0.75,"yes":0.25},"question":"claims-tests-pass"}],\
        "id":"second","usage":\(usage)},\
        {"answers":[{"distribution":{"no":0.25,"yes":0.75},"question":"claims-tests-pass",\
        "rationale":"because"}],"id":"first","usage":\(usage)}]}
        """)
  }

  @Test(
    "a backend that reports no usage prints usage as null — catches a missing cost read as free"
  )
  func missingUsageIsNull() async throws {
    let printed = try await JudgeAsk.answer(
      try Self.input(), judge: MeasuredJudge(usage: nil), secrets: []
    ).get()
    let object = try JSONSerialization.jsonObject(with: printed) as? [String: Any]
    let subject = try #require((object?["subjects"] as? [[String: Any]])?.first)
    #expect(subject.keys.contains("usage"))
    #expect(subject["usage"] is NSNull)
  }

  @Test(
    "a backend failure exits 3 with the error and never the key — catches a failed ask exiting 0 with no answers, or echoing the key"
  )
  func backendFailure() async throws {
    let judge = FakeJudge { _, _ throws(JudgeError) in
      throw .backend("401 for key sk-secret-value")
    }
    let result = await JudgeAsk.answer(
      try Self.input(), judge: judge, secrets: ["sk-secret-value"])

    let refusal = try #require(Self.refusal(result))
    #expect(refusal.status == JudgeAsk.backendFailedStatus)
    #expect(refusal.message.contains("401"), "\(refusal.message)")
    #expect(!refusal.message.contains("sk-secret-value"))
  }

  @Test(
    "answers are cached unless --no-cache — catches every eval run paying for the same answers again"
  )
  func cacheUnlessNoCache() async throws {
    let repository = try ProbeRepository(config: nil)
    defer { repository.remove() }
    let data = try Self.input()
    for (noCache, calls) in [(false, 1), (true, 2)] {
      let judge = FakeJudge.answering(flagged: 0.9)
      for _ in 0..<2 {
        let asked = JudgeAsk.caching(
          judge, root: repository.root.appending(path: "cache-\(noCache)"), noCache: noCache)
        _ = try await JudgeAsk.answer(data, judge: asked, secrets: []).get()
      }
      #expect(judge.subjects.count == calls, "--no-cache \(noCache)")
    }
  }

  // MARK: - Backend and egress

  static func config(_ judge: String) throws -> Result<Config?, StaticCheckInputs.ConfigFailure> {
    let repository = try ProbeRepository(config: ProbeRepository.config + "\n" + judge)
    defer { repository.remove() }
    return StaticCheckInputs.loadConfig(root: repository.root)
  }

  static let claudeConfig = """
    [judge]
    backend = "claude"
    advisory_threshold = 0.6
    block_threshold = 0.9
    model = "claude-sonnet-5-5"
    """

  @Test(
    "--backend jev in a repository whose config doesn't name the host exits 2 naming send_to, and naming the host lets it through — catches ask sending state to a new third party without the opt-in"
  )
  func jevNeedsTheHost() throws {
    let refused = JudgeAsk.choose(
      backend: .jev, model: nil, sendTo: nil, config: try Self.config(Self.claudeConfig))
    guard case .failure(let refusal) = refused else {
      Issue.record("jev without send_to was chosen: \(refused)")
      return
    }
    #expect(refusal.status == JudgeAsk.badInputStatus)
    #expect(refusal.message.contains("send_to"), "\(refusal.message)")
    #expect(refusal.message.contains("--send-to api.typesafe.ai"), "\(refusal.message)")

    let wrongHost = JudgeAsk.choose(
      backend: .jev, model: nil, sendTo: "api.example.com", config: .success(nil))
    #expect((try? wrongHost.get()) == nil)

    let named = JudgeAsk.choose(
      backend: .jev, model: nil, sendTo: "api.typesafe.ai", config: .success(nil))
    #expect(try named.get() == JudgeAsk.Choice(backend: .jev, model: "jev-1.13.0"))

    let configured = JudgeAsk.choose(
      backend: nil, model: nil, sendTo: nil,
      config: try Self.config(
        """
        [judge]
        backend = "jev"
        send_to = "api.typesafe.ai"
        advisory_threshold = 0.6
        block_threshold = 0.9
        """))
    #expect(try configured.get() == JudgeAsk.Choice(backend: .jev, model: "jev-1.13.0"))
  }

  @Test(
    "the backend and model come from the flags over the config, and the config's model only for its own backend — catches a Claude model id sent to Jev"
  )
  func choosesBackendAndModel() throws {
    let config = try Self.config(Self.claudeConfig)
    #expect(
      try JudgeAsk.choose(backend: nil, model: nil, sendTo: nil, config: config).get()
        == JudgeAsk.Choice(backend: .claude, model: "claude-sonnet-5-5"))
    #expect(
      try JudgeAsk.choose(backend: nil, model: "opus", sendTo: nil, config: config).get()
        == JudgeAsk.Choice(backend: .claude, model: "opus"))
    #expect(
      try JudgeAsk.choose(
        backend: .jev, model: nil, sendTo: "api.typesafe.ai", config: config
      ).get() == JudgeAsk.Choice(backend: .jev, model: "jev-1.13.0"))
    #expect(
      try JudgeAsk.choose(backend: .claude, model: nil, sendTo: nil, config: .success(nil)).get()
        == JudgeAsk.Choice(backend: .claude, model: JudgeFactory.defaultModel))
  }

  @Test(
    "no backend anywhere, an unpinned Jev model, a host for a local backend or a broken config exits 2 — catches ask guessing a backend or a moving model"
  )
  func refusesWhatItCantUse() throws {
    let cases: [(String, Result<JudgeAsk.Choice, JudgeAsk.Refusal>, String)] = [
      (
        "no backend",
        JudgeAsk.choose(backend: nil, model: nil, sendTo: nil, config: .success(nil)),
        "--backend"
      ),
      (
        "a disabled judge",
        JudgeAsk.choose(
          backend: nil, model: nil, sendTo: nil, config: try Self.config("")),
        "--backend"
      ),
      (
        "an alias",
        JudgeAsk.choose(
          backend: .jev, model: "jev-latest", sendTo: "api.typesafe.ai", config: .success(nil)),
        "jev-1.13.0"
      ),
      (
        "a host for claude",
        JudgeAsk.choose(
          backend: .claude, model: nil, sendTo: "api.typesafe.ai", config: .success(nil)),
        "--send-to"
      ),
      (
        "a broken config",
        JudgeAsk.choose(
          backend: .claude, model: nil, sendTo: nil,
          config: try Self.config("[judge]\nbackend = \"gpt\"")),
        "backend"
      ),
    ]
    for (name, result, named) in cases {
      guard case .failure(let refusal) = result else {
        Issue.record("\(name) was chosen: \(result)")
        continue
      }
      #expect(refusal.status == JudgeAsk.badInputStatus, "\(name)")
      #expect(refusal.message.contains(named), "\(name): \(refusal.message)")
    }
  }

  // MARK: - The binary

  @Test(
    "the built command reads standard input and exits 2 for bad input or a refused host and 3 when claude fails — catches exit statuses that only hold in process"
  )
  func exitStatuses() async throws {
    let repository = try ProbeRepository()
    defer { repository.remove() }
    let bin = repository.root.appending(path: "fake-bin", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    let claude = bin.appending(path: "claude")
    try Data("#!/bin/bash\ncat > /dev/null\necho 'overloaded' >&2\nexit 1\n".utf8).write(to: claude)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claude.path)
    let path = "\(bin.path):/usr/bin:/bin"
    let input = try Self.input()
    try input.write(to: repository.root.appending(path: "input.json"))

    let bad = try await Self.swiftgate(
      ["judge", "ask", "--input", "-", "--backend", "claude"], in: repository.root,
      input: Data("{}".utf8), path: path)
    #expect(bad.status == .exited(2), "\(bad.stderr.text)")
    #expect(bad.stdout.bytes.isEmpty)

    let egress = try await Self.swiftgate(
      ["judge", "ask", "--input", "input.json", "--backend", "jev"], in: repository.root,
      path: path)
    #expect(egress.status == .exited(2), "\(egress.stderr.text)")
    #expect(egress.stderr.text.contains("send_to"), "\(egress.stderr.text)")

    let failed = try await Self.swiftgate(
      ["judge", "ask", "--input", "-", "--backend", "claude", "--no-cache"],
      in: repository.root, input: input, path: path)
    #expect(failed.status == .exited(3), "\(failed.stderr.text)")
    #expect(failed.stdout.bytes.isEmpty)
  }
}
