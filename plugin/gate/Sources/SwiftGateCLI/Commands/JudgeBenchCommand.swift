import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain

/// `swiftgate judge bench` and `bench-render` (design §10.6): measure backends on a labelled
/// dataset with no cache, 1 request at a time, and render the comparison from the raw answers.
enum JudgeBench {
  static let metricsDifferStatus: Int32 = 1
  static let badInputStatus: Int32 = 2
  static let backendFailedStatus: Int32 = 3
  /// The built-in comment set, relative to the harness root.
  static let commentsDirectory = "gate/Fixtures/judge-comments"

  /// Why nothing was measured or rendered, and the exit status that says so.
  struct Refusal: Error, Equatable {
    let status: Int32
    let message: String
  }

  /// The flags as given.
  struct Options: Equatable {
    var dataset: String
    var arms: [String]
    var repeats = JudgeBenchmarkMetrics.minimumRepeats
    var concurrency = 1
    var threshold = JudgeCalibration.decisionThreshold
    var cases: [String] = []
    var smoke = false
    var sendTo: String?
  }

  /// What a run will ask: the dataset, its cases, and each arm with the set it asks.
  struct Plan: Sendable {
    let dataset: JudgeDataset
    let cases: [JudgeDatasetCase]
    let arms: [(arm: JudgeBenchmarkArm, questions: JudgeQuestionSet)]
    let repeats: Int
    let concurrency: Int
    let threshold: Double
    let purpose: JudgeBenchmarkPurpose

    /// The questions each case is asked, in case order.
    var judgments: [Int] {
      cases.map { dataset.labels(of: $0)?.expected.count ?? 0 }
    }
  }

  private static func refuse<Value>(_ message: String) -> Result<Value, Refusal> {
    .failure(Refusal(status: badInputStatus, message: message))
  }

  /// Validates the options and loads the dataset. `configNamesHost` is true when the
  /// repository's `[judge]` config has already named the Jev host.
  static func plan(
    _ options: Options, root: URL, harnessRoot: URL?, configNamesHost: Bool,
    environment: [String: String]
  ) -> Result<Plan, Refusal> {
    guard !options.arms.isEmpty else {
      return refuse("name at least 1 --backend <backend>:<model>, such as claude:claude-sonnet-5-5")
    }
    guard options.repeats >= 1 else { return refuse("--repeats \(options.repeats): at least 1") }
    if options.repeats < JudgeBenchmarkMetrics.minimumRepeats, !options.smoke {
      return refuse(
        "--repeats \(options.repeats): a benchmark needs at least "
          + "\(JudgeBenchmarkMetrics.minimumRepeats) repeats to measure stability; --smoke with "
          + "--case runs fewer over named cases")
    }
    if options.smoke, options.cases.isEmpty {
      return refuse("--smoke needs at least 1 --case <id>: a smoke run asks named cases only")
    }
    guard options.concurrency >= 1 else {
      return refuse("--concurrency \(options.concurrency): at least 1")
    }
    guard (0...1).contains(options.threshold) else {
      return refuse("--threshold \(options.threshold): a probability from 0 to 1")
    }
    var arms: [JudgeBenchmarkArm] = []
    for text in options.arms {
      do throws(JudgeBenchmarkArmError) {
        let arm = try JudgeBenchmarkArm.parse(text)
        guard !arms.contains(arm) else { return refuse("--backend \(text) is named twice") }
        arms.append(arm)
      } catch {
        return refuse("\(error)")
      }
    }
    if let host = arms.lazy.compactMap(\.backend.egressHost).first {
      if !(configNamesHost && options.sendTo == nil),
        let issue = JudgeBackend.jev.egressIssue(sendTo: options.sendTo, path: "--send-to")
      {
        return refuse("\(issue), or pass --send-to \(host)")
      }
    } else if let issue = JudgeBackend.claude.egressIssue(
      sendTo: options.sendTo, path: "--send-to")
    {
      return refuse("\(issue)")
    }
    let dataset: JudgeDataset
    switch Self.dataset(options.dataset, root: root, harnessRoot: harnessRoot) {
    case .failure(let refusal): return .failure(refusal)
    case .success(let found): dataset = found
    }
    var cases = dataset.cases.filter { dataset.labels(of: $0) != nil }
    if !options.cases.isEmpty {
      let known = Set(cases.map(\.id))
      if let unknown = options.cases.first(where: { !known.contains($0) }) {
        return refuse(
          "--case \(unknown): no case with that id has \(dataset.labelsVersion) labels in "
            + "\(dataset.id)")
      }
      let wanted = Set(options.cases)
      cases = cases.filter { wanted.contains($0.id) }
    }
    guard !cases.isEmpty else {
      return refuse("\(dataset.id) has no case labelled for \(dataset.labelsVersion)")
    }
    var asked: [(arm: JudgeBenchmarkArm, questions: JudgeQuestionSet)] = []
    for arm in arms {
      do throws(JudgeBenchmarkArmError) {
        asked.append((arm, try arm.questions(for: dataset)))
      } catch {
        return refuse("\(error)")
      }
    }
    return .success(
      Plan(
        dataset: dataset, cases: cases, arms: asked, repeats: options.repeats,
        concurrency: options.concurrency, threshold: options.threshold,
        purpose: options.smoke ? .smoke : .benchmark))
  }

  /// Why a remote arm can't reach its backend: its key isn't set.
  static func missingKey(_ plan: Plan, environment: [String: String]) -> Refusal? {
    for (arm, _) in plan.arms {
      guard let variable = arm.backend.keyVariable else { continue }
      if environment[variable]?.isEmpty ?? true {
        return Refusal(
          status: badInputStatus,
          message: "--backend \(arm): set \(variable) to reach \(arm.backend.rawValue)")
      }
    }
    return nil
  }

  /// A dataset by path, or by id: `test-quality`, `comments` or `calibrate-design:<run id>`.
  static func dataset(_ spec: String, root: URL, harnessRoot: URL?) -> Result<
    JudgeDataset, Refusal
  > {
    let prefix = JudgeDatasetLoader.storedRepliesQuestionSetID + ":"
    let builtIns = [JudgeDatasetLoader.testQualityID, "comments"]
    if builtIns.contains(spec), harnessRoot == nil {
      return refuse(
        "--dataset \(spec): set \(SelfTestCommand.harnessRootVariable) to load a built-in set; "
          + "bin/swiftgate sets it")
    }
    do throws(JudgeDatasetError) {
      if let harnessRoot, spec == JudgeDatasetLoader.testQualityID {
        return .success(try JudgeDatasetLoader.testQuality(harnessRoot: harnessRoot))
      }
      if let harnessRoot, spec == "comments" {
        return .success(
          try JudgeDatasetLoader.directory(
            harnessRoot.appending(path: commentsDirectory, directoryHint: .isDirectory), id: spec))
      }
      if spec.hasPrefix(prefix) {
        return .success(
          try JudgeDatasetLoader.storedReplies(
            root: root, runID: String(spec.dropFirst(prefix.count))))
      }
      let url = URL(filePath: spec, relativeTo: root)
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
        return refuse("--dataset \(spec): no such file or directory, and not a built-in id")
      }
      return .success(
        isDirectory.boolValue
          ? try JudgeDatasetLoader.directory(url, id: url.lastPathComponent)
          : try JudgeDatasetLoader.file(url))
    } catch {
      return refuse("--dataset \(spec): \(error)")
    }
  }

  /// The arm's judge at its model, never behind the answer cache. A cascade arm's Claude
  /// answers from the set `questions` is based on.
  static func liveJudge(
    _ arm: JudgeBenchmarkArm, runner: any ProcessRunner, environment: [String: String],
    questions: JudgeQuestionSet = .testsJev
  ) -> any Judge {
    let claude = { (model: String) in
      ClaudeCLIJudge(runner: KeylessProcessRunner(inner: runner), model: model)
    }
    let single: any Judge =
      switch arm.backend {
      case .claude: claude(arm.model)
      case .jev:
        JevJudge(model: arm.model, transport: URLSessionTransport(), environment: environment)
      }
    guard let claudeModel = arm.claudeModel else { return single }
    // Escalation reads only the band; the thresholds don't change which questions go to Claude.
    return CascadingJudge(
      jev: single, claude: claude(claudeModel), base: JudgeBenchmarkArm.base(of: questions),
      policy: CascadingJudge.Policy(
        thresholds: JudgeThresholds(advisory: 0, block: 1), atReadyTier: true))
  }

  /// Asks every case of `plan` through `judges` (1 per arm, in arm order) `plan.repeats` times,
  /// and builds the result. A served model that changes mid-run fails it.
  static func run(_ plan: Plan, judges: [any Judge], startedAt: Date) async -> Result<
    JudgeBenchmarkReport, Refusal
  > {
    guard judges.count == plan.arms.count else {
      return refuse("\(judges.count) judges for \(plan.arms.count) arms")
    }
    func failed(_ message: String) -> Result<JudgeBenchmarkReport, Refusal> {
      .failure(Refusal(status: backendFailedStatus, message: message))
    }
    var answered = Array(repeating: [[String: [JudgeBenchmarkReply]]](), count: judges.count)
    var served = [String?](repeating: nil, count: judges.count)
    // Arms take turns within each repeat, so drift over the run touches every arm alike.
    for repeatIndex in 0..<plan.repeats {
      for (index, entry) in plan.arms.enumerated() {
        let replies: [String: [JudgeBenchmarkReply]]
        switch await answer(plan, questions: entry.questions, judge: judges[index]) {
        case .failure(let failure):
          return failed(
            "\(entry.arm) on case \(failure.caseID), repeat \(repeatIndex + 1): \(failure.reason)")
        case .success(let found): replies = found
        }
        for item in plan.cases {
          // A cascade's Claude reply comes first and names its escalations; Jev's is the arm's.
          guard
            let model = replies[item.id]?.last(where: { $0.escalations == nil })?.usage?
              .servedModel
          else { continue }
          if let first = served[index], first != model {
            return failed(
              "\(entry.arm): the served model changed from \(first) to \(model) at repeat "
                + "\(repeatIndex + 1), case \(item.id); 1 result can't mix 2 models")
          }
          served[index] = model
        }
        answered[index].append(replies)
      }
    }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    let arms = plan.arms.indices.map { index in
      let (arm, questions) = plan.arms[index]
      return JudgeBenchmarkArmResult(
        arm: arm.description,
        identity: JudgeBenchmarkIdentity(
          backend: arm.backendName, requestedModel: arm.requestedModel,
          servedModel: served[index]),
        questionSet: questions.versionedID, labelsVersion: questions.labelsVersion,
        repeats: answered[index])
    }
    return .success(
      JudgeBenchmarkReport(
        swiftgateVersion: SwiftGateVersion.current, startedAt: formatter.string(from: startedAt),
        purpose: plan.purpose, dataset: plan.dataset.summary,
        questions: plan.dataset.questions.questions.filter { question in
          plan.cases.contains { plan.dataset.labels(of: $0)?.expected[question.id] != nil }
        },
        cases: plan.cases.compactMap { item in
          plan.dataset.labels(of: item).map {
            JudgeBenchmarkLabelledCase(
              id: item.id, labeller: $0.labeller, declaredTier: item.declaredTier,
              expected: $0.expected)
          }
        }, threshold: plan.threshold, repeats: plan.repeats, arms: arms))
  }

  struct CaseFailure: Error {
    let caseID: String
    let reason: String
  }

  /// 1 request per case, at most `plan.concurrency` at a time; the first failure fails them all.
  /// A cascade's case holds Claude's reply, when a question escalated, before Jev's, so the
  /// merged answer is the first per question.
  static func answer(_ plan: Plan, questions: JudgeQuestionSet, judge: any Judge) async -> Result<
    [String: [JudgeBenchmarkReply]], CaseFailure
  > {
    let version = plan.dataset.labelsVersion
    return await withTaskGroup(of: (String, Result<[JudgeBenchmarkReply], CaseFailure>).self) {
      group in
      var pending = plan.cases[...]
      var replies: [String: [JudgeBenchmarkReply]] = [:]
      var failure: CaseFailure?
      func enqueue() {
        guard let item = pending.popFirst() else { return }
        let asked = JudgeBenchmarkArm.questions(questions, for: item, labelsVersion: version)
        let subject = JudgeSubject(
          id: item.id, file: item.id, line: 1, source: item.source, context: item.context,
          declaredTier: item.declaredTier)
        group.addTask {
          func failure(_ reason: String) -> (String, Result<[JudgeBenchmarkReply], CaseFailure>) {
            (item.id, .failure(CaseFailure(caseID: item.id, reason: reason)))
          }
          do throws(JudgeError) {
            let answers: [JudgeAnswer]
            let found: [JudgeBenchmarkReply]
            if let cascade = judge as? CascadingJudge {
              let reply = try await cascade.cascade(subject, questions: asked)
              if case .failed(let why) = reply.claude { return failure("escalation: \(why)") }
              var escalated = reply.claudeReply.map(JudgeBenchmarkReply.init)
              escalated?.escalations = reply.plan.escalations
              answers = reply.decided.map(\.answer)
              found = (escalated.map { [$0] } ?? []) + [JudgeBenchmarkReply(reply.jev)]
            } else {
              let reply = try await judge.measuredAnswer(subject, questions: asked)
              answers = reply.answers
              found = [JudgeBenchmarkReply(reply)]
            }
            do throws(JudgeAnswerViolation) {
              _ = try JudgeAnswers.validate(answers, for: asked)
            } catch {
              return failure("\(error)")
            }
            return (item.id, .success(found))
          } catch {
            return failure("\(error)")
          }
        }
      }
      for _ in 0..<plan.concurrency { enqueue() }
      for await (id, result) in group {
        switch result {
        case .success(let reply): replies[id] = reply
        case .failure(let error): failure = failure ?? error
        }
        if failure == nil { enqueue() }
      }
      if let failure { return .failure(failure) }
      return .success(replies)
    }
  }

  /// Recomputes a result's metrics and renders its page, refusing edited metrics.
  static func render(_ data: Data) -> Result<String, Refusal> {
    do throws(JudgeBenchmarkReportError) {
      let report = try JudgeBenchmarkReport.decode(data)
      try report.verify()
      return .success(report.markdown)
    } catch {
      if case .metricsDiffer = error {
        return .failure(Refusal(status: metricsDifferStatus, message: "\(error)"))
      }
      return refuse("\(error)")
    }
  }
}

extension JudgeDataset {
  /// `item`'s labels for this dataset's question set.
  func labels(of item: JudgeDatasetCase) -> JudgeDatasetLabel? { item.labels[labelsVersion] }
}

struct JudgeBenchCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "bench",
    abstract: "Measure judge backends on a labelled dataset and write the raw answers and metrics.",
    discussion:
      "Each --backend is <backend>:<model>, with a pinned model, optionally followed by "
      + "#<set id>@<version> to ask a built-in set that reads the dataset's labels, such as "
      + "jev:jev-1.13.0#test-quality@2-jev. cascade:<jev model>,<claude model> asks Jev the "
      + "set rendered for it, then Claude the blocking questions Jev's answer leaves in its "
      + "uncertain band; its cost per case sums both, and the result names each case's "
      + "escalations. Every case is asked with no cache, 1 request at a "
      + "time by default, --repeats times (at least 3). --estimate counts the calls and prices "
      + "each arm from --usage-from files (a bench result or a judge recording) and calls "
      + "nothing. A Jev arm sends each case to api.typesafe.ai: pass --send-to api.typesafe.ai "
      + "and set TYPESAFE_API_KEY. --smoke with --case asks a few named cases with fewer "
      + "repeats. Exit 0 written, 2 for a bad flag, dataset, host or key, 3 when a backend "
      + "fails or its served model changes mid-run.")

  @Option(
    help: ArgumentHelp(
      "A dataset file or directory, or test-quality, comments or calibrate-design:<run id>.",
      valueName: "path|id"))
  var dataset: String

  @Option(
    name: .customLong("backend"),
    help: ArgumentHelp(
      "An arm; repeat for each arm.",
      valueName: "backend:model[#set@version]|cascade:jev-model,claude-model"))
  var arms: [String] = []

  @Option(help: "How many times each arm answers every case.")
  var repeats = JudgeBenchmarkMetrics.minimumRepeats

  @Option(help: "Requests in flight per arm; the committed benchmark uses 1.")
  var concurrency = 1

  @Option(help: "The flagged probability at which an answer counts as a finding.")
  var threshold = JudgeCalibration.decisionThreshold

  @Option(name: .customLong("case"), help: "Ask only this case; repeat for each.")
  var cases: [String] = []

  @Flag(help: "A smoke run: allows fewer than 3 repeats over the --case ids, and says so.")
  var smoke = false

  @Option(help: ArgumentHelp("The host a Jev arm may send cases to.", valueName: "host"))
  var sendTo: String?

  @Flag(help: "Count the calls and estimate the spend; call nothing.")
  var estimate = false

  @Option(
    name: .customLong("usage-from"),
    help: ArgumentHelp(
      "A bench result or judge recording whose usage prices the estimate.", valueName: "file"))
  var usageFrom: [String] = []

  @Option(help: ArgumentHelp("Where to write the result JSON.", valueName: "file"))
  var out: String?

  func run() async throws {
    let root = URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
    let environment = ProcessInfo.processInfo.environment
    var configNamesHost = false
    if case .success(let config?) = StaticCheckInputs.loadConfig(root: root),
      case .enabled(let backend, _, _) = config.judge, backend.egressHost != nil
    {
      configNamesHost = true
    }
    var options = JudgeBench.Options(dataset: dataset, arms: arms)
    options.repeats = repeats
    options.concurrency = concurrency
    options.threshold = threshold
    options.cases = cases
    options.smoke = smoke
    options.sendTo = sendTo
    let plan: JudgeBench.Plan
    switch JudgeBench.plan(
      options, root: root,
      harnessRoot: environment[SelfTestCommand.harnessRootVariable].map {
        URL(filePath: $0, directoryHint: .isDirectory)
      }, configNamesHost: configNamesHost, environment: environment)
    {
    case .failure(let refusal): throw Self.fail(refusal, environment: environment)
    case .success(let found): plan = found
    }
    if estimate {
      var recorded: [JudgeBenchmarkEstimate.Recorded] = []
      for path in usageFrom {
        do {
          let data = try Data(contentsOf: URL(filePath: path, relativeTo: root))
          recorded += try JudgeBenchmarkEstimate.recorded(from: data, source: path)
        } catch {
          throw Self.fail(
            JudgeBench.Refusal(
              status: JudgeBench.badInputStatus, message: "--usage-from \(path): \(error)"),
            environment: environment)
        }
      }
      Console.write(
        JudgeBenchmarkEstimate.make(
          arms: plan.arms.map(\.arm), judgments: plan.judgments, repeats: plan.repeats,
          recorded: recorded
        ).text)
      return
    }
    guard let out else {
      throw Self.fail(
        JudgeBench.Refusal(
          status: JudgeBench.badInputStatus, message: "--out <file> is required unless --estimate"),
        environment: environment)
    }
    if let refusal = JudgeBench.missingKey(plan, environment: environment) {
      throw Self.fail(refusal, environment: environment)
    }
    let runner = LiveProcessRunner()
    let judges = plan.arms.map {
      JudgeBench.liveJudge(
        $0.arm, runner: runner, environment: environment, questions: $0.questions)
    }
    let report: JudgeBenchmarkReport
    switch await JudgeBench.run(plan, judges: judges, startedAt: Date()) {
    case .failure(let refusal): throw Self.fail(refusal, environment: environment)
    case .success(let found): report = found
    }
    let url = URL(filePath: out, relativeTo: root)
    do {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try report.json.write(to: url)
    } catch {
      throw Self.fail(
        JudgeBench.Refusal(
          status: JudgeBench.badInputStatus, message: "--out \(out): can't write: \(error)"),
        environment: environment)
    }
    Console.write(
      "wrote \(out): \(plan.arms.count) arms × \(plan.repeats) repeats × \(plan.cases.count) cases")
  }

  /// Prints the refusal with every backend key redacted.
  static func fail(_ refusal: JudgeBench.Refusal, environment: [String: String]) -> ExitCode {
    let secrets = JudgeBackend.allCases.compactMap { $0.keyVariable.flatMap { environment[$0] } }
    let message = secrets.filter { !$0.isEmpty }.reduce(refusal.message) {
      $0.replacingOccurrences(of: $1, with: "<redacted>")
    }
    FileHandle.standardError.write(Data("swiftgate judge bench: \(message)\n".utf8))
    return ExitCode(refusal.status)
  }
}

struct JudgeBenchRenderCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "bench-render",
    abstract: "Recompute a judge bench result's metrics and print its comparison page.",
    discussion:
      "Exit 0 rendered, 1 when the stored metrics differ from those the raw answers give, 2 for "
      + "a file that isn't a bench result this swiftgate reads.")

  @Argument(help: ArgumentHelp("A `judge bench` result JSON.", valueName: "file"))
  var file: String

  @Option(help: ArgumentHelp("Write the page here instead of printing it.", valueName: "file.md"))
  var out: String?

  func run() async throws {
    let root = URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
    let result: Result<String, JudgeBench.Refusal>
    do {
      result = JudgeBench.render(try Data(contentsOf: URL(filePath: file, relativeTo: root)))
    } catch {
      result = .failure(
        JudgeBench.Refusal(
          status: JudgeBench.badInputStatus, message: "can't read \(file): \(error)"))
    }
    switch result {
    case .failure(let refusal):
      FileHandle.standardError.write(
        Data("swiftgate judge bench-render: \(refusal.message)\n".utf8))
      throw ExitCode(refusal.status)
    case .success(let page):
      guard let out else {
        Console.write(page)
        return
      }
      do {
        try Data(page.utf8).write(to: URL(filePath: out, relativeTo: root))
      } catch {
        FileHandle.standardError.write(
          Data("swiftgate judge bench-render: --out \(out): can't write: \(error)\n".utf8))
        throw ExitCode(JudgeBench.badInputStatus)
      }
    }
  }
}
