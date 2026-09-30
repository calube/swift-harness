import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateRules

struct CalibrateCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "calibrate",
    abstract: "Run an agent against labelled seeds and judge it against the labels.",
    subcommands: [CalibrateDesignCommand.self, CalibrateBuildCommand.self])
}

struct CalibrateDesignCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "design",
    abstract: "Run the design agents against labelled seeds and report per-agent pass/fail (§12).",
    discussion:
      "Runs every \(DesignCalibrationLayout.agentsDirectory)/<agent>.md with seeds under \(DesignCalibrationLayout.seedsDirectory)/"
      + "<agent>/<case>/ through `claude -p`: the agent's prompt as the system prompt, the model "
      + "its frontmatter names, the case's input.md as the prompt. The label's checks score the "
      + "JSON the agent returns; a judge reads the output only for a label no field carries, and "
      + "a judged answer passes at p >= 0.7. When every label is met it writes "
      + "\(DesignCalibrationLayout.recordPath) with each case's model and the content hash of "
      + "\(DesignCalibrationLayout.agentsDirectory)/design-*.md and "
      + "\(DesignCalibrationLayout.workflowsDirectory)/design-*.js. Exit 0 all labels met (record written), "
      + "1 on a missed label or a seed defect (record untouched), 2 when claude can't run or "
      + "answer, or a seed can't be read.")

  @Option(
    help: ArgumentHelp(
      "Run every agent on this model instead of its frontmatter's, for experiments. The "
        + "record it writes never counts as fresh."))
  var model: String?

  @Option(
    help: ArgumentHelp(
      "Judge the replies an earlier run kept under .harness/runs/<run id>/ instead of running "
        + "the agents.",
      valueName: "run id"))
  var replay: String?

  @OptionGroup var output: OutputOptions

  func run() async throws {
    let root = URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
    let now = Date()  // swiftgate:allow det.date-init — the CLI edge stamps when the pass ran
    try await StaticCheckRun.execute(root: root, format: output.format) {
      await CalibrateDesignRun.run(
        root: root, runner: LiveProcessRunner(), model: CalibrationModel.unpinned,
        modelOverride: model, now: now,
        concurrentCases: CalibrateDesignRun.defaultConcurrentCases)
    }
  }
}

struct CalibrateBuildCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "build",
    abstract: "Run the build worker and fixer on seeded repositories and judge them (§12).",
    discussion:
      "For each case under \(CalibrationSuite.build.seedsDirectory)/<agent>/<case>/ it builds the "
      + "seed's git repository in a scratch directory, runs the agent there through `claude -p` "
      + "with its own prompt and tools, then checks its return, the files its branch touched, "
      + "the refs it moved, a fixer's resolution, and the seed's acceptance tests. Each agent runs "
      + "on the model its frontmatter names, or \(CalibrationModel.unpinned) when it names none. "
      + "When every "
      + "label is met it writes \(CalibrationSuite.build.recordPath) with the content hash of "
      + "\(CalibrationSuite.build.agentsDescription). Exit 0 all labels met (record written), 1 "
      + "on a missed label or a seed defect (record untouched), 2 when git, swift or claude "
      + "can't run, or a seed can't be read. Costs a real agent run per case.")

  @Option(
    help: ArgumentHelp(
      "Run every agent on this model instead of its frontmatter's, for experiments. The "
        + "record it writes never counts as fresh."))
  var model: String?

  @Option(help: "Minutes each agent run may take before it's stopped.")
  var timeoutMinutes: Int = 60

  @OptionGroup var output: OutputOptions

  func validate() throws {
    guard timeoutMinutes > 0 else { throw ValidationError("--timeout-minutes must be positive") }
  }

  func run() async throws {
    let root = URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
    let now = Date()  // swiftgate:allow det.date-init — the CLI edge stamps when the pass ran
    let runner = LiveProcessRunner()
    let calibration = BuildCalibrationRunner(
      agent: runner, tools: runner, root: root,
      sandboxRoot: FileManager.default.temporaryDirectory.appending(
        path: "swiftgate-calibrate-build-\(Int(now.timeIntervalSince1970))-"
          + "\(ProcessInfo.processInfo.processIdentifier)",
        directoryHint: .isDirectory),
      pluginBin: root.appending(path: "\(CalibrationSuite.pluginDirectory)/bin").path,
      defaultModel: CalibrationModel.unpinned, modelOverride: model,
      agentTimeout: .seconds(timeoutMinutes * 60))
    try await StaticCheckRun.execute(root: root, format: output.format) {
      await CalibrateBuildRun.run(root: root, calibration: calibration, now: now)
    }
  }
}

/// Loads the design seeds and runs each agent on its cases.
enum CalibrateDesignRun {
  /// What the command runs at once: each case is one `claude -p` with no tools, so several run
  /// together without contending for the build machine.
  static let defaultConcurrentCases = 4

  /// - Parameters:
  ///   - model: the model for an agent whose frontmatter names none.
  ///   - modelOverride: every agent's model instead of its own, for experiments.
  static func run(
    root: URL, runner: any ProcessRunner, model: String, modelOverride: String? = nil,
    now: Date, concurrentCases: Int = 1, replies: DesignCalibrationReplies? = nil
  ) async -> StaticCheckOutcome {
    let calibration = DesignCalibrationRunner(
      runner: runner, unpinnedModel: model, modelOverride: modelOverride)
    return await CalibrationRun.run(
      root: root, seeds: DesignCalibrationSeeds.load(root: root),
      modelOverride: calibration.modelOverride, now: now, concurrentCases: concurrentCases
    ) { agent, seed throws(CalibrationCaseError) in
      let run = try await calibration.run(agent: agent, seed: seed)
      return .init(
        result: run.result,
        note: CalibrationRun.usage(
          "\(agent.name)/\(seed.name) on \(calibration.model(of: agent))", costUSD: run.costUSD,
          durationMilliseconds: run.durationMilliseconds))
    }
  }
}

/// Loads the build seeds and runs each agent on its seeded repository.
enum CalibrateBuildRun {
  static func run(root: URL, calibration: BuildCalibrationRunner, now: Date) async
    -> StaticCheckOutcome
  {
    await CalibrationRun.run(
      root: root, seeds: BuildCalibrationSeeds.load(root: root),
      modelOverride: calibration.modelOverride, now: now
    ) { agent, seed throws(CalibrationCaseError) in
      let run = try await calibration.run(agent: agent, seed: seed)
      var note = CalibrationRun.usage(
        "\(agent.name)/\(seed.name) on \(calibration.model(of: agent))", costUSD: run.costUSD,
        durationMilliseconds: run.durationMilliseconds)
      if let sandbox = run.sandbox { note += "; its repository is kept at \(sandbox)" }
      return .init(result: run.result, note: note)
    }
  }
}

/// What every suite shares: seed defects stop the run before any agent is called, so a broken
/// seed set costs nothing; the pass record is written only when nothing missed.
enum CalibrationRun {
  /// Every rule a calibration run reports; a finding's id is `calibrate-<suite>.<rule>`.
  enum Rule: String, Sendable, CaseIterable {
    case usage
    case seedDefect = "seed-defect"
    case labelMissed = "label-missed"
    case passed
    case noSeeds = "no-seeds"
    case missingLabel = "missing-label"
    case missingInput = "missing-input"
    case missingEntry = "missing-entry"
    case invalidLabel = "invalid-label"
    case unknownAgent = "unknown-agent"
    case uncalibratedAgent = "uncalibrated-agent"
  }

  static func ruleID(_ suite: CalibrationSuite, _ rule: Rule) -> String {
    "calibrate-\(suite.rawValue).\(rule.rawValue)"
  }

  struct CaseRun: Sendable {
    let result: CalibrationRecord.CaseResult
    /// Shown as a non-gating `usage` finding, such as what the agent run cost.
    let note: String?
  }

  static func usage(_ what: String, costUSD: Double?, durationMilliseconds: Int?) -> String {
    var note = what
    if let costUSD { note += String(format: ", $%.2f", costUSD) }
    if let durationMilliseconds { note += ", \(durationMilliseconds / 1000)s" }
    return note
  }

  /// Runs up to `concurrentCases` cases at once, and judges them in seed order.
  static func run<Label>(
    root: URL, seeds: CalibrationSeeds<Label>, modelOverride: String?, now: Date,
    concurrentCases: Int = 1,
    runCase:
      @escaping @Sendable (CalibrationSeeds<Label>.Agent, CalibrationSeeds<Label>.Case)
      async throws(CalibrationCaseError) -> CaseRun
  ) async -> StaticCheckOutcome {
    let suite = Label.suite
    let unreadable = seeds.problems.compactMap { problem -> String? in
      guard case .unreadable(let path, let reason) = problem else { return nil }
      return "can't read \(path): \(reason)"
    }
    if !unreadable.isEmpty {
      return .blocked(reason: "calibrate \(suite.rawValue): " + unreadable.joined(separator: "; "))
    }
    if !seeds.problems.isEmpty {
      return checked(seeds.problems.flatMap { findings($0, suite: suite) })
    }

    var results: [CalibrationRecord.CaseResult] = []
    var notes: [Finding] = []
    var defects: [Finding] = []
    let jobs = seeds.agents.flatMap { agent in agent.cases.map { (agent: agent, seed: $0) } }
    var outcomes = [Result<CaseRun, CalibrationCaseError>?](repeating: nil, count: jobs.count)
    await withTaskGroup(of: (Int, Result<CaseRun, CalibrationCaseError>).self) { group in
      var next = 0
      var inFlight = 0
      // A blocked case means the environment can't answer, so no new case starts after one.
      var blocked = false
      while true {
        while !blocked, next < jobs.count, inFlight < max(concurrentCases, 1) {
          let index = next
          let job = jobs[index]
          group.addTask {
            do throws(CalibrationCaseError) {
              return (index, .success(try await runCase(job.agent, job.seed)))
            } catch {
              return (index, .failure(error))
            }
          }
          next += 1
          inFlight += 1
        }
        guard let (index, outcome) = await group.next() else { break }
        inFlight -= 1
        outcomes[index] = outcome
        if case .failure(.blocked) = outcome { blocked = true }
      }
    }
    for (job, outcome) in zip(jobs, outcomes) {
      switch outcome {
      case .success(let run):
        results.append(run.result)
        if let note = run.note {
          notes += make(suite, .usage, .nit, file: job.seed.directory, note)
        }
      case .failure(.seedDefect(let reason)):
        defects += make(
          suite, .seedDefect, .major, file: job.seed.directory,
          "\(job.agent.name)/\(job.seed.name): \(reason)")
      case .failure(.blocked(let reason)):
        return .blocked(
          reason: "calibrate \(suite.rawValue): \(job.agent.name)/\(job.seed.name): \(reason)")
      case nil:
        return .blocked(
          reason: "calibrate \(suite.rawValue): \(job.agent.name)/\(job.seed.name) never finished")
      }
    }

    var missed: [Finding] = defects
    for result in results {
      for answer in result.answers where !answer.met {
        let margin =
          answer.answered == answer.expected
          ? ", below the \(String(format: "%.2f", CalibrationRecord.QuestionResult.passMargin)) "
            + "a judged answer needs"
          : ""
        missed += make(
          suite, .labelMissed, .major,
          file: "\(suite.seedsDirectory)/\(result.agent)/\(result.caseName)",
          "\(result.agent)/\(result.caseName) on \(result.model): `\(answer.question)` answered "
            + "`\(answer.answered)` (p=\(String(format: "%.2f", answer.probability))\(margin)), "
            + "label expects `\(answer.expected)`")
      }
    }
    if !missed.isEmpty { return checked(missed + notes) }

    let hashed: [CalibrationHash.File]
    do {
      hashed = try CalibrationHash.discover(root: root, suite: suite)
    } catch {
      return .blocked(
        reason: "calibrate \(suite.rawValue): can't read the \(suite.rawValue) prompts to hash: "
          + "\(error)")
    }
    let record = CalibrationRecord(
      contentHash: CalibrationHash.hash(hashed), hashedFiles: hashed.map(\.path),
      modelOverride: modelOverride, passedAt: now, cases: results)
    do {
      try record.encoded().write(to: root.appending(path: suite.recordPath), options: .atomic)
    } catch {
      return .blocked(
        reason: "calibrate \(suite.rawValue): can't write \(suite.recordPath): \(error)")
    }
    let agents = Set(results.map(\.agent)).count
    return checked(
      make(
        suite, .passed, .nit, file: suite.recordPath,
        "\(results.count) case(s) across \(agents) agent(s) met every label; recorded content "
          + "hash \(record.contentHash)"
          + (modelOverride.map {
            " on the `--model \($0)` override, which push never counts as fresh"
          } ?? " with each agent on its own model")) + notes)
  }

  private static func checked(_ findings: [Finding]) -> StaticCheckOutcome {
    .checked(RuleRunResult(findings: findings, allowances: []))
  }

  /// Every argument here is non-empty by construction, so the report contract can't reject it.
  private static func make(
    _ suite: CalibrationSuite, _ rule: Rule, _ severity: Severity, file: String,
    _ message: String
  ) -> [Finding] {
    guard
      let finding = try? Finding(
        ruleID: ruleID(suite, rule), severity: severity, file: file, line: nil,
        message: message, failureScenario: nil)
    else { return [] }
    return [finding]
  }

  private static func findings<Label>(
    _ problem: CalibrationSeeds<Label>.Problem, suite: CalibrationSuite
  ) -> [Finding] {
    let layout = "see \(suite.seedsDirectory)/README.md"
    return switch problem {
    case .noSeeds(let path):
      make(
        suite, .noSeeds, .major, file: path,
        "no calibration seeds: nothing to calibrate (\(layout))")
    case .missingLabel(let path):
      make(
        suite, .missingLabel, .major, file: path,
        "case \(path) has no \(CalibrationSuite.labelFile) (\(layout))")
    case .missingInput(let path):
      make(
        suite, .missingInput, .major, file: path,
        "case \(path) has no \(CalibrationSuite.inputFile) (\(layout))")
    case .missingEntry(let path):
      make(suite, .missingEntry, .major, file: path, "case entry \(path) is missing (\(layout))")
    case .invalidLabel(let path, let reason):
      make(suite, .invalidLabel, .major, file: path, "\(path): \(reason)")
    case .unknownAgent(let path):
      make(
        suite, .unknownAgent, .major, file: path,
        "seeds in \(path) name no \(suite.agentsDescription) agent")
    case .uncalibratedAgent(let path):
      make(
        suite, .uncalibratedAgent, .major, file: path,
        "\(path) has no calibration case under \(suite.seedsDirectory)")
    case .unreadable: []
    }
  }
}
