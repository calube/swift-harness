import ArgumentParser
import Darwin
import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import Synchronization

/// `qa run`'s behaviour, apart from argument parsing so tests drive it against a temp repository.
enum QARunRun {
  static let command = "qa run"
  /// How long 1 check may run before it is stopped and reads `red`.
  static let checkTimeout: Duration = .seconds(600)

  struct Options: Sendable, Equatable {
    var plan: String?
    var after: String?
    var atBase = false
    /// Every ready row, with each flow recorded and its logs saved.
    var final = false
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
    /// The device flow rows run on; `nil` leaves every flow row `unverified`.
    var flows: (any QAFlowSimulating)?
    /// The plugin root `qa lint` reads the pinned step schemas from.
    var pluginRoot: URL?
    /// What `--final` adds around each flow.
    var finalPass: QAFinalPass?
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
      planDirectory: plan.directory, qaDirectory: qaDirectory, dependencies: dependencies,
      runID: runID, plan: runPlan, atBase: options.atBase,
      flows: dependencies.flows.map { QAFlowRunner(simulator: $0) })

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
    let flowRecords = await checks.flowRecords()

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
          }
            + rows.compactMap { row in
              flowRecords[row.row].map { record in
                HarnessEvent(
                  eventID: dependencies.newEventID(), time: time, runID: runID, head: commit,
                  source: HarnessEventSource(route: nil),
                  payload: .qaFlow(
                    QAFlowEvent(
                      plan: slug, row: row.row, requirement: row.requirement,
                      atBase: options.atBase, record: record)))
              }
            })
      } catch {
        notes.append("qa.check and qa.flow events not written: \(error)")
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

  /// Runs 1 row's check and saves what it printed: an acceptance or state row's command or
  /// script, or a flow row through ``QAFlowRunner``.
  private struct Checks: Sendable {
    let planDirectory: String
    let qaDirectory: URL
    let dependencies: Dependencies
    let runID: String
    let plan: QARunPlan
    let atBase: Bool
    let flows: QAFlowRunner?
    /// State rows a flow row already ran on its device, by row.
    let stateResults = StateResults()

    final class StateResults: Sendable {
      private let results = Mutex<[Int: QACheckOutcome]>([:])

      func store(_ outcome: QACheckOutcome, row: Int) {
        results.withLock { $0[row] = outcome }
      }

      func take(row: Int) -> QACheckOutcome? {
        results.withLock { $0.removeValue(forKey: row) }
      }
    }

    func flowRecords() async -> [Int: QAFlowRecord] {
      await flows?.records ?? [:]
    }

    func run(_ entry: QARunPlan.Entry, in workingDirectory: String) async -> QACheckOutcome {
      let row = entry.validation
      if row.layer == .flow {
        return await flow(entry, in: workingDirectory)
      }
      if row.layer == .state, let ran = stateResults.take(row: entry.row) {
        return ran
      }
      return await command(entry, in: workingDirectory, device: [:])
    }

    /// The ready state rows the flow row `entry` runs on its device: its requirement's, when no
    /// later flow row has the same requirement.
    private func stateRows(of entry: QARunPlan.Entry) -> [QARunPlan.Entry] {
      let requirement = entry.validation.requirement
      let later = plan.entries.drop { $0.row != entry.row }.dropFirst()
        .filter { $0.validation.requirement == requirement }
      guard !later.contains(where: { $0.validation.layer == .flow }) else { return [] }
      return later.filter { $0.validation.layer == .state && $0.waitingOn.isEmpty }
    }

    private func flow(_ entry: QARunPlan.Entry, in workingDirectory: String) async
      -> QACheckOutcome
    {
      guard let flows else {
        return QACheckOutcome(result: .unverified, message: QARunPlan.flowRunnerMissing)
      }
      let row = entry.validation
      let stepsFile = URL(filePath: planDirectory).appending(path: row.check)
      let worktree = URL(filePath: workingDirectory, directoryHint: .isDirectory)
      let lint = QALintRun.run(
        files: [stepsFile.path], root: worktree, pluginRoot: dependencies.pluginRoot)
      let name = String(Self.evidenceName(entry).dropLast(".txt".count))
      let states = stateRows(of: entry)
      return await flows.run(
        QAFlowRow(
          row: entry.row, requirement: row.requirement, stepsFile: stepsFile, worktree: worktree,
          directory: qaDirectory.appending(path: name, directoryHint: .isDirectory),
          relativeDirectory: "\(QAReport.directory)/\(name)", runID: "\(runID)-row\(entry.row)",
          atBase: atBase),
        lint: lint
      ) { device in
        for state in states {
          stateResults.store(
            await command(state, in: workingDirectory, device: device), row: state.row)
        }
      }
    }

    /// Runs an acceptance row's command or a state row's script, with `device`'s variables
    /// when its flow's device is up.
    private func command(
      _ entry: QARunPlan.Entry, in workingDirectory: String, device: [String: String]
    ) async -> QACheckOutcome {
      let row = entry.validation
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
          ].merging(device, uniquingKeysWith: { own, _ in own }), timeout: dependencies.timeout))

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
        }, flows: LiveQAFlowSimulator(runner: runner),
        pluginRoot: ProcessInfo.processInfo.environment[QALintRun.harnessRootVariable].map {
          URL(filePath: $0, directoryHint: .isDirectory)
        }))
    Console.write(QARunRun.render(report, json: json))
    if report.verdict != .green { throw ExitCode(report.verdict.exitCode) }
  }
}

/// `sim up`, `sim verify` and `sim down` as their commands run them, for the tree a flow row runs
/// in: the checkout, or a scratch tree at the merge base.
struct LiveQAFlowSimulator: QAFlowSimulating {
  let runner: any ProcessRunner
  let agentDevice: any AgentDevice

  init(runner: any ProcessRunner) {
    self.runner = runner
    self.agentDevice = LiveAgentDevice(runner: runner)
  }

  /// `qa run` starts each holder itself and outlives it, so a holder that exited stays a zombie
  /// child, which `kill(pid, 0)` still finds, until it is reaped here.
  @Sendable static func isAlive(_ pid: Int32) -> Bool {
    var status: Int32 = 0
    if waitpid(pid, &status, WNOHANG) == pid { return false }
    return SimulatorClones.processIsAlive(pid)
  }

  func up(_ request: QAFlowSimulatorRequest) async -> Result<SimUpStarted, SimUpFailure> {
    let root = request.worktree
    let config: Config
    do {
      guard let loaded = try ConfigLoader().load(repositoryRoot: root) else {
        return .failure(
          SimUpFailure(rule: .environment, message: "no \(ConfigLoader.fileName) in \(root.path)"))
      }
      config = loaded
    } catch {
      return .failure(
        SimUpFailure(rule: .environment, message: "\(ConfigLoader.fileName) doesn't load: \(error)")
      )
    }
    let maxConcurrent = config.simulator.maxConcurrent
    let dependencies = SimUp.Dependencies(
      agentDevice: agentDevice,
      leases: SimLeaseStore(directory: SimLeaseStore.defaultDirectory()),
      launcher: DetachedLauncher(), xcodebuild: LiveXcodebuild(runner: runner),
      simctl: LiveSimctl(
        runner: runner,
        timeouts: LiveSimctl.Timeouts(quick: .seconds(config.simulator.simctlTimeoutSeconds))),
      bundles: AppBundleReader(), git: LiveGit(runner: runner, repositoryRoot: root.path),
      isAlive: Self.isAlive, terminate: { _ = kill($0, SIGTERM) },
      slotHolders: {
        SimUp.liveSlotHolders(
          lockDirectory: FileCountingLock.defaultDirectory(), capacity: maxConcurrent)
      }, clock: .continuous(),
      now: { Date() })  // swiftgate:allow det.date-init — the CLI edge stamps when the run started
    return await SimUp(dependencies: dependencies).run(
      SimUp.Request(
        worktree: root, config: config, scenario: request.scenario, runID: request.runID,
        simDirectory: request.simDirectory,
        derivedDataPath: SimUpCommand.derivedDataDirectory(root: root).path,
        swiftgateExecutable: Bundle.main.executablePath ?? CommandLine.arguments[0]))
  }

  func verify(_ request: QAFlowSimulatorRequest) async -> Result<SimVerified, SimVerifyFailure> {
    let root = request.worktree
    let checkoutHead: SimCheckoutHead
    do {
      let sha = try await LiveGit(runner: runner, repositoryRoot: root.path).revision("HEAD")
      checkoutHead = sha.map { .commit($0) } ?? .unreadable("HEAD names no commit yet")
    } catch {
      checkoutHead = .unreadable(String(describing: error))
    }
    let simDirectory = request.simDirectory
    return SimVerify(
      dependencies: SimVerify.Dependencies(
        leases: SimLeaseStore(directory: SimLeaseStore.defaultDirectory()),
        isAlive: Self.isAlive, clock: .continuous(),
        now: { Date() })  // swiftgate:allow det.date-init — the history line's finish time
    ).run(
      SimVerify.Request(
        worktree: CanonicalPath.of(root), runID: request.runID, checkoutHead: checkoutHead,
        simDirectory: { _ in simDirectory },
        historyFile: StateRootResolver.resolve(worktree: root)
          .url(RunLayout.historyFile, directoryHint: .notDirectory)))
  }

  func down(_ request: QAFlowSimulatorRequest) async -> Result<SimDowned, SimDownFailure> {
    let simDirectory = request.simDirectory
    return await SimDown(
      dependencies: SimDown.Dependencies(
        agentDevice: agentDevice,
        leases: SimLeaseStore(directory: SimLeaseStore.defaultDirectory()),
        simctl: LiveSimctl(runner: runner),
        crashReports: CrashReportReader(directory: CrashReportReader.defaultDirectory()),
        isAlive: Self.isAlive, clock: .continuous())
    ).run(
      SimDown.Request(
        worktree: CanonicalPath.of(request.worktree), runID: request.runID,
        simDirectory: { _ in simDirectory }))
  }
}
