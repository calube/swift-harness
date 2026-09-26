import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateRules

struct CalibrateCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "calibrate",
    abstract: "Run an agent against labelled seeds and judge it against the labels.",
    subcommands: [CalibrateDesignCommand.self])
}

struct CalibrateDesignCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "design",
    abstract: "Run the design agents against labelled seeds and report per-agent pass/fail (§12).",
    discussion:
      "Runs every agents/<agent>.md with seeds under \(DesignCalibrationLayout.seedsDirectory)/"
      + "<agent>/<case>/ through `claude -p`, the agent's prompt as the system prompt. When every "
      + "label is met it writes \(DesignCalibrationLayout.recordPath) with the content hash of "
      + "agents/design-*.md and workflows/design-*.js. Exit 0 all labels met (record written), "
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

/// Loads the seeds, runs every case, and writes the pass record only when nothing missed. Seed
/// defects stop the run before any agent is called, so a broken seed set costs nothing.
enum CalibrateDesignRun {
  static func run(root: URL, runner: any ProcessRunner, model: String, now: Date) async
    -> StaticCheckOutcome
  {
    let seeds = DesignCalibrationSeeds.load(root: root)
    let unreadable = seeds.problems.compactMap { problem -> String? in
      guard case .unreadable(let path, let reason) = problem else { return nil }
      return "can't read \(path): \(reason)"
    }
    if !unreadable.isEmpty {
      return .blocked(reason: "calibrate design: " + unreadable.joined(separator: "; "))
    }
    if !seeds.problems.isEmpty {
      return checked(seeds.problems.flatMap(findings))
    }

    let calibration = DesignCalibrationRunner(runner: runner, model: model)
    var results: [CalibrationRecord.CaseResult] = []
    for agent in seeds.agents {
      for seed in agent.cases {
        do {
          results.append(try await calibration.run(agent: agent, seed: seed))
        } catch {
          return .blocked(reason: "calibrate design: \(agent.name)/\(seed.name): \(error)")
        }
      }
    }

    var missed: [Finding] = []
    for result in results {
      for answer in result.answers where answer.answered != answer.expected {
        missed += make(
          "label-missed", .major,
          file: "\(DesignCalibrationLayout.seedsDirectory)/\(result.agent)/\(result.caseName)",
          "\(result.agent)/\(result.caseName): `\(answer.question)` answered `\(answer.answered)` "
            + "(p=\(String(format: "%.2f", answer.probability))), label expects "
            + "`\(answer.expected)`")
      }
    }
    if !missed.isEmpty { return checked(missed) }

    let hashed: [DesignCalibrationHash.File]
    do {
      hashed = try DesignCalibrationHash.discover(root: root)
    } catch {
      return .blocked(reason: "calibrate design: can't read the design prompts to hash: \(error)")
    }
    let record = CalibrationRecord(
      contentHash: DesignCalibrationHash.hash(hashed), hashedFiles: hashed.map(\.path),
      model: calibration.model, passedAt: now, cases: results)
    do {
      try record.encoded().write(
        to: root.appending(path: DesignCalibrationLayout.recordPath), options: .atomic)
    } catch {
      return .blocked(
        reason: "calibrate design: can't write \(DesignCalibrationLayout.recordPath): \(error)")
    }
    let agents = Set(results.map(\.agent)).count
    return checked(
      make(
        "passed", .nit, file: DesignCalibrationLayout.recordPath,
        "\(results.count) case(s) across \(agents) agent(s) met every label; recorded content "
          + "hash \(record.contentHash)"))
  }

  private static func checked(_ findings: [Finding]) -> StaticCheckOutcome {
    .checked(RuleRunResult(findings: findings, allowances: []))
  }

  /// Every argument here is non-empty by construction, so the report contract can't reject it.
  private static func make(_ rule: String, _ severity: Severity, file: String, _ message: String)
    -> [Finding]
  {
    guard
      let finding = try? Finding(
        ruleID: "calibrate-design.\(rule)", severity: severity, file: file, line: nil,
        message: message, failureScenario: nil)
    else { return [] }
    return [finding]
  }

  private static func findings(_ problem: DesignCalibrationSeeds.Problem) -> [Finding] {
    let layout = "see \(DesignCalibrationLayout.seedsDirectory)/README.md"
    return switch problem {
    case .noSeeds(let path):
      make(
        "no-seeds", .major, file: path, "no calibration seeds: nothing to calibrate (\(layout))")
    case .missingLabel(let path):
      make(
        "missing-label", .major, file: path,
        "case \(path) has no \(DesignCalibrationLayout.labelFile) (\(layout))")
    case .missingInput(let path):
      make(
        "missing-input", .major, file: path,
        "case \(path) has no \(DesignCalibrationLayout.inputFile) (\(layout))")
    case .invalidLabel(let path, let reason):
      make("invalid-label", .major, file: path, "\(path): \(reason)")
    case .unknownAgent(let path):
      make(
        "unknown-agent", .major, file: path, "seeds in \(path) name no agents/design-*.md agent")
    case .uncalibratedAgent(let path):
      make(
        "uncalibrated-agent", .major, file: path,
        "\(path) has no calibration case under \(DesignCalibrationLayout.seedsDirectory)")
    case .unreadable: []
    }
  }
}
