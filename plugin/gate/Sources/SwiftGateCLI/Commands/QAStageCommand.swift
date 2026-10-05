import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain

/// What `qa stage` put in a worktree's prepared folder.
struct QAStageReport: Sendable, Equatable, Encodable {
  var worktree: String
  var plan: String
  var requirement: String
  var verdict: Verdict = .blocked
  /// The prepared folder it filled, `.harness/qa/<plan>/` under the worktree.
  var destination: String = ""
  /// Each check file it copied there, by name, in table order.
  var files: [String] = []
  var message = ""

  private enum CodingKeys: String, CodingKey {
    case command, worktree, plan, requirement, verdict, destination, files, message
  }

  func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(QAStageRun.command, forKey: .command)
    try c.encode(worktree, forKey: .worktree)
    try c.encode(plan, forKey: .plan)
    try c.encode(requirement, forKey: .requirement)
    try c.encode(verdict, forKey: .verdict)
    try c.encode(destination, forKey: .destination)
    try c.encode(files, forKey: .files)
    try c.encode(message, forKey: .message)
  }
}

/// `qa stage`'s behaviour, apart from argument parsing so tests drive it against a temp
/// repository: the reverse of `qa adopt`, for a flow repair round.
enum QAStageRun {
  static let command = "qa stage"

  /// Replaces `worktree`'s prepared folder with 1 plan folder holding `requirement`'s adopted
  /// check files from plan state, permissions kept, so the orchestrator copies no store file.
  static func run(
    worktree: String, plan: String, requirement: String, root: URL, git: any Git,
    runner: any ProcessRunner
  ) async -> QAStageReport {
    var report = QAStageReport(worktree: worktree, plan: plan, requirement: requirement)
    func refused(_ message: String) -> QAStageReport {
      var refusal = report
      refusal.verdict = .red
      refusal.message = message + "; nothing was staged"
      return refusal
    }
    let files = FileManager.default
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
    let state: PlanStateLayout.Plan
    do {
      state = try PlanStateLayout(commonDirectory: try await git.commonDirectory()).plan(plan)
    } catch {
      report.message = "resolving plan `\(plan)`'s state directory: \(error)"
      return report
    }
    let tablePath = state.directory + "/" + ValidationTable.fileName
    let table: ValidationTable
    do {
      guard let data = files.contents(atPath: tablePath) else {
        report.message = "\(tablePath) is missing"
        return report
      }
      table = try ValidationTableJSON.decode(data)
    } catch {
      report.message = "\(tablePath) doesn't read: \(error)"
      return report
    }
    var names: [String] = []
    for row in table.rows where row.requirement == requirement {
      guard let name = QAFlowRepair.preparedName(row.check), !names.contains(name) else {
        continue
      }
      names.append(name)
    }
    guard !names.isEmpty else {
      return refused(
        "no row of \(tablePath) checks `\(requirement)` with a \(QAReport.directory)/ file")
    }
    let adopted = URL(filePath: state.directory, directoryHint: .isDirectory)
      .appending(path: QAReport.directory, directoryHint: .isDirectory)
    let absent = names.filter { !files.fileExists(atPath: adopted.appending(path: $0).path) }
    guard absent.isEmpty else {
      return refused(
        "\(adopted.path) lacks \(absent.joined(separator: ", ")), which `\(requirement)`'s "
          + "rows check")
    }
    let preparedRoot = URL(filePath: target, directoryHint: .isDirectory)
      .appending(path: QAAdoptRun.preparedDirectory, directoryHint: .isDirectory)
    let destination = preparedRoot.appending(path: plan, directoryHint: .isDirectory)
    report.destination = destination.path
    do {
      if files.fileExists(atPath: preparedRoot.path) { try files.removeItem(at: preparedRoot) }
      try files.createDirectory(at: destination, withIntermediateDirectories: true)
      for name in names {
        try files.copyItem(at: adopted.appending(path: name), to: destination.appending(path: name))
      }
    } catch {
      report.message =
        "staging `\(requirement)`'s checks into \(destination.path): \(error); remove "
        + "\(preparedRoot.path) before a repair worker starts there"
      return report
    }
    report.verdict = .green
    report.files = names
    report.message =
      "staged \(names.count) check file(s) of `\(requirement)` in \(destination.path)"
    return report
  }

  static func render(_ report: QAStageReport, json: Bool) -> String {
    guard json else {
      return
        (["\(command): \(report.verdict.rawValue) \(report.message)"]
        + report.files.map { "  \($0)" }).joined(separator: "\n")
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return String(decoding: (try? encoder.encode(report)) ?? Data(), as: UTF8.self)
  }
}

/// `swiftgate qa stage <worktree> --plan <slug> --requirement <requirement> [--json]`.
struct QAStageCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "stage",
    abstract:
      "Fill a checkout's .harness/qa/ with 1 requirement's adopted checks from plan state, for a "
      + "flow repair.",
    discussion:
      "Removes the checkout's .harness/qa/, then copies each check file the plan's "
      + "validation.json rows for the requirement name from the plan's qa/"
      + " into .harness/qa/<plan>/, keeping each file's permissions. Copies nothing unless the "
      + "checkout is one `git worktree list` names and every file is in plan state. Exits 0 "
      + "when it filled the folder, 1 when it refused, and 2 when plan state can't be read.")

  @Argument(help: "A checkout of this repository, such as a fix worktree.")
  var worktree: String

  @Option(help: "The slug of the plan whose adopted checks it copies.")
  var plan: String

  @Option(help: "The requirement whose rows' check files it copies.")
  var requirement: String

  @Flag(help: "Print JSON.")
  var json = false

  func run() async throws {
    let root = URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
    let runner = LiveProcessRunner()
    let report = await QAStageRun.run(
      worktree: worktree, plan: plan, requirement: requirement, root: root,
      git: LiveGit(runner: runner, repositoryRoot: root.path), runner: runner)
    Console.write(QAStageRun.render(report, json: json))
    if report.verdict != .green { throw ExitCode(report.verdict.exitCode) }
  }
}
