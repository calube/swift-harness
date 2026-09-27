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
      + "<agent>/<case>/ through `claude -p`, the agent's prompt as the system prompt. When every "
      + "label is met it writes \(DesignCalibrationLayout.recordPath) with the content hash of "
      + "\(DesignCalibrationLayout.agentsDirectory)/design-*.md and "
      + "\(DesignCalibrationLayout.workflowsDirectory)/design-*.js. Exit 0 all labels met (record written), "
      + "1 on a missed label or a seed defect (record untouched), 2 when claude can't run or "
      + "answer, or a seed can't be read.")

  @Option(help: "The Claude model every agent runs on.")
  var model: String = JudgeFactory.defaultModel

  @OptionGroup var output: OutputOptions

  func run() async throws {
    let root = URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
    let now = Date()  // swiftgate:allow det.date-init — the CLI edge stamps when the pass ran
    try await StaticCheckRun.execute(root: root, format: output.format) {
      await CalibrateDesignRun.run(
        root: root, runner: LiveProcessRunner(), model: model, now: now)
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
      + "the refs it moved, a fixer's resolution, and the seed's acceptance tests. When every "
      + "label is met it writes \(CalibrationSuite.build.recordPath) with the content hash of "
      + "\(CalibrationSuite.build.agentsDescription). Exit 0 all labels met (record written), 1 "
      + "on a missed label or a seed defect (record untouched), 2 when git, swift or claude "
      + "can't run, or a seed can't be read. Costs a real agent run per case.")

  @Option(help: "The Claude model for an agent whose frontmatter pins none.")
  var model: String = JudgeFactory.defaultModel

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
      defaultModel: model, agentTimeout: .seconds(timeoutMinutes * 60))
    try await StaticCheckRun.execute(root: root, format: output.format) {
      await CalibrateBuildRun.run(root: root, calibration: calibration, now: now)
    }
  }
}

/// Loads the design seeds and asks each agent its label's questions through the judge.
enum CalibrateDesignRun {
  static func run(root: URL, runner: any ProcessRunner, model: String, now: Date) async
    -> StaticCheckOutcome
  {
    let calibration = DesignCalibrationRunner(runner: runner, model: model)
    return await CalibrationRun.run(
      root: root, seeds: DesignCalibrationSeeds.load(root: root), model: calibration.model,
      now: now
    ) { agent, seed throws(CalibrationCaseError) in
      do {
        return .init(result: try await calibration.run(agent: agent, seed: seed), note: nil)
      } catch {
        throw .blocked("\(error)")
      }
    }
  }
}

/// Loads the build seeds and runs each agent on its seeded repository.
enum CalibrateBuildRun {
  static func run(root: URL, calibration: BuildCalibrationRunner, now: Date) async
    -> StaticCheckOutcome
  {
    let seeds = BuildCalibrationSeeds.load(root: root)
    let models = seeds.agents.map { "\($0.name)=\(calibration.model(of: $0))" }.sorted()
    return await CalibrationRun.run(
      root: root, seeds: seeds, model: models.joined(separator: ", "), now: now
    ) { agent, seed throws(CalibrationCaseError) in
      let run = try await calibration.run(agent: agent, seed: seed)
      var note = "\(agent.name)/\(seed.name) on \(calibration.model(of: agent))"
      if let cost = run.costUSD { note += String(format: ", $%.2f", cost) }
      if let duration = run.durationMilliseconds { note += ", \(duration / 1000)s" }
      if let sandbox = run.sandbox { note += "; its repository is kept at \(sandbox)" }
      return .init(result: run.result, note: note)
    }
  }
}

/// What every suite shares: seed defects stop the run before any agent is called, so a broken
/// seed set costs nothing; the pass record is written only when nothing missed.
enum CalibrationRun {
  struct CaseRun {
    let result: CalibrationRecord.CaseResult
    /// Shown as a non-gating `usage` finding, such as what the agent run cost.
    let note: String?
  }

  static func run<Label>(
    root: URL, seeds: CalibrationSeeds<Label>, model: String, now: Date,
    runCase: (CalibrationSeeds<Label>.Agent, CalibrationSeeds<Label>.Case)
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
    for agent in seeds.agents {
      for seed in agent.cases {
        do throws(CalibrationCaseError) {
          let run = try await runCase(agent, seed)
          results.append(run.result)
          if let note = run.note {
            notes += make(suite, "usage", .nit, file: seed.directory, note)
          }
        } catch {
          switch error {
          case .seedDefect(let reason):
            defects += make(
              suite, "seed-defect", .major, file: seed.directory,
              "\(agent.name)/\(seed.name): \(reason)")
          case .blocked(let reason):
            return .blocked(
              reason: "calibrate \(suite.rawValue): \(agent.name)/\(seed.name): \(reason)")
          }
        }
      }
    }

    var missed: [Finding] = defects
    for result in results {
      for answer in result.answers where answer.answered != answer.expected {
        missed += make(
          suite, "label-missed", .major,
          file: "\(suite.seedsDirectory)/\(result.agent)/\(result.caseName)",
          "\(result.agent)/\(result.caseName): `\(answer.question)` answered `\(answer.answered)` "
            + "(p=\(String(format: "%.2f", answer.probability))), label expects "
            + "`\(answer.expected)`")
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
      model: model, passedAt: now, cases: results)
    do {
      try record.encoded().write(to: root.appending(path: suite.recordPath), options: .atomic)
    } catch {
      return .blocked(
        reason: "calibrate \(suite.rawValue): can't write \(suite.recordPath): \(error)")
    }
    let agents = Set(results.map(\.agent)).count
    return checked(
      make(
        suite, "passed", .nit, file: suite.recordPath,
        "\(results.count) case(s) across \(agents) agent(s) met every label; recorded content "
          + "hash \(record.contentHash)") + notes)
  }

  private static func checked(_ findings: [Finding]) -> StaticCheckOutcome {
    .checked(RuleRunResult(findings: findings, allowances: []))
  }

  /// Every argument here is non-empty by construction, so the report contract can't reject it.
  private static func make(
    _ suite: CalibrationSuite, _ rule: String, _ severity: Severity, file: String,
    _ message: String
  ) -> [Finding] {
    guard
      let finding = try? Finding(
        ruleID: "calibrate-\(suite.rawValue).\(rule)", severity: severity, file: file, line: nil,
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
        suite, "no-seeds", .major, file: path,
        "no calibration seeds: nothing to calibrate (\(layout))")
    case .missingLabel(let path):
      make(
        suite, "missing-label", .major, file: path,
        "case \(path) has no \(CalibrationSuite.labelFile) (\(layout))")
    case .missingInput(let path):
      make(
        suite, "missing-input", .major, file: path,
        "case \(path) has no \(CalibrationSuite.inputFile) (\(layout))")
    case .missingEntry(let path):
      make(suite, "missing-entry", .major, file: path, "case entry \(path) is missing (\(layout))")
    case .invalidLabel(let path, let reason):
      make(suite, "invalid-label", .major, file: path, "\(path): \(reason)")
    case .unknownAgent(let path):
      make(
        suite, "unknown-agent", .major, file: path,
        "seeds in \(path) name no \(suite.agentsDescription) agent")
    case .uncalibratedAgent(let path):
      make(
        suite, "uncalibrated-agent", .major, file: path,
        "\(path) has no calibration case under \(suite.seedsDirectory)")
    case .unreadable: []
    }
  }
}
