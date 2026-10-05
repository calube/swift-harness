import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain

/// What `qa adopt` did with a worktree's prepared checks.
struct QAAdoptReport: Sendable, Equatable, Encodable {
  /// 1 plan's `qa/` folder copied into plan state.
  struct Adopted: Sendable, Equatable, Encodable {
    var plan: String
    var files: Int
    var destination: String
  }

  var worktree: String
  var verdict: Verdict = .blocked
  var adopted: [Adopted] = []
  /// The repair a `--repair` adopt took; `nil` otherwise, or when it took none.
  var repaired: QAFlowRepairRecord?
  /// Why a `--repair` adopt took nothing.
  var findings: [Finding] = []
  var message = ""

  private enum CodingKeys: String, CodingKey {
    case command, worktree, verdict, adopted, repaired, findings, message
  }

  func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(QAAdoptRun.command, forKey: .command)
    try c.encode(worktree, forKey: .worktree)
    try c.encode(verdict, forKey: .verdict)
    try c.encode(adopted, forKey: .adopted)
    try c.encode(repaired, forKey: .repaired)
    try c.encode(findings, forKey: .findings)
    try c.encode(message, forKey: .message)
  }
}

/// What `qa adopt --repair` takes: 1 requirement's rewritten checks, and why.
struct QAAdoptRepair: Sendable, Equatable {
  var requirement: String
  var buildRun: String
  var cause: QAFlowRepair.Cause
  var reason: String
  /// The `qa run`s that read the row red before the repair.
  var redRuns: [String]
}

/// `qa adopt`'s behaviour, apart from argument parsing so tests drive it against a temp repository.
enum QAAdoptRun {
  static let command = "qa adopt"
  /// Where a validation worker leaves its checks in its worktree, 1 folder per plan.
  static let preparedDirectory = RunLayout.treePath(RunLayout.qaPreparedDirectory)

  /// Copies nothing unless `worktree` is a checkout `git worktree list` names and every plan
  /// folder it holds names a plan that exists, so a refusal never leaves half an adoption.
  static func run(worktree: String, root: URL, git: any Git, runner: any ProcessRunner) async
    -> QAAdoptReport
  {
    var report = QAAdoptReport(worktree: worktree)
    func refused(_ message: String) -> QAAdoptReport {
      var refusal = report
      refusal.verdict = .red
      refusal.message = message + "; nothing was copied"
      return refusal
    }
    let target = CanonicalPath.of(URL(filePath: worktree, relativeTo: root))
    let checkouts: [String]
    do {
      checkouts = try await QACheckouts(runner: runner, repositoryRoot: root.path).paths()
    } catch {
      report.message = "listing this repository's checkouts: \(error)"
      return report
    }
    guard checkouts.contains(target) else {
      return refused(
        "\(target) is not a checkout of this repository: `git worktree list` names "
          + checkouts.joined(separator: ", "))
    }
    let layout: PlanStateLayout
    do {
      layout = try PlanStateLayout(commonDirectory: try await git.commonDirectory())
    } catch {
      report.message = "resolving the plan state directory: \(error)"
      return report
    }
    let prepared = URL(filePath: target, directoryHint: .isDirectory)
      .appending(path: preparedDirectory, directoryHint: .isDirectory)
    let names: [String]
    do {
      names = try QAFiles.subdirectories(of: prepared)
    } catch {
      report.message = "reading \(prepared.path): \(error)"
      return report
    }
    guard !names.isEmpty else {
      return refused("\(target) holds no \(preparedDirectory)/<plan>/ folder")
    }
    var plans: [(name: String, plan: PlanStateLayout.Plan)] = []
    for name in names {
      guard let plan = try? layout.plan(name),
        FileManager.default.fileExists(atPath: plan.directory)
      else {
        return refused("\(preparedDirectory)/\(name) names no plan under \(layout.root)")
      }
      plans.append((name, plan))
    }
    for (name, plan) in plans {
      let destination = URL(filePath: plan.directory, directoryHint: .isDirectory)
        .appending(path: QAReport.directory, directoryHint: .isDirectory)
      do {
        let files = try QAFiles.replace(
          destination, withCopyOf: prepared.appending(path: name, directoryHint: .isDirectory))
        report.adopted.append(
          QAAdoptReport.Adopted(plan: name, files: files, destination: destination.path))
      } catch {
        report.message =
          "copying \(preparedDirectory)/\(name): \(error)"
          + (report.adopted.isEmpty
            ? "" : "; already adopted: " + report.adopted.map(\.plan).joined(separator: ", "))
        return report
      }
    }
    report.verdict = .green
    report.message =
      "adopted "
      + report.adopted.map { "\($0.plan) (\($0.files) files)" }.joined(separator: ", ")
    return report
  }

  /// Copies only `repair.requirement`'s checks from the worktree's prepared folder into plan
  /// state, merges their rows of the prepared `at-base-run.json` into plan state's, records the
  /// repair in `qa/repairs.json` and writes 1 `qa.repair` event, when ``QAFlowRepair`` finds
  /// nothing; otherwise copies nothing and names each finding.
  static func repair(
    _ repair: QAAdoptRepair, worktree: String, root: URL, git: any Git, runner: any ProcessRunner,
    events: (any HarnessEventWriting)?, now: @Sendable () -> Date,
    newEventID: @Sendable () -> String
  ) async -> QAAdoptReport {
    var report = QAAdoptReport(worktree: worktree)
    report.message = "qa adopt --repair is not built yet"
    return report
  }

  static func render(_ report: QAAdoptReport, json: Bool) -> String {
    guard json else { return "\(command): \(report.verdict.rawValue) \(report.message)" }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return String(decoding: (try? encoder.encode(report)) ?? Data(), as: UTF8.self)
  }
}

/// `swiftgate qa adopt <worktree> [--repair <requirement> --build-run <run> --cause <cause>
/// --reason <text> --red-run <id>...] [--json]`.
struct QAAdoptCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "adopt",
    abstract:
      "Copy a validation worktree's .harness/qa/<plan>/ into that plan's state as qa/, or 1 "
      + "requirement's repaired checks with --repair.")

  @Argument(help: "A checkout of this repository holding .harness/qa/<plan>/.")
  var worktree: String

  @Option(
    help: ArgumentHelp(
      "Take only this requirement's rewritten checks, proved red at the base by the worktree's "
        + "--prepared-by --requirement run, in place of the adopted ones."))
  var repair: String?

  @Option(help: "With --repair, the build run the repair counts against: 1 per requirement.")
  var buildRun: String?

  @Option(help: "With --repair, flow-side or still-red.")
  var cause: QAFlowRepair.Cause?

  @Option(help: "With --repair, why the flow, not the app, kept the row red.")
  var reason: String?

  @Option(help: "With --repair, a qa run that read the row red before the repair; repeat it.")
  var redRun: [String] = []

  @Flag(help: "Print JSON.")
  var json = false

  func run() async throws {
    let root = URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
    let runner = LiveProcessRunner()
    let git = LiveGit(runner: runner, repositoryRoot: root.path)
    let report: QAAdoptReport
    if let requirement = repair {
      guard let buildRun, let cause, let reason else {
        throw ValidationError("--repair needs --build-run, --cause and --reason")
      }
      report = await QAAdoptRun.repair(
        QAAdoptRepair(
          requirement: requirement, buildRun: buildRun, cause: cause, reason: reason,
          redRuns: redRun),
        worktree: worktree, root: root, git: git, runner: runner,
        events: TelemetryOptIn.writer(root: root),
        now: { Date() },  // swiftgate:allow det.date-init — the CLI edge stamps the repair
        newEventID: {
          UUID().uuidString  // swiftgate:allow det.uuid-init — an event id need only be unique
        })
    } else {
      report = await QAAdoptRun.run(worktree: worktree, root: root, git: git, runner: runner)
    }
    Console.write(QAAdoptRun.render(report, json: json))
    if report.verdict != .green { throw ExitCode(report.verdict.exitCode) }
  }
}
extension QAFlowRepair.Cause: ExpressibleByArgument {}
