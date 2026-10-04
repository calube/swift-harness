import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain

/// What `plan import` did with a brownfield plan's `PLAN.md`.
struct PlanImportReport: Sendable, Equatable, Encodable {
  enum Status: String, Sendable, Encodable {
    case imported
    /// `PLAN.md` doesn't parse into a schedulable ledger; nothing was written.
    case invalid
    /// The clone, its config or its plan state couldn't be read or written.
    case blocked
  }

  var plan: String
  var status: Status = .blocked
  var verdict: Verdict = .blocked
  var tasks: Int?
  var waves: Int?
  /// Whether this import appended the `PLAN.md` line to `info/exclude`; `nil` before that step.
  var excludeAdded: Bool?
  /// The plan's `index.json` status after the import; `nil` before that step.
  var indexStatus: PlanStatus?
  var assumptions: [String] = []
  /// What became of the contract task `--contract` named; `nil` without the flag.
  var contract: ContractRecord?
  var message = ""

  /// The contract task `--contract` named, and whether its gate run made it `done`.
  struct ContractRecord: Sendable, Equatable, Encodable {
    enum Status: String, Sendable, Encodable {
      case done, pending
    }

    var task: String
    var runId: String
    var status: Status
    /// The contract commit recorded as the task's only commit; `nil` while it stays pending.
    var commit: String?
    var message: String
  }

  private enum CodingKeys: String, CodingKey {
    case command, plan, status, verdict, tasks, waves, excludeAdded, indexStatus, assumptions,
      contract, message
  }

  /// Every key is always present; an absent value is `null`.
  func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(PlanImportRun.command, forKey: .command)
    try c.encode(plan, forKey: .plan)
    try c.encode(status, forKey: .status)
    try c.encode(verdict, forKey: .verdict)
    try c.encode(tasks, forKey: .tasks)
    try c.encode(waves, forKey: .waves)
    try c.encode(excludeAdded, forKey: .excludeAdded)
    try c.encode(indexStatus, forKey: .indexStatus)
    try c.encode(assumptions, forKey: .assumptions)
    try c.encode(contract, forKey: .contract)
    try c.encode(message, forKey: .message)
  }
}

/// `plan import`'s behaviour, apart from argument parsing so tests drive it against a temp clone.
enum PlanImportRun {
  static let command = "plan import"

  /// Reads `<common>/swift-harness/plans/<slug>/PLAN.md`, writes `ledger.json` and `plan.json`
  /// beside it, links `<root>/PLAN.md` to it and excludes that link once, then sets the plan's
  /// `index.json` entry to `planned` under the index lock unless it is already planned or past
  /// it. Nothing is written
  /// unless the clone is brownfield, the plan parses and the link's place is free or already
  /// the link.
  /// The contract task and the gate run of its commit, from `--contract` and `--contract-run`.
  struct Contract: Sendable, Equatable {
    let task: String
    let runID: String
  }

  static func run(
    slug: String, root: URL, git: any Git, contract: Contract? = nil
  ) async -> PlanImportReport {
    var report = PlanImportReport(plan: slug)
    let common: String
    do {
      common = try await git.commonDirectory()
    } catch {
      report.message = "resolving the git common dir: \(error)"
      return report
    }
    let plan: PlanStateLayout.Plan
    do {
      plan = try PlanStateLayout(commonDirectory: common).plan(slug)
    } catch {
      report.message = "`\(slug)` is not a plan name: \(error)"
      return report
    }
    let files = FileManager.default

    let configPath = URL(filePath: common).appending(path: StateRootResolver.commonConfigFile).path
    guard let configData = files.contents(atPath: configPath) else {
      report.message =
        "\(configPath) is missing, so this is not a brownfield clone; plan import derives a "
        + "brownfield plan's ledger only. Run `swiftgate discover --apply` first"
      return report
    }
    let config: BrownfieldConfig
    do {
      config = try TOMLConfigDecoder().decodeBrownfield(String(decoding: configData, as: UTF8.self))
    } catch {
      report.message = "\(configPath) doesn't load: \(error)"
      return report
    }
    let presetName = BrownfieldConfigSchema.profileName
    guard let preset = config.buildPresets[presetName] else {
      report.message =
        "\(configPath) has no [build.presets.\(presetName)], so the ledger's max_parallel is unknown"
      return report
    }

    let livePath = plan.directory + "/" + PlanFile.LivePlanSource.fileName
    guard let liveData = files.contents(atPath: livePath) else {
      report.message = "\(livePath) is missing; write the plan there before importing it"
      return report
    }
    let livePlan: LivePlan
    do throws(LivePlanError) {
      livePlan = try LivePlanParser.parse(String(decoding: liveData, as: UTF8.self))
    } catch {
      return invalid(report, error, livePath)
    }

    var landing: ContractLanding.Outcome?
    if let contract {
      guard livePlan.tasks.contains(where: { $0.id == contract.task }) else {
        report.status = .invalid
        report.verdict = .red
        report.message =
          "--contract `\(contract.task)` names no task in \(livePath); nothing was written"
        return report
      }
      landing = await contractLanding(contract, slug: slug, common: common, git: git)
    }

    let link = root.appending(path: PlanFile.LivePlanSource.fileName).path
    if let refusal = linkRefusal(at: link, target: livePath) {
      report.message = refusal
      return report
    }

    let store = PlanStateStore(plan: plan)
    let lease: LockLease
    do {
      lease = try await FileCountingLock(
        directory: URL(filePath: plan.directory, directoryHint: .isDirectory),
        name: "ledger.lock", capacity: 1, pollInterval: .milliseconds(5)
      ).acquire(timeout: .seconds(30))
    } catch {
      report.message = "taking the ledger lock in \(plan.directory): \(error)"
      return report
    }
    defer { lease.release() }

    let existingLedger: Ledger?
    let existingPlan: PlanFile?
    do throws(PlanStateStoreError) {
      existingLedger = try optional { () throws(PlanStateStoreError) in try store.ledger() }
      existingPlan = try optional { () throws(PlanStateStoreError) in try store.planFile() }
    } catch {
      report.message = "reading the plan's current state: \(error)"
      return report
    }
    if let existingPlan, existingPlan.livePlanSource == nil {
      report.message =
        "\(plan.planFile) belongs to a design or spec-page plan; plan import replaces only a "
        + "live plan's state, so it was left as it is"
      return report
    }

    var worktrees: [String: String] = [:]
    do throws(GitWorkspaceError) {
      for task in livePlan.tasks {
        worktrees[task.id] =
          try TaskWorktree(
            commonDirectory: common, plan: slug, task: task.id, profile: .brownfield
          ).path
      }
    } catch {
      report.message = "naming the task worktrees: \(error)"
      return report
    }
    var ledger: Ledger
    do throws(LivePlanError) {
      // `ledger` asks only for the ids of `livePlan.tasks`, each named above.
      ledger = try livePlan.ledger(maxParallel: preset.maxParallel, existing: existingLedger) {
        worktrees[$0] ?? ""
      }
    } catch {
      return invalid(report, error, livePath)
    }
    if let contract, let landing {
      switch recordContract(contract, landing, in: &ledger, plan: plan) {
      case .success(let record): report.contract = record
      case .failure(let failure):
        report.message = failure.message
        return report
      }
    }
    let planFile = livePlan.planFile(slug: slug, resume: ledger.resume, existing: existingPlan)
    do {
      // Each file is written beside the old one and renamed over it: a reader sees one whole
      // file or the other.
      try LedgerJSON.encode(ledger).write(to: URL(filePath: plan.ledgerFile), options: .atomic)
      try PlanFileJSON.encode(planFile).write(to: URL(filePath: plan.planFile), options: .atomic)
    } catch {
      report.message = "writing the plan's state in \(plan.directory): \(error)"
      return report
    }

    do {
      if (try? files.destinationOfSymbolicLink(atPath: link)) == nil {
        try files.createSymbolicLink(atPath: link, withDestinationPath: livePath)
      }
    } catch {
      report.message = "linking \(link) to \(livePath): \(error)"
      return report
    }
    let exclude = URL(filePath: common).appending(path: "info/exclude")
    do {
      let current = files.contents(atPath: exclude.path).map { String(decoding: $0, as: UTF8.self) }
      if let updated = LivePlanExclude.adding(to: current) {
        try files.createDirectory(
          at: exclude.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(updated.utf8).write(to: exclude, options: .atomic)
        report.excludeAdded = true
      } else {
        report.excludeAdded = false
      }
    } catch {
      report.message = "adding \(LivePlanExclude.line) to \(exclude.path): \(error)"
      return report
    }

    let indexFile: String
    do {
      indexFile = try PlanStateLayout(commonDirectory: common).indexFile
    } catch {
      report.message = "placing index.json under \(common): \(error)"
      return report
    }
    // A plan already planned, building or finished keeps its status: importing again adds a
    // fix task to a running build, which `build next` picks up without a second `build start`.
    var kept: Result<PlanStatus, IndexEntryUnknown> = .success(.planned)
    do {
      try await PlanIndexStore(path: indexFile).update { index in
        guard let current = index.plans.first(where: { $0.slug == slug }) else {
          return index.settingStatus(
            slug: slug, status: PlanStatus.planned.rawValue, resume: planFile.resume)
        }
        guard let status = PlanStatus(rawValue: current.status) else {
          kept = .failure(IndexEntryUnknown(status: current.status))
          return index
        }
        guard status.importSetsPlanned else {
          kept = .success(status)
          return index
        }
        return index.settingStatus(
          slug: slug, status: PlanStatus.planned.rawValue, resume: planFile.resume)
      }
    } catch {
      report.message =
        "\(plan.ledgerFile) and \(plan.planFile) written, but setting \(indexFile) to planned "
        + "failed: \(error)"
      return report
    }
    switch kept {
    case .success(let status): report.indexStatus = status
    case .failure(let unknown):
      report.message =
        "\(plan.ledgerFile) and \(plan.planFile) written, but \(indexFile) holds `\(slug)` at "
        + "`\(unknown.status)`, which is not a plan status; it was left as it is"
      return report
    }

    report.status = .imported
    report.verdict = report.contract?.status == .pending ? .red : .green
    report.tasks = ledger.tasks.count
    report.waves = ledger.waves.count
    report.assumptions = livePlan.assumptions
    report.message =
      "\(ledger.tasks.count) tasks in \(ledger.waves.count) waves; \(plan.ledgerFile) and "
      + "\(plan.planFile) written"
      + (report.contract.map { "; contract `\($0.task)` \($0.status.rawValue): \($0.message)" }
        ?? "")
    return report
  }

  /// Reads the contract's gate run from the plan checkout's history and the plan branch's tip.
  /// Neither failing to read is fatal to the import: the contract just stays pending, saying why.
  private static func contractLanding(
    _ contract: Contract, slug: String, common: String, git: any Git
  ) async -> ContractLanding.Outcome {
    let branch = BrownfieldRunReport.planBranch(slug: slug)
    let tip: String?
    do {
      tip = try await git.revision(branch)
    } catch {
      return .pending(reason: "reading the tip of \(branch): \(error)")
    }
    let checkout: String
    do throws(GitWorkspaceError) {
      checkout = try TaskWorktree.planCheckout(commonDirectory: common, plan: slug)
    } catch {
      return .pending(reason: "naming the plan checkout: \(error)")
    }
    let runs = RunStore(worktreeRoot: URL(filePath: checkout, directoryHint: .isDirectory))
    let history: [RunHistoryRecord]
    do throws(RunStoreError) {
      history = try runs.readHistory().records
    } catch {
      return .pending(reason: "reading \(runs.historyFile.path): \(error)")
    }
    return ContractLanding.outcome(
      task: contract.task, runID: contract.runID, history: history, planBranch: branch,
      planBranchTip: tip)
  }

  /// Sets a pending contract task `done` in `ledger` once its return is written to the plan's
  /// pre-build returns, which `build start` copies into the run. A task already `done` keeps its
  /// return; one in any other status stays where it is.
  private static func recordContract(
    _ contract: Contract, _ landing: ContractLanding.Outcome, in ledger: inout Ledger,
    plan: PlanStateLayout.Plan
  ) -> Result<PlanImportReport.ContractRecord, ContractWriteFailure> {
    var record = PlanImportReport.ContractRecord(
      task: contract.task, runId: contract.runID, status: .pending, commit: nil, message: "")
    guard let index = ledger.tasks.firstIndex(where: { $0.id == contract.task }) else {
      record.message = "the ledger has no task `\(contract.task)`"
      return .success(record)
    }
    let task = ledger.tasks[index]
    switch (landing, task.status) {
    case (.pending(let reason), _):
      record.message = reason
      return .success(record)
    case (.done, .done):
      record.status = .done
      record.message = "already done; its return was kept"
      return .success(record)
    case (.done(let taskReturn), .pending):
      let file = URL(filePath: plan.returnsDirectory, directoryHint: .isDirectory)
        .appending(path: "\(contract.task).json")
      do {
        try FileManager.default.createDirectory(
          at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try TaskReturnJSON.encode(taskReturn).write(to: file, options: .atomic)
      } catch {
        return .failure(
          ContractWriteFailure(message: "writing the contract's return \(file.path): \(error)"))
      }
      ledger = ledger.setting(status: .done, ofTaskAt: index)
      record.status = .done
      record.commit = taskReturn.commits.first
      record.message = taskReturn.notes
      return .success(record)
    case (.done, let status):
      record.message =
        "the task is \(status.rawValue), and only a pending task takes a landed contract"
      return .success(record)
    }
  }

  /// Why `link` can't become the plan's link: something other than that link already sits there.
  private static func linkRefusal(at link: String, target: String) -> String? {
    if let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: link) {
      return destination == target
        ? nil : "\(link) is a link to \(destination), not to \(target); move it and import again"
    }
    guard FileManager.default.fileExists(atPath: link) else { return nil }
    return "\(link) already exists and is not the plan's link; move it and import again"
  }

  private static func optional<T>(_ read: () throws(PlanStateStoreError) -> T)
    throws(PlanStateStoreError) -> T?
  {
    do {
      return try read()
    } catch .missing {
      return nil
    }
  }

  private static func invalid(_ report: PlanImportReport, _ error: LivePlanError, _ path: String)
    -> PlanImportReport
  {
    var report = report
    report.status = .invalid
    report.verdict = .red
    report.message = "\(path): \(error.message); nothing was written"
    return report
  }

  static func render(_ report: PlanImportReport, json: Bool) -> String {
    guard json else { return "\(command): \(report.verdict.rawValue) \(report.message)" }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return String(decoding: (try? encoder.encode(report)) ?? Data(), as: UTF8.self)
  }
}

private struct IndexEntryUnknown: Error {
  let status: String
}

private struct ContractWriteFailure: Error {
  let message: String
}

extension Ledger {
  /// This ledger with the task at `index` moved to `status` and nothing else changed.
  fileprivate func setting(status: TaskStatus, ofTaskAt index: Int) -> Ledger {
    var tasks = self.tasks
    let task = tasks[index]
    tasks[index] = LedgerTask(
      id: task.id, deps: task.deps, writeSet: task.writeSet, gate: task.gate, tests: task.tests,
      covers: task.covers, estLines: task.estLines, status: status, worktree: task.worktree,
      actualLines: task.actualLines, model: task.model, branch: task.branch)
    return Ledger(
      schemaVersion: schemaVersion, resume: resume, maxParallel: maxParallel, tasks: tasks,
      waves: waves)
  }
}

extension PlanStatus {
  /// Whether `plan import` moves a plan at this status to `planned`: only one not planned yet.
  fileprivate var importSetsPlanned: Bool {
    switch self {
    case .designing, .inReview, .approved: true
    case .planned, .building, .done, .abandoned, .superseded: false
    }
  }
}

/// `swiftgate plan import <slug>`: derives a brownfield plan's ledger and plan file from its
/// `PLAN.md`.
struct PlanImportCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "import",
    abstract:
      "Write a brownfield plan's ledger.json and plan.json from its PLAN.md, and index it as "
      + "planned.")

  @Argument(help: "The plan's slug.")
  var slug: String

  @Option(help: "The contract task, already landed on the plan branch; needs --contract-run.")
  var contract: String?

  @Option(help: "The GREEN gate run, in the plan checkout, of the contract commit.")
  var contractRun: String?

  @Flag(help: "Print JSON.")
  var json = false

  func validate() throws {
    guard (contract == nil) == (contractRun == nil) else {
      throw ValidationError("--contract and --contract-run go together")
    }
  }

  func run() async throws {
    let root = URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
    var named: PlanImportRun.Contract?
    if let contract, let contractRun {
      named = PlanImportRun.Contract(task: contract, runID: contractRun)
    }
    let report = await PlanImportRun.run(
      slug: slug, root: root, git: LiveGit(runner: LiveProcessRunner(), repositoryRoot: root.path),
      contract: named)
    Console.write(PlanImportRun.render(report, json: json))
    if report.verdict != .green { throw ExitCode(report.verdict.exitCode) }
  }
}
