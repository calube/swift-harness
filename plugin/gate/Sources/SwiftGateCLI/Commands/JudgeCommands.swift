import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateRules

/// Asks the judge about many subjects with bounded concurrency; one failure fails the batch
/// (the caller reports it once instead of per subject).
enum JudgeBatch {
  static let maxConcurrent = 4

  static func answer(
    _ subjects: [JudgeSubject], questions: JudgeQuestionSet, judge: any Judge,
    maxConcurrent: Int = maxConcurrent
  ) async -> Result<[String: [JudgeAnswer]], JudgeError> {
    await measuredAnswer(subjects, questions: questions, judge: judge, maxConcurrent: maxConcurrent)
      .map { $0.mapValues(\.answers) }
  }

  /// ``answer(_:questions:judge:maxConcurrent:)`` keeping each subject's usage.
  static func measuredAnswer(
    _ subjects: [JudgeSubject], questions: JudgeQuestionSet, judge: any Judge,
    maxConcurrent: Int = maxConcurrent
  ) async -> Result<[String: JudgeReply], JudgeError> {
    await withTaskGroup(of: (String, Result<JudgeReply, JudgeError>).self) { group in
      var pending = subjects[...]
      var replies: [String: JudgeReply] = [:]
      var failure: JudgeError?
      func enqueue() {
        guard let subject = pending.popFirst() else { return }
        group.addTask {
          do throws(JudgeError) {
            return (
              subject.id, .success(try await judge.measuredAnswer(subject, questions: questions))
            )
          } catch {
            return (subject.id, .failure(error))
          }
        }
      }
      for _ in 0..<maxConcurrent { enqueue() }
      for await (id, result) in group {
        switch result {
        case .success(let found): replies[id] = found
        case .failure(let error): failure = failure ?? error
        }
        if failure == nil { enqueue() }
      }
      if let failure { return .failure(failure) }
      return .success(replies)
    }
  }
}

// MARK: - Test quality

/// The judge's test-quality questions over new and changed host tests (spec §7.4). Advisory below
/// the ready tier; at ready, a confident answer to a blocking question is a gating finding.
enum TestJudgeCheck {
  static let notRunRuleID = "judge.not-run"
  /// Diff context per test is capped so one huge change can't blow the prompt.
  static let maxContextCharacters = 12_000

  struct Dependencies: Sendable {
    let makeJudge: @Sendable (JudgeConfig) -> (any Judge)?
    let diff: any DiffReading
    /// The harness checkout whose labels and recordings decide whether a backend that needs a
    /// block calibration may block; `nil` when none is known.
    let harnessRoot: URL?
    /// Writes the reason on a blocking finding from a backend that gives none; `nil` leaves such
    /// a finding with a note that the reason is missing.
    let reasonJudge: (any Judge)?
    /// Values no reason may carry, such as the Jev key.
    let secrets: [String]

    init(
      makeJudge: @escaping @Sendable (JudgeConfig) -> (any Judge)?, diff: any DiffReading,
      harnessRoot: URL? = nil, reasonJudge: (any Judge)? = nil, secrets: [String] = []
    ) {
      self.makeJudge = makeJudge
      self.diff = diff
      self.harnessRoot = harnessRoot
      self.reasonJudge = reasonJudge
      self.secrets = secrets
    }

    static func live(root: URL, git: LiveGit) -> Dependencies {
      Dependencies(
        makeJudge: {
          JudgeFactory.make(
            $0, runner: LiveProcessRunner(),
            cacheDirectory: root.appending(path: FileJudgeCache.directoryName))
        },
        diff: git,
        harnessRoot: ProcessInfo.processInfo.environment[SelfTestCommand.harnessRootVariable].map {
          URL(filePath: $0, directoryHint: .isDirectory)
        },
        reasonJudge: JudgeBlockReason.liveJudge(root: root),
        secrets: JudgeBackend.allCases.compactMap {
          $0.keyVariable.flatMap { ProcessInfo.processInfo.environment[$0] }
        })
    }
  }

  static func run(
    _ environment: ChangedTestChecks.Environment, graph: ModuleGraph, config: Config,
    base: String, atReadyTier: Bool, dependencies: Dependencies
  ) async -> [Finding] {
    guard case .enabled(let backend, let thresholds, _) = config.judge,
      let judge = dependencies.makeJudge(config.judge)
    else { return [] }
    let needsCalibration =
      backend.needsBlockCalibration
      || JudgeBackend(rawValue: judge.identity.backend)?.needsBlockCalibration == true
    let selection: ChangedTestChecks.Selection
    switch await ChangedTestChecks.select(environment, graph: graph, base: base) {
    case .failure(let reason): return note("judge not run: \(reason.text)")
    case .success(let found): selection = found
    }
    guard !selection.packages.isEmpty else { return [] }
    let diff: String
    do throws(GitError) {
      diff = try await dependencies.diff.unifiedDiff(since: selection.mergeBase)
    } catch {
      return note("judge not run: git: \(error)")
    }
    let sections = DiffSections.split(diff)
    var subjects: [JudgeSubject] = []
    var files: [String: [Substring]] = [:]
    for package in selection.packages {
      let context = sections.filter { path, _ in
        path.hasPrefix(package.packagePath == "." ? "" : package.packagePath + "/")
          && !package.testDirectories.contains { path.hasPrefix($0) }
      }
      .map(\.text).joined(separator: "\n")
      for test in package.tests {
        if files[test.file] == nil {
          let text =
            (try? String(contentsOf: environment.root.appending(path: test.file), encoding: .utf8))
            ?? ""
          files[test.file] = text.split(separator: "\n", omittingEmptySubsequences: false)
        }
        let lines = files[test.file] ?? []
        guard test.lastLine <= lines.count else { continue }
        subjects.append(
          JudgeSubject(
            id: test.id, file: test.file, line: test.line,
            source: lines[(test.line - 1)...(test.lastLine - 1)].joined(separator: "\n"),
            context: String(context.prefix(maxContextCharacters)), declaredTier: "T1"))
      }
    }
    switch await JudgeBatch.answer(subjects, questions: .tests, judge: judge) {
    case .failure(let error): return note("judge not run: \(error)")
    case .success(let answers):
      let authority: JudgeBlockAuthority =
        needsCalibration
        ? .perQuestion(
          JudgeCalibrationFiles.blockDecisions(
            harnessRoot: dependencies.harnessRoot, questions: .tests,
            model: judge.identity.model, blockThreshold: thresholds.block))
        : .standing
      var findings: [Finding] = []
      for subject in subjects {
        findings +=
          (try? JudgePolicy.findings(
            subject: subject, answers: answers[subject.id] ?? [], questions: .tests,
            thresholds: thresholds, identity: judge.identity, atReadyTier: atReadyTier,
            blockAuthority: authority)) ?? []
      }
      return await JudgeBlockReason.attach(
        findings, subjects: subjects, answers: answers, questions: .tests,
        identity: judge.identity, reasonJudge: dependencies.reasonJudge,
        redacting: dependencies.secrets)
    }
  }

  /// A judge that can't run is reported, never gating: it says nothing about the code.
  private static func note(_ message: String) -> [Finding] {
    (try? Finding(
      ruleID: notRunRuleID, severity: .minor, file: ".", line: nil, message: message,
      failureScenario: nil)).map { [$0] } ?? []
  }
}

/// Splits a unified diff into per-file sections keyed by the new path.
enum DiffSections {
  static func split(_ diff: String) -> [(path: String, text: String)] {
    var sections: [(path: String, text: String)] = []
    var current: [Substring] = []
    var path: String?
    func flush() {
      if let path, !current.isEmpty { sections.append((path, current.joined(separator: "\n"))) }
      current = []
    }
    for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
      if line.hasPrefix("diff --git ") {
        flush()
        path = line.split(separator: " ").last.map { String($0.dropFirst(2)) }
      }
      current.append(line)
    }
    flush()
    return sections
  }
}

typealias JudgeTestsCommand = JudgeCommand

struct JudgeCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "judge",
    abstract: "Ask the configured judge about new and changed host tests (advisory below ready).",
    discussion:
      "Off unless .swiftgate.toml has [judge] backend set: a remote backend sends test source "
      + "off the machine. Answers are cached under .harness/judge-cache/.")

  @Option(help: "Changes are measured from the merge base of HEAD and this ref.")
  var base = "origin/main"

  @Flag(help: "Apply the ready-tier policy: confident answers to blocking questions gate.")
  var ready = false

  @OptionGroup var output: OutputOptions

  func run() async throws {
    let root = URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
    let git = LiveGit(runner: LiveProcessRunner(), repositoryRoot: root.path)
    let swiftPM = ScopeResolution.liveSwiftPM(root: root)
    try await StaticCheckRun.execute(root: root, format: output.format) {
      let config: Config
      switch StaticCheckInputs.loadConfig(root: root) {
      case .failure(let failure): return failure.outcome
      case .success(nil): return .invalid(reason: "no \(ConfigLoader.fileName)", file: ".")
      case .success(let loaded?): config = loaded
      }
      guard case .enabled = config.judge else {
        return .checked(RuleRunResult(findings: [], allowances: []))
      }
      let graph: ModuleGraph
      switch await ScopeResolution.resolve(config: config, root: root, swiftPM: swiftPM) {
      case .failed(let outcome): return outcome
      case .resolved(let scopes):
        guard let resolved = scopes.graph else {
          return .blocked(reason: "the module graph could not be built")
        }
        graph = resolved
      }
      let findings = await TestJudgeCheck.run(
        .live(root: root, git: git, swiftPM: swiftPM), graph: graph, config: config, base: base,
        atReadyTier: ready, dependencies: .live(root: root, git: git))
      return .checked(RuleRunResult(findings: findings, allowances: []))
    }
  }
}

// MARK: - Comments

/// The judge's comment questions on a Claude-authored commit (spec §7.5): advisory, cached, and
/// only when the repository enabled the judge.
struct ConfiguredCommitCommentJudge: CommitCommentJudging {
  static let maxComments = 6
  /// Keeps the PreToolUse hook inside its budget; a slow judge is skipped, not waited on.
  static let timeout: Duration = .seconds(15)

  let makeJudge: @Sendable (JudgeConfig, URL) -> (any Judge)?
  let git: @Sendable (URL) -> any Git

  static let live = ConfiguredCommitCommentJudge(
    makeJudge: { config, root in
      judge(
        for: config, root: root, transport: URLSessionTransport(),
        environment: ProcessInfo.processInfo.environment, clock: LiveRetryClock())
    },
    git: { LiveGit(runner: LiveProcessRunner(), repositoryRoot: $0.path) })

  /// The configured backend held to the hook's timeout, wrapped in the cache under `root`.
  static func judge(
    for config: JudgeConfig, root: URL, transport: any HTTPTransport,
    environment: [String: String], clock: any RetryClock
  ) -> (any Judge)? {
    guard case .enabled(let backend, _, let configured) = config else { return nil }
    let model = configured ?? backend.pinnedModel
    let judge: any Judge =
      switch backend {
      case .claude:
        ClaudeCLIJudge(
          runner: LiveProcessRunner(), model: model ?? JudgeFactory.defaultModel,
          timeout: timeout)
      case .jev:
        JevJudge(
          model: model ?? JevPin.model, transport: transport, environment: environment,
          clock: clock, timeout: timeout)
      }
    return CachingJudge(
      judge, cache: FileJudgeCache(directory: root.appending(path: FileJudgeCache.directoryName)))
  }

  /// Comments asked at once. Each Jev request is 1 HTTP call well under TypeSafe's rate limit, so
  /// every capped comment goes in 1 round and the hook waits for 1 request; each Claude answer is
  /// a `claude` process, so those keep the shared bound.
  static func concurrency(_ backend: JudgeBackend) -> Int {
    switch backend {
    case .claude: JudgeBatch.maxConcurrent
    case .jev: maxComments
    }
  }

  func review(root: URL) async -> String? {
    guard case .success(let config?) = StaticCheckInputs.loadConfig(root: root),
      case .enabled(let backend, let thresholds, _) = config.judge,
      let judge = makeJudge(config.judge, root)
    else { return nil }
    let subjects: [JudgeSubject]
    do throws(GitError) {
      subjects = try await Self.subjects(git: git(root))
    } catch {
      return nil
    }
    guard !subjects.isEmpty else { return nil }
    switch await JudgeBatch.answer(
      subjects, questions: .comments, judge: judge, maxConcurrent: Self.concurrency(backend))
    {
    case .failure(let error):
      return "Comment judge not run: \(error)"
    case .success(let answers):
      let findings = subjects.flatMap { subject in
        (try? JudgePolicy.findings(
          subject: subject, answers: answers[subject.id] ?? [], questions: .comments,
          thresholds: thresholds, identity: judge.identity, atReadyTier: false)) ?? []
      }
      guard !findings.isEmpty else { return nil }
      return "Comment judge (advisory; propose the edit, never block):\n"
        + findings.map { "- \($0.file):\($0.line ?? 0) \($0.message)" }.joined(separator: "\n")
    }
  }

  /// Staged comments on added lines, with the code that follows each, capped.
  static func subjects(git: any Git) async throws(GitError) -> [JudgeSubject] {
    let added = try await git.stagedAddedLines().filter { $0.path.hasSuffix(".swift") }
    let contents = try await git.stagedContents(of: added.map(\.path))
    var subjects: [JudgeSubject] = []
    for lines in added {
      guard let text = contents[lines.path] else { continue }
      let source = text.split(separator: "\n", omittingEmptySubsequences: false)
      let unit = SourceUnit(input: SourceInput(path: lines.path, text: text), scope: nil)
      for comment in unit.comments
      where lines.ranges.contains(where: { $0.contains(comment.startLine) })
        && !comment.body.hasPrefix("MARK:")
      {
        let following = source.dropFirst(comment.endLine).prefix(6).joined(separator: "\n")
        subjects.append(
          JudgeSubject(
            id: "\(lines.path):\(comment.startLine)", file: lines.path, line: comment.startLine,
            source: comment.text, context: following))
        if subjects.count == maxComments { return subjects }
      }
    }
    return subjects
  }
}

// MARK: - Calibration

/// `self-test --judge`: precision and recall per question over the labeled calibration set
/// (spec §7.4). Offline by default, from the recorded answers of a real backend.
enum JudgeSelfTest {
  static let directory = "gate/Fixtures/judge"
  static let ruleID = "swiftgate.self-test.judge"
  static let metricsRuleID = "swiftgate.self-test.judge-metrics"
  static let staleRuleID = "swiftgate.self-test.judge-stale"

  /// The set each backend is calibrated on: Jev asks its own rendering, whose labels are the
  /// base set's.
  static func questions(for backend: JudgeBackend) -> JudgeQuestionSet {
    switch backend {
    case .claude: .tests
    case .jev: .testsJev
    }
  }

  /// Claude's baseline keeps its original name; every other backend's is `baseline-<backend>.json`.
  static func baselineFile(for backend: JudgeBackend) -> String {
    switch backend {
    case .claude: "baseline.json"
    case .jev: "baseline-jev.json"
    }
  }

  static func subjects(harnessRoot: URL, set: JudgeCalibrationSet) throws -> [JudgeSubject] {
    try set.cases.map { item in
      let caseDirectory = "\(directory)/cases/\(item.id)"
      let root = harnessRoot.appending(path: caseDirectory, directoryHint: .isDirectory)
      return JudgeSubject(
        id: item.id, file: "\(caseDirectory)/Test.swift.txt", line: 1,
        source: try String(contentsOf: root.appending(path: "Test.swift.txt"), encoding: .utf8),
        context: try String(contentsOf: root.appending(path: "Change.diff"), encoding: .utf8),
        declaredTier: item.declaredTier)
    }
  }

  /// A recording to score, with the baseline beside it.
  struct Scored {
    let backend: JudgeBackend
    let recording: JudgeCalibrationRecording
    let baseline: JudgeBaseline?
    /// From comparing a live run with the committed recording; `nil` offline or when recording.
    let live: JudgeRecordingStaleness?
  }

  /// Offline, scores every backend's recording that exists against its own baseline; Claude's
  /// must exist. With `judge`, answers every case live as `backend` and scores that instead;
  /// with `record`, the live answers replace `backend`'s recording.
  static func run(
    harnessRoot: URL, judge: (any Judge)?, record: Bool, backend: JudgeBackend = .claude
  ) async -> StaticCheckOutcome {
    let root = harnessRoot.appending(path: directory, directoryHint: .isDirectory)
    let set: JudgeCalibrationSet
    let subjects: [JudgeSubject]
    do {
      set = try JSONDecoder().decode(
        JudgeCalibrationSet.self, from: Data(contentsOf: root.appending(path: "labels.json")))
      subjects = try Self.subjects(harnessRoot: harnessRoot, set: set)
    } catch {
      return .blocked(reason: "self-test --judge: calibration set unreadable: \(error)")
    }
    let labelled = JudgeQuestionSet.tests
    guard set.questionSet == labelled.versionedID else {
      return .invalid(
        reason:
          "labels and baseline must target \(labelled.versionedID); relabel and re-baseline "
          + "after a question-set change",
        file: "\(directory)/labels.json")
    }
    var scored: [Scored] = []
    if let judge {
      let replies: [String: JudgeReply]
      let questions = questions(for: backend)
      switch await JudgeBatch.measuredAnswer(subjects, questions: questions, judge: judge) {
      case .failure(let error): return .blocked(reason: "self-test --judge: \(error)")
      case .success(let found): replies = found
      }
      let live = JudgeCalibrationRecording(
        questionSet: questions.versionedID, identity: judge.identity, replies: replies)
      let file = JudgeCalibrationFiles.recordingFile(for: backend)
      var drift: JudgeRecordingStaleness?
      if record {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
          try encoder.encode(live).write(to: root.appending(path: file), options: .atomic)
        } catch {
          return .blocked(reason: "self-test --judge: could not write the recording: \(error)")
        }
      } else {
        do {
          drift = JudgeCalibration.liveStaleness(
            committed: try recording(in: root, file: file), file: file, live: live)
        } catch {
          return .blocked(reason: "self-test --judge: no usable \(directory)/\(file): \(error)")
        }
      }
      do {
        scored = [
          Scored(
            backend: backend, recording: live, baseline: try baseline(in: root, for: backend),
            live: drift)
        ]
      } catch {
        return .blocked(reason: "self-test --judge: \(error)")
      }
    } else {
      for candidate in JudgeBackend.allCases {
        let file = JudgeCalibrationFiles.recordingFile(for: candidate)
        do {
          guard let found = try recording(in: root, file: file) else {
            // Claude's recording is the one the harness always ships.
            guard candidate == .claude else { continue }
            return .blocked(reason: "self-test --judge: no \(directory)/\(file)")
          }
          scored.append(
            Scored(
              backend: candidate, recording: found,
              baseline: try baseline(in: root, for: candidate), live: nil))
        } catch {
          return .blocked(reason: "self-test --judge: no usable \(directory)/\(file): \(error)")
        }
      }
    }
    var findings: [Finding] = []
    for entry in scored {
      switch score(entry, set: set, subjects: subjects) {
      case .success(let found): findings += found
      case .failure(let refused): return refused.outcome
      }
    }
    return .checked(RuleRunResult(findings: findings, allowances: []))
  }

  /// `nil` when the file doesn't exist; a file that exists but won't decode is an error.
  static func recording(in root: URL, file: String) throws -> JudgeCalibrationRecording? {
    let url = root.appending(path: file)
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    return try JSONDecoder().decode(JudgeCalibrationRecording.self, from: Data(contentsOf: url))
  }

  /// `nil` when a backend other than Claude has no baseline yet; Claude's must exist.
  static func baseline(in root: URL, for backend: JudgeBackend) throws -> JudgeBaseline? {
    let file = baselineFile(for: backend)
    let url = root.appending(path: file)
    guard backend == .claude || FileManager.default.fileExists(atPath: url.path) else {
      return nil
    }
    do {
      return try JSONDecoder().decode(JudgeBaseline.self, from: Data(contentsOf: url))
    } catch {
      throw BaselineUnreadable(description: "\(directory)/\(file) unreadable: \(error)")
    }
  }

  struct BaselineUnreadable: Error, CustomStringConvertible {
    let description: String
  }

  /// A recording that can't be scored at all, and the outcome that says why.
  struct Refused: Error {
    let outcome: StaticCheckOutcome

    static func failure(_ outcome: StaticCheckOutcome) -> Result<[Finding], Refused> {
      .failure(Refused(outcome: outcome))
    }
  }

  /// Every finding for 1 recording: its metrics, usage, regressions against its baseline, and
  /// why it may be stale.
  static func score(
    _ entry: Scored, set: JudgeCalibrationSet, subjects: [JudgeSubject]
  ) -> Result<[Finding], Refused> {
    let questions = questions(for: entry.backend)
    let file = JudgeCalibrationFiles.recordingFile(for: entry.backend)
    let baselineFile = baselineFile(for: entry.backend)
    let recording = entry.recording
    guard recording.questionSet == questions.versionedID else {
      // Answers to another version can't be scored as this one's; only a re-record helps.
      let stale = JudgeRecordingStaleness.questionSetDiffers(
        file: file, found: recording.questionSet, expected: questions.versionedID)
      do {
        return .success([
          try Finding(
            ruleID: staleRuleID, severity: .major, file: "\(directory)/\(file)", line: nil,
            message: stale.description, failureScenario: nil)
        ])
      } catch {
        return Refused.failure(.blocked(reason: "self-test --judge: \(error)"))
      }
    }
    if let baseline = entry.baseline, baseline.questionSet != questions.versionedID {
      return Refused.failure(
        .invalid(
          reason:
            "labels and baseline must target \(questions.versionedID); relabel and re-baseline "
            + "after a question-set change",
          file: "\(directory)/\(baselineFile)"))
    }
    let asked = Set(subjects.map(\.id))
    var answers: [String: [JudgeAnswer]] = [:]
    for (id, found) in recording.answers where asked.contains(id) {
      do {
        answers[id] = try JudgeAnswers.validate(found, for: questions)
      } catch {
        return Refused.failure(
          .blocked(reason: "self-test --judge: \(file): recorded answer for \(id): \(error)"))
      }
    }
    let valid = JudgeCalibrationRecording(
      questionSet: recording.questionSet, identity: recording.identity,
      servedModels: recording.servedModels, answers: answers, usage: recording.usage)
    let result = JudgeCalibration.score(set: set, questions: questions, answers: answers)
    var stale = JudgeCalibration.staleness(
      recording: recording, file: file, backend: entry.backend, baseline: entry.baseline,
      baselineFile: baselineFile)
    if let live = entry.live { stale.append(live) }
    if !result.unrecorded.isEmpty {
      stale.append(
        .labelledNotRecorded(file: file, backend: entry.backend, cases: result.unrecorded.count))
    }
    let tune = JudgeTuneCases(set.benchmarkCases)
    let labelsFile = "\(directory)/labels.json"
    do {
      var findings = try zip(questions.questions, result.metrics).map {
        question, metric throws(ReportContractViolation) in
        let threshold = sweep(
          question, tune: tune, run: valid.run,
          minimumPrecision: entry.baseline?.minimums[question.id]?.precision)
        return try Finding(
          ruleID: metricsRuleID, severity: .nit, file: labelsFile, line: nil,
          message: describe(metric, identity: recording.identity) + "; " + threshold,
          failureScenario: nil)
      }
      findings.append(
        try Finding(
          ruleID: metricsRuleID, severity: .nit, file: labelsFile, line: nil,
          message: describe(
            JudgeCalibration.usage(set: set, recording: valid), identity: recording.identity),
          failureScenario: nil))
      if let baseline = entry.baseline {
        findings += try JudgeCalibration.regressions(result.metrics, baseline: baseline).map {
          line throws(ReportContractViolation) in
          try Finding(
            ruleID: ruleID, severity: .major, file: "\(directory)/\(baselineFile)", line: nil,
            message: "judge calibration regressed [\(file)]: \(line)", failureScenario: nil)
        }
      } else {
        findings.append(
          try Finding(
            ruleID: ruleID, severity: .major, file: "\(directory)/\(baselineFile)", line: nil,
            message:
              "\(file) has no \(baselineFile) to score against; set one from these metrics",
            failureScenario: nil))
      }
      findings += try stale.map { item throws(ReportContractViolation) in
        try Finding(
          ruleID: staleRuleID, severity: item.gates ? .major : .minor,
          // A note about the live replies has no file of its own; it's about the recording.
          file: "\(directory)/\(item.file.hasSuffix(".json") ? item.file : file)", line: nil,
          message: item.description,
          failureScenario: nil)
      }
      return .success(findings)
    } catch {
      return Refused.failure(.blocked(reason: "self-test --judge: \(error)"))
    }
  }

  /// The swept threshold column: the lowest block threshold whose tune-split precision reaches
  /// the baseline's.
  static func sweep(
    _ question: JudgeQuestion, tune: JudgeTuneCases, run: JudgeBenchmarkRun,
    minimumPrecision: Double?
  ) -> String {
    let labelled = tune.cases.filter { $0.expected[question.id] != nil }.count
    let prefix = "lowest block threshold at baseline precision (tune split, n \(labelled)): "
    guard let minimumPrecision else { return prefix + "no baseline" }
    let lowest = JudgeCalibration.lowestBlockThreshold(
      question, cases: tune, run: run, minimumPrecision: minimumPrecision)
    let range = JudgeCalibration.sweepThresholds
    return prefix
      + (lowest.map { format($0) }
        ?? "none from \(format(range.first ?? 0)) to \(format(range.last ?? 0))")
  }

  static func format(_ value: Double?) -> String {
    value.map { String(format: "%.2f", $0) } ?? "n/a"
  }

  static func describe(_ metric: JudgeQuestionMetrics, identity: JudgeIdentity) -> String {
    "\(metric.question) [\(identity.backend)/\(identity.model)]: precision "
      + "\(format(metric.precision)) recall \(format(metric.recall)) "
      + "(tp \(metric.truePositives) fp \(metric.falsePositives) fn \(metric.falseNegatives) "
      + "tn \(metric.trueNegatives)); true-negative rate \(format(metric.trueNegativeRate))"
  }

  static func describe(_ usage: JudgeUsageBenchmark, identity: JudgeIdentity) -> String {
    func milliseconds(_ value: Int?) -> String { value.map { "\($0) ms" } ?? "n/a" }
    let cost = usage.costPerCase.value.map { String(format: "$%.4f", $0) } ?? "n/a"
    return "[\(identity.backend)/\(identity.model)] usage over the report split: latency p50 "
      + "\(milliseconds(usage.requestLatency.p50)) p95 \(milliseconds(usage.requestLatency.p95)) "
      + "(n \(usage.requestLatency.n)); cost per subject \(cost) (n \(usage.costPerCase.n))"
  }
}
extension JudgeBackend: ExpressibleByArgument {}
