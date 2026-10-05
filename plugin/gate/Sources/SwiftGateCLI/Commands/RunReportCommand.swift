import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain

/// What `run report` did.
struct RunReportOutcome: Sendable, Equatable, Encodable {
  var plan: String
  var verdict: Verdict = .blocked
  /// Where the report was written; `nil` when it wasn't.
  var path: String?
  var report: BrownfieldRunReport?
  var message = ""
  /// The run's report page, rewritten from the plan's newest build run; `nil` when none was.
  var runReport: String?
  /// Why no report page was written; `nil` when one was.
  var runReportNote: String?

  private enum CodingKeys: String, CodingKey {
    case command, plan, verdict, path, report, message, runReport, runReportNote
  }

  /// Every key is always present; an absent value is `null`.
  func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(BrownfieldRunReportRun.command, forKey: .command)
    try c.encode(plan, forKey: .plan)
    try c.encode(verdict, forKey: .verdict)
    try c.encode(path, forKey: .path)
    try c.encode(report, forKey: .report)
    try c.encode(message, forKey: .message)
    try c.encode(runReport, forKey: .runReport)
    try c.encode(runReportNote, forKey: .runReportNote)
  }
}

/// `run report`'s behaviour, apart from argument parsing so tests drive it against a temp clone.
enum BrownfieldRunReportRun {
  static let command = "run report"

  /// Reads the plan dir and its ledger, the baseline at the plan branch's base tree, the last
  /// discover record, the plan's newest build run and, for a plan with a validation table, its
  /// newest `qa run` over every row, then writes `<plan-dir>/REPORT.md`. A source that can't be
  /// read is a line in its section; only a clone with no brownfield config or no such plan
  /// writes nothing.
  /// - Parameter pluginRoot: where `viewer/` lives, for the run's report page.
  static func write(
    slug: String, planBranch: String?, base: String?, root: URL, runner: any ProcessRunner,
    pluginRoot: URL? = nil, now: Date = Date()
  ) async -> RunReportOutcome {
    var outcome = RunReportOutcome(plan: slug)
    let git = LiveGit(runner: runner, repositoryRoot: root.path)
    let layout: BrownfieldStateLayout
    do {
      layout = try await GitTrackedTree(runner: runner, directory: root).stateLayout()
    } catch {
      outcome.message = "resolving the clone's git dirs: \(error.message)"
      return outcome
    }
    let files = FileManager.default
    guard files.fileExists(atPath: layout.config.path) else {
      outcome.message =
        "\(layout.config.path) is missing, so this is not a brownfield clone; run report "
        + "closes a brownfield run"
      return outcome
    }
    let plan: PlanStateLayout.Plan
    do {
      plan = try PlanStateLayout(commonDirectory: layout.commonDir.path).plan(slug)
    } catch {
      outcome.message = "`\(slug)` is not a plan name: \(error)"
      return outcome
    }
    var isDirectory: ObjCBool = false
    guard files.fileExists(atPath: plan.directory, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      outcome.message = "\(plan.directory) doesn't exist: no plan named `\(slug)`"
      return outcome
    }

    let branch = planBranch ?? BrownfieldRunReport.planBranch(slug: slug)
    let head: String?
    do {
      head = try await git.revision("refs/heads/\(branch)")
    } catch {
      outcome.message = "reading the plan branch \(branch): \(error)"
      return outcome
    }
    let report = BrownfieldRunReport.make(
      BrownfieldRunReportInputs(
        slug: slug, planBranch: branch, planBranchHead: head,
        plan: read(plan.directory + "/" + PlanFile.LivePlanSource.fileName) { $0 },
        baseline: await baseline(
          layout: layout, base: base, branchExists: head != nil, branch: branch,
          git: git, runner: runner, root: root),
        discover: discover(layout: layout), build: await build(slug: slug, git: git),
        ledger: read(plan.ledgerFile) { try LedgerJSON.decode(Data($0.utf8)) },
        validation: files.fileExists(atPath: plan.directory + "/" + ValidationTable.fileName)
          ? QAFiles.newestWholeRun(
            plan: slug,
            runsDirectory: RunStore(worktreeRoot: root).state.url(
              RunLayout.runsDirectory, directoryHint: .isDirectory)) : nil))

    let path = plan.directory + "/" + BrownfieldRunReport.fileName
    do {
      try Data(report.text.utf8).write(to: URL(filePath: path), options: .atomic)
    } catch {
      outcome.report = report
      outcome.message = "writing \(path): \(error.localizedDescription)"
      return outcome
    }
    outcome.verdict = .green
    outcome.path = path
    outcome.report = report
    outcome.message = "wrote \(path)"
    return outcome
  }

  private static func read<V>(_ path: String, decode: (String) throws -> V) -> RunReportInput<V> {
    let data: Data
    do {
      data = try Data(contentsOf: URL(filePath: path))
    } catch CocoaError.fileReadNoSuchFile {
      return .missing(path: path)
    } catch {
      return .unreadable(source: path, reason: error.localizedDescription)
    }
    do {
      return .read(try decode(String(decoding: data, as: UTF8.self)))
    } catch {
      return .unreadable(source: path, reason: "\(error)")
    }
  }

  /// The base is `base` when given, else where the plan branch left the checked-out `HEAD`,
  /// which the run never moves.
  private static func baseline(
    layout: BrownfieldStateLayout, base: String?, branchExists: Bool, branch: String,
    git: LiveGit, runner: any ProcessRunner, root: URL
  ) async -> RunReportInput<BaselineFile> {
    let commit: String
    if let base {
      commit = base
    } else {
      guard branchExists else {
        return .unreadable(
          source: "baseline",
          reason: "the base tree is unknown: \(branch) doesn't exist and no --base was given")
      }
      do {
        guard let found = try await git.mergeBase(branch, "HEAD") else {
          return .unreadable(
            source: "baseline", reason: "\(branch) and HEAD share no history, so no base tree")
        }
        commit = found
      } catch {
        return .unreadable(source: "baseline", reason: "git merge-base \(branch) HEAD: \(error)")
      }
    }
    let tree: String
    do {
      let output = try await runner.run(
        ProcessInvocation(
          executable: "git", arguments: ["rev-parse", "--verify", "\(commit)^{tree}"],
          workingDirectory: root.path, timeout: .seconds(60)))
      tree = output.stdout.text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard output.status.isSuccess, !tree.isEmpty else {
        return .unreadable(
          source: "baseline", reason: "git rev-parse \(commit)^{tree}: \(output.stderr.text)")
      }
    } catch {
      return .unreadable(source: "baseline", reason: "git rev-parse \(commit)^{tree}: \(error)")
    }
    let path = layout.baseline(tree: tree).path
    return read(path) { text in try BaselineFile.decode(Data(text.utf8), tree: tree) }
  }

  private static func discover(layout: BrownfieldStateLayout) -> RunReportInput<DiscoverRecord> {
    do {
      guard let record = try BrownfieldConfigWriter(layout: layout).readLastDiscover() else {
        return .missing(path: layout.discoverLast.path)
      }
      return .read(record)
    } catch {
      return .unreadable(source: layout.discoverLast.path, reason: error.message)
    }
  }

  private static func build(slug: String, git: LiveGit) async -> RunReportInput<RunReportBuild> {
    do {
      guard let store = try await BuildRunStore.latest(plan: slug, git: git) else {
        let common = (try? await git.commonDirectory()) ?? "the git common dir"
        return .missing(path: "\(common)/swift-harness/plans/\(slug)/build")
      }
      let log = try store.events()
      return .read(
        RunReportBuild(
          record: try store.record(), log: log,
          returns: returns(in: store.layout.directory + "/returns", log: log),
          cutoff: read(store.layout.directory + "/" + CutoffRecord.fileName) {
            try CutoffRecord.decode(Data($0.utf8))
          }))
    } catch {
      return .unreadable(source: "the plan's build runs", reason: "\(error)")
    }
  }

  /// Each `<task>.json` under `directory`, by task id. A listing that fails for a reason other
  /// than a missing directory marks every task the log names unreadable, so no task reads as
  /// having stored nothing.
  private static func returns(in directory: String, log: BuildEventLog)
    -> [String: RunReportInput<TaskReturn>]
  {
    let names: [String]
    do {
      names = try FileManager.default.contentsOfDirectory(atPath: directory)
    } catch CocoaError.fileReadNoSuchFile {
      return [:]
    } catch {
      let tasks = log.events.compactMap { event -> String? in
        switch event {
        case .merge(let merge): merge.task
        case .transition(let transition): transition.task
        case .undo, .gate, .returnCheck, .finish: nil
        }
      }
      return Dictionary(
        tasks.map { ($0, .unreadable(source: directory, reason: error.localizedDescription)) },
        uniquingKeysWith: { first, _ in first })
    }
    var found: [String: RunReportInput<TaskReturn>] = [:]
    for name in names where name.hasSuffix(".json") {
      found[String(name.dropLast(".json".count))] = read(directory + "/" + name) {
        try TaskReturnJSON.decode(Data($0.utf8))
      }
    }
    return found
  }

  static func render(_ outcome: RunReportOutcome, json: Bool) -> String {
    guard json else {
      guard let report = outcome.report, outcome.verdict == .green else {
        return "\(command): \(outcome.verdict.rawValue) \(outcome.message)"
      }
      return report.text
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return String(decoding: (try? encoder.encode(outcome)) ?? Data(), as: UTF8.self)
  }
}

/// `swiftgate run report <slug>`: renders a run's end-of-run report into its plan dir and prints
/// it.
struct RunReportCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "report",
    abstract: "Write and print the end-of-run report of a brownfield plan.")

  @Argument(help: "The plan's slug.")
  var slug: String

  @Option(help: "The plan branch to merge; defaults to the one `swiftgate run` names.")
  var planBranch: String?

  @Option(help: "The commit the plan branch started at; defaults to its merge base with HEAD.")
  var base: String?

  @Flag(help: "Print JSON.")
  var json = false

  func run() async throws {
    let root = URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
    let outcome = await BrownfieldRunReportRun.write(
      slug: slug, planBranch: planBranch, base: base, root: root, runner: LiveProcessRunner())
    Console.write(BrownfieldRunReportRun.render(outcome, json: json))
    if outcome.verdict != .green { throw ExitCode(outcome.verdict.exitCode) }
  }
}
