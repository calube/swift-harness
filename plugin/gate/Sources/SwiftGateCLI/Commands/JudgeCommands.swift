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
    _ subjects: [JudgeSubject], questions: JudgeQuestionSet, judge: any Judge
  ) async -> Result<[String: [JudgeAnswer]], JudgeError> {
    await withTaskGroup(of: (String, Result<[JudgeAnswer], JudgeError>).self) { group in
      var pending = subjects[...]
      var answers: [String: [JudgeAnswer]] = [:]
      var failure: JudgeError?
      func enqueue() {
        guard let subject = pending.popFirst() else { return }
        group.addTask {
          do throws(JudgeError) {
            return (subject.id, .success(try await judge.answer(subject, questions: questions)))
          } catch {
            return (subject.id, .failure(error))
          }
        }
      }
      for _ in 0..<maxConcurrent { enqueue() }
      for await (id, result) in group {
        switch result {
        case .success(let found): answers[id] = found
        case .failure(let error): failure = failure ?? error
        }
        if failure == nil { enqueue() }
      }
      if let failure { return .failure(failure) }
      return .success(answers)
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

    init(
      makeJudge: @escaping @Sendable (JudgeConfig) -> (any Judge)?, diff: any DiffReading,
      harnessRoot: URL? = nil
    ) {
      self.makeJudge = makeJudge
      self.diff = diff
      self.harnessRoot = harnessRoot
    }

    static func live(root: URL, git: LiveGit) -> Dependencies {
      Dependencies(
        makeJudge: {
          JudgeFactory.make(
            $0, runner: LiveProcessRunner(),
            cacheDirectory: root.appending(path: FileJudgeCache.directoryName))
        },
        diff: git)
    }
  }

  static func run(
    _ environment: ChangedTestChecks.Environment, graph: ModuleGraph, config: Config,
    base: String, atReadyTier: Bool, dependencies: Dependencies
  ) async -> [Finding] {
    guard case .enabled(_, let thresholds, _) = config.judge,
      let judge = dependencies.makeJudge(config.judge)
    else { return [] }
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
      var findings: [Finding] = []
      for subject in subjects {
        findings +=
          (try? JudgePolicy.findings(
            subject: subject, answers: answers[subject.id] ?? [], questions: .tests,
            thresholds: thresholds, identity: judge.identity, atReadyTier: atReadyTier)) ?? []
      }
      return findings
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
      let cache = root.appending(path: FileJudgeCache.directoryName)
      guard case .enabled(.claude, _, let model) = config else {
        return JudgeFactory.make(config, runner: LiveProcessRunner(), cacheDirectory: cache)
      }
      let claude = ClaudeCLIJudge(
        runner: LiveProcessRunner(), model: model ?? JudgeFactory.defaultModel, timeout: timeout)
      return CachingJudge(claude, cache: FileJudgeCache(directory: cache))
    },
    git: { LiveGit(runner: LiveProcessRunner(), repositoryRoot: $0.path) })

  func review(root: URL) async -> String? {
    guard case .success(let config?) = StaticCheckInputs.loadConfig(root: root),
      case .enabled(_, let thresholds, _) = config.judge,
      let judge = makeJudge(config.judge, root)
    else { return nil }
    let subjects: [JudgeSubject]
    do throws(GitError) {
      subjects = try await Self.subjects(git: git(root))
    } catch {
      return nil
    }
    guard !subjects.isEmpty else { return nil }
    switch await JudgeBatch.answer(subjects, questions: .comments, judge: judge) {
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
  static let recordingFile = "recording.json"
  static let ruleID = "swiftgate.self-test.judge"
  static let metricsRuleID = "swiftgate.self-test.judge-metrics"

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

  /// `judge` answers every case; with `record`, its answers replace the stored recording.
  static func run(harnessRoot: URL, judge: (any Judge)?, record: Bool) async -> StaticCheckOutcome {
    let root = harnessRoot.appending(path: directory, directoryHint: .isDirectory)
    let set: JudgeCalibrationSet
    let baseline: JudgeBaseline
    let subjects: [JudgeSubject]
    do {
      set = try JSONDecoder().decode(
        JudgeCalibrationSet.self, from: Data(contentsOf: root.appending(path: "labels.json")))
      baseline = try JSONDecoder().decode(
        JudgeBaseline.self, from: Data(contentsOf: root.appending(path: "baseline.json")))
      subjects = try Self.subjects(harnessRoot: harnessRoot, set: set)
    } catch {
      return .blocked(reason: "self-test --judge: calibration set unreadable: \(error)")
    }
    let questions = JudgeQuestionSet.tests
    guard set.questionSet == questions.versionedID, baseline.questionSet == questions.versionedID
    else {
      return .invalid(
        reason:
          "labels and baseline must target \(questions.versionedID); relabel and re-baseline "
          + "after a question-set change",
        file: "\(directory)/labels.json")
    }
    let resolved: any Judge
    if let judge {
      resolved = judge
    } else {
      do {
        resolved = RecordedJudge(
          try JSONDecoder().decode(
            RecordedJudge.Recording.self,
            from: Data(contentsOf: root.appending(path: recordingFile))))
      } catch {
        return .blocked(
          reason: "self-test --judge: no usable \(directory)/\(recordingFile): \(error)")
      }
    }
    let answers: [String: [JudgeAnswer]]
    switch await JudgeBatch.answer(subjects, questions: questions, judge: resolved) {
    case .failure(let error): return .blocked(reason: "self-test --judge: \(error)")
    case .success(let found): answers = found
    }
    if record {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      do {
        try encoder.encode(
          RecordedJudge.Recording(
            questionSet: questions.versionedID, identity: resolved.identity, answers: answers)
        ).write(to: root.appending(path: recordingFile), options: .atomic)
      } catch {
        return .blocked(reason: "self-test --judge: could not write the recording: \(error)")
      }
    }
    let metrics = JudgeCalibration.metrics(set: set, questions: questions, answers: answers)
    do {
      var findings = try metrics.map { metric throws(ReportContractViolation) in
        try Finding(
          ruleID: metricsRuleID, severity: .nit, file: "\(directory)/labels.json", line: nil,
          message: describe(metric, identity: resolved.identity), failureScenario: nil)
      }
      findings += try JudgeCalibration.regressions(metrics, baseline: baseline).map {
        line throws(ReportContractViolation) in
        try Finding(
          ruleID: ruleID, severity: .major, file: "\(directory)/baseline.json", line: nil,
          message: "judge calibration regressed: \(line)", failureScenario: nil)
      }
      return .checked(RuleRunResult(findings: findings, allowances: []))
    } catch {
      return .blocked(reason: "self-test --judge: \(error)")
    }
  }

  static func describe(_ metric: JudgeQuestionMetrics, identity: JudgeIdentity) -> String {
    func format(_ value: Double?) -> String { value.map { String(format: "%.2f", $0) } ?? "n/a" }
    return
      "\(metric.question) [\(identity.backend)/\(identity.model)]: precision "
      + "\(format(metric.precision)) recall \(format(metric.recall)) "
      + "(tp \(metric.truePositives) fp \(metric.falsePositives) fn \(metric.falseNegatives) "
      + "tn \(metric.trueNegatives))"
  }
}
extension JudgeBackend: ExpressibleByArgument {}
