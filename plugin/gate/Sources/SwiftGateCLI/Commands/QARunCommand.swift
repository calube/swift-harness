import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain

/// `qa run`'s behaviour, apart from argument parsing so tests drive it against a temp repository.
enum QARunRun {
  static let command = "qa run"
  /// How long 1 check may run before it is stopped and reads `red`.
  static let checkTimeout: Duration = .seconds(600)

  struct Options: Sendable, Equatable {
    var plan: String?
    var after: String?
    var atBase = false
  }

  struct Dependencies: Sendable {
    var checks: any QACheckRunning
    var ports: any QAPortAssigning
    /// `nil` makes scratch trees beside the repository, as `prove` does.
    var scratch: (any ScratchWorktrees)?
    /// `nil` writes through the checkout's telemetry setting.
    var events: (any HarnessEventWriting)?
    var now: @Sendable () -> Date
    var runIDSuffix: @Sendable () -> UInt32
    var newEventID: @Sendable () -> String
    var timeout: Duration = QARunRun.checkTimeout
  }

  /// Reads the plan's `validation.json` and ledger from the git common dir, runs the rows the
  /// plan picks in `root` (or, with `--at-base`, in a scratch tree at the merge base), and writes
  /// `qa/report.json` under a new run and 1 `qa.check` event per row.
  static func run(root: URL, options: Options, git: any Git, dependencies: Dependencies) async
    -> QAReport
  {
    func blocked(_ message: String, plan: String? = options.plan) -> QAReport {
      .blocked(message, plan: plan, after: options.after, atBase: options.atBase)
    }
    let common: String
    let layout: PlanStateLayout
    do {
      common = try await git.commonDirectory()
      layout = try PlanStateLayout(commonDirectory: common)
    } catch {
      return blocked("resolving the plan state directory: \(error)")
    }
    let files = FileManager.default

    let slug: String
    if let named = options.plan {
      slug = named
    } else {
      let candidates: [String]
      do {
        candidates = try QAFiles.subdirectories(of: URL(filePath: layout.root)).filter {
          files.fileExists(atPath: "\(layout.root)/\($0)/\(ValidationTable.fileName)")
        }
      } catch {
        return blocked("listing the plans in \(layout.root): \(error)")
      }
      switch candidates.count {
      case 0:
        return .nothingToRun(
          "no plan under \(layout.root) holds a \(ValidationTable.fileName), so no row runs",
          plan: nil, after: options.after, atBase: options.atBase)
      case 1:
        slug = candidates[0]
      default:
        return blocked(
          "\(candidates.count) plans hold a \(ValidationTable.fileName): "
            + candidates.joined(separator: ", ") + "; name 1 with --plan")
      }
    }
    let plan: PlanStateLayout.Plan
    do {
      plan = try layout.plan(slug)
    } catch {
      return blocked("`\(slug)` is not a plan name")
    }
    guard files.fileExists(atPath: plan.directory) else {
      return blocked("no plan `\(slug)` under \(layout.root)", plan: slug)
    }
    let tablePath = plan.directory + "/" + ValidationTable.fileName
    guard let tableData = files.contents(atPath: tablePath) else {
      return .nothingToRun(
        "\(tablePath) is missing: the plan has no validation table, so no row runs", plan: slug,
        after: options.after, atBase: options.atBase)
    }
    let table: ValidationTable
    do throws(ValidationTableJSONError) {
      table = try ValidationTableJSON.decode(tableData)
    } catch {
      return blocked("\(tablePath) doesn't read: \(error)", plan: slug)
    }

    var merged: Set<String>?
    if !options.atBase || options.after != nil {
      let ledger: Ledger
      do throws(PlanStateStoreError) {
        ledger = try PlanStateStore(plan: plan).ledger()
      } catch {
        return blocked("reading \(plan.ledgerFile): \(error)", plan: slug)
      }
      if let after = options.after, !ledger.tasks.contains(where: { $0.id == after }) {
        return blocked(
          "--after `\(after)` names no task in \(plan.ledgerFile); no row ran", plan: slug)
      }
      if !options.atBase {
        merged = Set(ledger.tasks.filter { $0.status == .done }.map(\.id))
      }
    }
    let runPlan = QARunPlan.make(table: table, merged: merged, after: options.after)

    let runID = RunID.make(startedAt: dependencies.now(), suffix: dependencies.runIDSuffix())
    let qaDirectory: URL
    do {
      qaDirectory = try RunStore(worktreeRoot: root).runDirectory(for: runID)
        .appending(path: QAReport.directory, directoryHint: .isDirectory)
      try files.createDirectory(at: qaDirectory, withIntermediateDirectories: true)
    } catch {
      return blocked("making the run directory for \(runID): \(error)", plan: slug)
    }
    let checks = Checks(
      planDirectory: plan.directory, qaDirectory: qaDirectory, dependencies: dependencies)

    var notes: [String] = []
    let rows: [QARow]
    let commit: String?
    if options.atBase {
      let main =
        BuildPresetCatalog.profile(root: root) == .brownfield
        ? BrownfieldRunReport.planBranch(slug: slug) : TaskWorktree.base
      let base: String
      do {
        guard let found = try await git.mergeBase("HEAD", main) else {
          return blocked("HEAD and \(main) share no commit, so there is no merge base", plan: slug)
        }
        base = found
      } catch {
        return blocked("finding the merge base of HEAD and \(main): \(error)", plan: slug)
      }
      let scratch =
        dependencies.scratch
        ?? LiveScratchWorktrees(runner: LiveProcessRunner(), repositoryRoot: root.path)
      do throws(ScratchWorktreeError) {
        rows = try await scratch.withScratchTree(
          ScratchTreeRequest(revision: base, revertTo: base, copiedPaths: [], revertedPaths: [])
        ) { tree in
          await runPlan.execute(atBase: true) { await checks.run($0, in: tree.path) }
        }
      } catch {
        return blocked("making a scratch worktree at \(base): \(error)", plan: slug)
      }
      commit = base
    } else {
      do {
        commit = try await git.revision("HEAD")
      } catch {
        commit = nil
        notes.append("the report names no commit: reading HEAD failed: \(error)")
      }
      rows = await runPlan.execute(atBase: false) { await checks.run($0, in: root.path) }
    }

    let events = dependencies.events ?? TelemetryOptIn.writer(root: root)
    if let events {
      let time = dependencies.now()
      do {
        try events.append(
          contentsOf: rows.map { row in
            HarnessEvent(
              eventID: dependencies.newEventID(), time: time, runID: runID, head: commit,
              source: HarnessEventSource(route: nil),
              payload: .qaCheck(QACheckEvent(plan: slug, row: row, atBase: options.atBase)))
          })
      } catch {
        notes.append("qa.check events not written: \(error)")
      }
    } else {
      notes.append("qa.check events not written: \(root.path) has no config that loads")
    }

    let report = QAReport(
      runID: runID, plan: slug, after: options.after, atBase: options.atBase, commit: commit,
      rows: rows, notes: notes)
    let reportFile = qaDirectory.appending(path: QAReport.fileName)
    do {
      let data: Data
      do {
        data = try QAReportJSON.encode(report)
      } catch {
        throw QAFilesError(path: reportFile.path, reason: "encoding: \(error)")
      }
      try QAFiles.write(data, to: reportFile)
    } catch {
      return report.adding(notes: ["\(QAReport.fileName) not written: \(error)"])
    }
    return report
  }

  /// Runs 1 acceptance or state row's check and saves what it printed.
  private struct Checks: Sendable {
    let planDirectory: String
    let qaDirectory: URL
    let dependencies: Dependencies

    func run(_ entry: QARunPlan.Entry, in workingDirectory: String) async -> QACheckOutcome {
      let row = entry.validation
      if row.layer == .flow {
        return QACheckOutcome(result: .unverified, message: QARunPlan.flowRunnerMissing)
      }
      let port: Int
      do {
        port = try dependencies.ports.assignPort()
      } catch {
        return QACheckOutcome(
          result: .unverified, message: "not run: no port for QA_PORT: \(error)")
      }
      let script = URL(filePath: planDirectory).appending(path: row.check).path
      var isDirectory: ObjCBool = false
      let program: QACheckRequest.Program =
        !row.check.hasPrefix("/")
          && FileManager.default.fileExists(atPath: script, isDirectory: &isDirectory)
          && !isDirectory.boolValue
        ? .script(path: script) : .command(row.check)
      let output = await dependencies.checks.run(
        QACheckRequest(
          program: program, workingDirectory: workingDirectory,
          environment: [
            "QA_PORT": "\(port)", "QA_DIR": planDirectory + "/qa",
            "QA_EVIDENCE_DIR": qaDirectory.path,
          ], timeout: dependencies.timeout))

      let result: QAResult
      let status: String
      var exitStatus: Int?
      switch output.exit {
      case .exited(let code):
        exitStatus = Int(code)
        result = code == 0 ? .pass : .red
        status = "exit \(code)"
      case .signaled(let signal):
        result = .red
        status = "killed by signal \(signal)"
      case .timedOut(let after):
        result = .red
        status = "timed out after \(after)"
      case .launchFailed(let reason):
        result = .unverified
        status = "not started: \(reason)"
      }
      let name = Self.evidenceName(entry)
      let text =
        "$ \(row.check)\nQA_PORT=\(port)\nexit: \(exitStatus.map(String.init) ?? status)\n"
        + "--- stdout ---\n\(output.stdout)\n--- stderr ---\n\(output.stderr)\n"
      var message = status
      var evidence: [String] = []
      do {
        try QAFiles.write(Data(text.utf8), to: qaDirectory.appending(path: name))
        evidence = ["\(QAReport.directory)/\(name)"]
      } catch {
        message += "; its output wasn't saved: \(error)"
      }
      return QACheckOutcome(
        result: result, message: message, exitStatus: exitStatus,
        milliseconds: Self.milliseconds(output.elapsed), evidence: evidence)
    }

    /// `<NN>-<requirement>.<layer>.txt`, with any character a file name shouldn't hold as `-`.
    static func evidenceName(_ entry: QARunPlan.Entry) -> String {
      let number = entry.row < 10 ? "0\(entry.row)" : "\(entry.row)"
      let requirement = String(
        entry.validation.requirement.map { character in
          character.isASCII
            && (character.isLetter || character.isNumber || "-_".contains(character))
            ? character : "-"
        })
      return "\(number)-\(requirement).\(entry.validation.layer.rawValue).txt"
    }

    static func milliseconds(_ duration: Duration) -> Int {
      let parts = duration.components
      return Int(parts.seconds) * 1000 + Int(parts.attoseconds / 1_000_000_000_000_000)
    }
  }

  static func render(_ report: QAReport, json: Bool) -> String {
    guard !json else {
      return String(decoding: (try? QAReportJSON.encode(report)) ?? Data(), as: UTF8.self)
    }
    var lines = ["\(command): \(report.verdict.rawValue) \(report.message)"]
    for row in report.rows {
      lines.append(
        "  row \(row.row) \(row.requirement) \(row.layer.rawValue): \(row.result.rawValue), "
          + row.message)
    }
    if let runID = report.runID { lines.append("  run: \(runID)") }
    lines += report.notes.map { "  note: \($0)" }
    return lines.joined(separator: "\n")
  }
}

/// `swiftgate qa run [--plan <slug>] [--after <task>] [--at-base] [--json]`.
struct QARunCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "run",
    abstract: "Run the validation rows whose tasks have merged: acceptance, then flow, then state.")

  @Option(help: "The plan's slug; defaults to the 1 plan holding a validation.json.")
  var plan: String?

  @Option(help: "Run only the rows that name this task in Runs after, taking it as merged.")
  var after: String?

  @Flag(help: "Run every row at the merge base in a scratch worktree and record why each fails.")
  var atBase = false

  @Flag(help: "Print JSON.")
  var json = false

  func run() async throws {
    let root = URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
    let runner = LiveProcessRunner()
    let report = await QARunRun.run(
      root: root, options: QARunRun.Options(plan: plan, after: after, atBase: atBase),
      git: LiveGit(runner: runner, repositoryRoot: root.path),
      dependencies: QARunRun.Dependencies(
        checks: QACommandRunner(runner: runner), ports: LiveQAPorts(), scratch: nil, events: nil,
        now: { Date() },  // swiftgate:allow det.date-init — the CLI edge stamps when the run ran
        runIDSuffix: {
          UInt32.random(in: .min ... .max)  // swiftgate:allow det.random — a unique run id
        },
        newEventID: {
          UUID().uuidString  // swiftgate:allow det.uuid-init — an event id need only be unique
        }))
    Console.write(QARunRun.render(report, json: json))
    if report.verdict != .green { throw ExitCode(report.verdict.exitCode) }
  }
}
