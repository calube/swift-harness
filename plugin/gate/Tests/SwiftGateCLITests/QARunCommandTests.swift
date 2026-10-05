import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Synchronization
import Testing

@testable import SwiftGateCLI

/// A throwaway owned repository on `main` with 1 commit, and 1 plan's state under its git common
/// dir: a ledger, a validation table and a `qa/` folder.
struct QARepo {
  static let slug = "2026-10-04-drafts"
  static let environment = [
    "PATH": "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin",
    "HOME": TestTemporaryDirectory.sharedHome.path,
    "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
    "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.com",
    "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.com",
  ]

  let root: URL
  let runner = LiveProcessRunner(baseEnvironment: QARepo.environment)

  init() async throws {
    root = TestTemporaryDirectory.root
      .appending(path: "swiftgate-qa-run-\(UUID().uuidString)", directoryHint: .isDirectory)
      .resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try await git("init", "-q", "-b", "main")
    try await git("config", "commit.gpgsign", "false")
    try Data(".harness/\n".utf8).write(to: root.appending(path: ".gitignore"))
    try Data("base\n".utf8).write(to: root.appending(path: "app.txt"))
    try await git("add", "-A")
    try await git("commit", "-q", "-m", "base")
    try FileManager.default.createDirectory(
      at: planDirectory.appending(path: "qa", directoryHint: .isDirectory),
      withIntermediateDirectories: true)
  }

  func remove() { TestTemporaryDirectory.remove(root) }

  var planDirectory: URL { planDirectory(Self.slug) }

  func planDirectory(_ slug: String) -> URL {
    root.appending(path: ".git/swift-harness/plans/\(slug)", directoryHint: .isDirectory)
  }

  /// Writes the ledger with each task at its status, and the table.
  func plan(
    _ rows: [ValidationRow], tasks: [String: TaskStatus], slug: String = QARepo.slug
  ) throws {
    let directory = planDirectory(slug)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let ids = tasks.keys.sorted()
    let ledger = Ledger(
      schemaVersion: 1, resume: "", maxParallel: 2,
      tasks: ids.map { id in
        LedgerTask(
          id: id, deps: [], writeSet: [], gate: .push, tests: [], covers: [], estLines: 10,
          status: tasks[id] ?? .pending, worktree: root.path + "-" + id)
      }, waves: [ids])
    try LedgerJSON.encode(ledger).write(to: directory.appending(path: "ledger.json"))
    try ValidationTableJSON.encode(ValidationTable(rows: rows)).write(
      to: directory.appending(path: ValidationTable.fileName))
  }

  /// Writes `text` at `qa/<name>` in the plan's folder.
  func qaFile(_ name: String, _ text: String, executable: Bool = false) throws {
    let url = planDirectory.appending(path: "qa/\(name)")
    try Data(text.utf8).write(to: url)
    if executable {
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
  }

  func run(
    _ options: QARunRun.Options, events: MemoryEventLog = MemoryEventLog(),
    suffix: UInt32 = 0xabc, checks: (any QACheckRunning)? = nil,
    xcresults: (any XcresultReader)? = nil, deadline: QARunDeadline? = nil
  ) async -> QAReport {
    var dependencies = QARunRun.Dependencies(
      checks: checks ?? QACommandRunner(runner: runner), ports: LiveQAPorts(),
      scratch: LiveScratchWorktrees(runner: runner, repositoryRoot: root.path),
      events: events, now: { Date(timeIntervalSince1970: 1_800_000_000) },
      runIDSuffix: { suffix }, newEventID: { UUID().uuidString }, timeout: .seconds(120))
    dependencies.merger = LiveMergeRunner(runner: runner)
    if let xcresults { dependencies.xcresults = xcresults }
    dependencies.deadline = deadline
    return await QARunRun.run(
      root: root, options: options, git: LiveGit(runner: runner, repositoryRoot: root.path),
      dependencies: dependencies)
  }

  func runDirectory(_ report: QAReport) throws -> URL {
    root.appending(path: ".harness/runs/\(try #require(report.runID))", directoryHint: .isDirectory)
  }

  /// The text of a row's first evidence file.
  func evidence(_ report: QAReport, row: Int) throws -> String {
    let entry = try #require(report.rows.first { $0.row == row })
    let path = try #require(entry.evidence.first)
    return try String(contentsOf: try runDirectory(report).appending(path: path), encoding: .utf8)
  }

  @discardableResult
  func git(_ arguments: String...) async throws -> String {
    let output = try await runner.run(
      ProcessInvocation(
        executable: "git", arguments: arguments, workingDirectory: root.path,
        timeout: .seconds(30)))
    try #require(output.status.isSuccess, "git \(arguments): \(output.stderr.text)")
    return output.stdout.text.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

func validationRow(
  _ requirement: String, _ layer: ValidationLayer, _ check: String, after: [String]
) -> ValidationRow {
  ValidationRow(
    requirement: requirement, layer: layer, check: check, runsAfter: after, writer: "validation")
}

private let toolsPresent = ["/usr/bin/python3", "/usr/bin/curl", "/usr/bin/jq"].allSatisfy {
  FileManager.default.isExecutableFile(atPath: $0)
}

@Suite("qa run")
struct QARunCommandTests {
  /// Starts a static server on `$QA_PORT` over the plan's `qa/` folder, waits for it, and asserts
  /// on its JSON with `jq -e`, as an API acceptance row does.
  static let serverCheck =
    "echo \"port=$QA_PORT\"; /usr/bin/python3 -m http.server \"$QA_PORT\" --bind 127.0.0.1 "
    + "--directory \"$QA_DIR\" >/dev/null 2>&1 & s=$!; trap 'kill $s' EXIT; "
    + "for i in $(seq 1 300); do /usr/bin/curl -fsS \"http://127.0.0.1:$QA_PORT/status.json\" "
    + "2>/dev/null | /usr/bin/jq -e '.ok == true' && exit 0; sleep 0.1; done; exit 1"

  @Test(
    "a curl | jq -e acceptance row against a server started on $QA_PORT passes, and 2 runs at once get different ports — catches a fixed port",
    .enabled(if: toolsPresent, "needs python3, curl and jq"))
  func serverOnAssignedPort() async throws {
    let repo = try await QARepo()
    defer { repo.remove() }
    try repo.plan(
      [validationRow("req-status", .acceptance, Self.serverCheck, after: ["status-api"])],
      tasks: ["status-api": .done])
    try repo.qaFile("status.json", "{\"ok\": true}\n")

    async let first = repo.run(QARunRun.Options(), suffix: 1)
    async let second = repo.run(QARunRun.Options(), suffix: 2)
    let reports = await [first, second]

    for report in reports {
      #expect(report.verdict == .green, "\(report.message)")
      #expect(report.rows.map(\.result) == [.pass])
    }
    let ports = try reports.map { report in
      try repo.evidence(report, row: 1).split(separator: "\n")
        .first { $0.hasPrefix("port=") }.map { String($0.dropFirst(5)) }
    }
    #expect(ports.allSatisfy { ($0.flatMap { Int($0) } ?? 0) > 0 }, "\(ports)")
    #expect(ports[0] != ports[1])
  }

  @Test(
    "a state script's exit 1 is red with its output and exit status saved, and an executable script runs by its own shebang — catches a failing state check read as a pass"
  )
  func stateScriptRed() async throws {
    let repo = try await QARepo()
    defer { repo.remove() }
    try repo.plan(
      [
        validationRow("req-save", .state, "qa/missing.state.sh", after: ["save-ui"]),
        validationRow("req-list", .state, "qa/list.state.sh", after: ["save-ui"]),
      ], tasks: ["save-ui": .done])
    try repo.qaFile("missing.state.sh", "echo 'draft file missing'\necho oops >&2\nexit 1\n")
    try repo.qaFile(
      "list.state.sh", "#!/bin/sh\ntest \"$QA_PORT\" -gt 0 && echo listed\n", executable: true)

    let report = await repo.run(QARunRun.Options())

    let red = try #require(report.rows.first { $0.row == 1 })
    #expect(red.result == .red)
    #expect(red.exitStatus == 1)
    let saved = try repo.evidence(report, row: 1)
    #expect(saved.contains("draft file missing"))
    #expect(saved.contains("oops"))
    #expect(saved.contains("exit: 1"))
    #expect(report.rows.first { $0.row == 2 }?.result == .pass)
    #expect(report.verdict == .red)
    #expect(report.findings.map(\.ruleID) == [QAReport.checkFailedRuleID])
  }

  @Test(
    "a screenshot file beside a row never changes its result — catches a row passed on evidence alone"
  )
  func screenshotNeverPasses() async throws {
    let repo = try await QARepo()
    defer { repo.remove() }
    try repo.plan(
      [
        validationRow("req-save", .state, "qa/save.state.sh", after: ["save-ui"]),
        validationRow("req-list", .state, "qa/list.state.sh", after: ["save-ui"]),
      ], tasks: ["save-ui": .done])
    try repo.qaFile("save.state.sh", "exit 1\n")
    try repo.qaFile("save.state.png", "PNG")
    try repo.qaFile("list.state.sh", "exit 0\n")
    try repo.qaFile("list.state.png", "PNG")

    let report = await repo.run(QARunRun.Options())

    #expect(report.rows.map(\.result) == [.red, .pass])
    #expect(report.rows.allSatisfy { $0.evidence.allSatisfy { !$0.hasSuffix(".png") } })
  }

  @Test(
    "a row whose task the ledger hasn't marked done reads waiting and runs nothing, while --after counts its task merged — catches a check run before its code merged"
  )
  func waitingUntilMerged() async throws {
    let repo = try await QARepo()
    defer { repo.remove() }
    try repo.plan(
      [validationRow("req-save", .acceptance, "touch ran-$QA_PORT; exit 0", after: ["save-ui"])],
      tasks: ["save-ui": .inProgress])

    let waiting = await repo.run(QARunRun.Options())
    let after = await repo.run(QARunRun.Options(after: "save-ui"), suffix: 2)

    #expect(waiting.rows.map(\.result) == [.waiting])
    #expect(waiting.rows.first?.waitingOn == ["save-ui"])
    #expect(waiting.rows.first?.evidence == [])
    #expect(waiting.verdict == .green)
    #expect(after.rows.map(\.result) == [.pass])
    let ran = try FileManager.default.contentsOfDirectory(atPath: repo.root.path)
      .filter { $0.hasPrefix("ran-") }
    #expect(ran.count == 1)
  }

  @Test(
    "a flow row reads unverified, flow runner not built, and its state row unverified behind it, as non-gating notes — catches a flow taken as passed before anything drives it"
  )
  func flowUnverified() async throws {
    let repo = try await QARepo()
    defer { repo.remove() }
    try repo.plan(
      [
        validationRow("req-save", .flow, "qa/save.flow.json", after: ["save-ui"]),
        validationRow("req-save", .state, "qa/save.state.sh", after: ["save-ui"]),
      ], tasks: ["save-ui": .done])
    try repo.qaFile("save.state.sh", "touch \"$QA_EVIDENCE_DIR/state-ran\"\n")

    let report = await repo.run(QARunRun.Options())

    #expect(report.rows.map(\.result) == [.unverified, .unverified])
    #expect(report.rows.first?.message == QARunPlan.flowRunnerMissing)
    #expect(
      !FileManager.default.fileExists(
        atPath: try repo.runDirectory(report).appending(path: "qa/state-ran").path))
    #expect(report.verdict == .green)
    #expect(
      report.findings.map(\.ruleID) == Array(repeating: QAReport.checkUnverifiedRuleID, count: 2))
  }

  @Test(
    "the run writes qa/report.json under its run and 1 qa.check event per row with the run's id, holding no command text — catches a report or event the run viewer can't find"
  )
  func reportAndEvents() async throws {
    let repo = try await QARepo()
    defer { repo.remove() }
    try repo.plan(
      [
        validationRow("req-save", .acceptance, "echo secret-command-text; exit 4", after: ["a"]),
        validationRow("req-save", .state, "qa/save.state.sh", after: ["b"]),
      ], tasks: ["a": .done, "b": .pending])
    let events = MemoryEventLog()

    let report = await repo.run(QARunRun.Options(), events: events)

    let file = try repo.runDirectory(report).appending(path: "qa/report.json")
    let data = try Data(contentsOf: file)
    #expect(try QAReportJSON.decode(data) == report)
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["after"] is NSNull)
    let head = try await repo.git("rev-parse", "HEAD")
    #expect(report.commit == head)
    #expect(report.rows.first?.exitStatus == 4)
    #expect(report.rows.first?.evidence == ["qa/01-req-save.acceptance.txt"])

    let checks = events.events.compactMap { event -> QACheckEvent? in
      guard case .qaCheck(let check) = event.payload else { return nil }
      return check
    }
    #expect(checks.map(\.row) == [1, 2])
    #expect(checks.map(\.result) == [.red, .waiting])
    #expect(checks.first?.exitStatus == 4)
    #expect(checks.first?.plan == QARepo.slug)
    #expect(events.events.allSatisfy { $0.runID == report.runID && $0.kind.stream == .qa })
    for event in events.events {
      let line = String(decoding: try HarnessEventJSON.encodeLine(event), as: UTF8.self)
      #expect(!line.contains("secret-command-text"))
      #expect(try HarnessEventJSON.decode(Data(line.utf8)).events == [event])
      #expect(try EventPayloadGuard.rejection(of: event) == nil)
    }

    let unknown = String(decoding: data, as: UTF8.self)
      .replacingOccurrences(of: "\"waiting\"", with: "\"skipped\"")
    #expect(throws: (any Error).self) { try QAReportJSON.decode(Data(unknown.utf8)) }
  }

  @Test(
    "--at-base runs each row at the merge base in a scratch worktree, records the failing exit status, and a row passing there is qa.check-passes-at-base — catches a red run proven on the changed tree"
  )
  func atBase() async throws {
    let repo = try await QARepo()
    defer { repo.remove() }
    let base = try await repo.git("rev-parse", "HEAD")
    try await repo.git("checkout", "-q", "-b", "feature")
    try Data("new\n".utf8).write(to: repo.root.appending(path: "feature.txt"))
    try await repo.git("add", "-A")
    try await repo.git("commit", "-q", "-m", "feature")
    try repo.plan(
      [
        validationRow("req-feature", .acceptance, "test -f feature.txt || exit 3", after: ["f"]),
        validationRow("req-feature", .state, "qa/always.state.sh", after: ["f"]),
      ], tasks: ["f": .pending])
    try repo.qaFile("always.state.sh", "exit 0\n")

    let report = await repo.run(QARunRun.Options(atBase: true))
    let head = await repo.run(QARunRun.Options(after: "f"), suffix: 2)

    #expect(report.atBase)
    #expect(report.commit == base)
    #expect(report.rows.first?.result == .red)
    #expect(report.rows.first?.exitStatus == 3)
    #expect(try repo.evidence(report, row: 1).contains("exit: 3"))
    #expect(report.rows.last?.result == .pass)
    #expect(report.findings.map(\.ruleID) == [QAReport.checkPassesAtBaseRuleID])
    #expect(report.verdict == .red)
    #expect(head.rows.first?.result == .pass)
    let worktrees = try await repo.git("worktree", "list", "--porcelain")
    #expect(worktrees.components(separatedBy: "worktree ").count == 2, "\(worktrees)")
  }

  @Test(
    "--at-base --prepared-by runs only the rows that task writes, with each check and QA_DIR read from the checkout's .harness/qa/<plan>/ rather than plan state — catches a validation worker's red proven against checks qa adopt hasn't copied yet, or spent on another task's rows"
  )
  func preparedAtBase() async throws {
    let repo = try await QARepo()
    defer { repo.remove() }
    try repo.plan(
      [
        ValidationRow(
          requirement: "req-toggle", layer: .acceptance, check: "exit 0",
          runsAfter: ["toggle-ui"], writer: "toggle-ui"),
        validationRow("req-toggle", .state, "qa/toggle.state.sh", after: ["toggle-ui"]),
      ], tasks: ["toggle-ui": .pending])
    try repo.qaFile("toggle.state.sh", "exit 0\n")
    let prepared = repo.root.appending(
      path: ".harness/qa/\(QARepo.slug)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: prepared, withIntermediateDirectories: true)
    try Data("test -f \"$QA_DIR/toggle.state.sh\" || exit 9\nexit 5\n".utf8)
      .write(to: prepared.appending(path: "toggle.state.sh"))

    let report = await repo.run(QARunRun.Options(atBase: true, preparedBy: "validation"))

    #expect(report.atBase)
    #expect(report.rows.map(\.row) == [2], "\(report.rows)")
    #expect(report.rows.first?.result == .red)
    #expect(report.rows.first?.exitStatus == 5, "\(report.rows)")
    #expect(report.findings.isEmpty, "\(report.findings)")
    #expect(report.verdict == .green, "\(report.message)")
    #expect(report.notes.contains { $0.contains(".harness/qa/\(QARepo.slug)") }, "\(report.notes)")
  }

  @Test(
    "--prepared-by without --at-base, naming no row's writer, or with no prepared folder is BLOCKED and runs nothing — catches a worker's checks run on the changed tree, or a typo'd task that proves no row"
  )
  func preparedBlocked() async throws {
    let repo = try await QARepo()
    defer { repo.remove() }
    try repo.plan(
      [validationRow("req-toggle", .state, "qa/toggle.state.sh", after: ["toggle-ui"])],
      tasks: ["toggle-ui": .pending])

    let notAtBase = await repo.run(QARunRun.Options(preparedBy: "validation"))
    let noFolder = await repo.run(
      QARunRun.Options(atBase: true, preparedBy: "validation"), suffix: 2)
    try FileManager.default.createDirectory(
      at: repo.root.appending(path: ".harness/qa/\(QARepo.slug)", directoryHint: .isDirectory),
      withIntermediateDirectories: true)
    let unknown = await repo.run(
      QARunRun.Options(atBase: true, preparedBy: "validaton"), suffix: 3)

    #expect(notAtBase.verdict == .blocked)
    #expect(notAtBase.message.contains("--at-base"), "\(notAtBase.message)")
    #expect(noFolder.verdict == .blocked)
    #expect(noFolder.message.contains(".harness/qa/\(QARepo.slug)"), "\(noFolder.message)")
    #expect(unknown.verdict == .blocked)
    #expect(unknown.message.contains("validaton"), "\(unknown.message)")
    #expect([notAtBase, noFolder, unknown].allSatisfy { $0.rows.isEmpty })
  }

  @Test(
    "--after naming no ledger task is BLOCKED, and runs nothing — catches a typo'd task id read as a merge that unblocks no row"
  )
  func unknownAfterBlocks() async throws {
    let repo = try await QARepo()
    defer { repo.remove() }
    try repo.plan(
      [validationRow("req-save", .acceptance, "exit 0", after: ["save-ui"])],
      tasks: ["save-ui": .done])

    let report = await repo.run(QARunRun.Options(after: "save-iu"))

    #expect(report.verdict == .blocked)
    #expect(report.message.contains("save-iu"))
    #expect(report.rows.isEmpty)
  }

  @Test(
    "a plain qa run reads each task's merged status from a ledger with no waves key, as --at-base runs without one — catches the same plan passing at base and BLOCKED on the branch"
  )
  func ledgerWithoutWaves() async throws {
    let repo = try await QARepo()
    defer { repo.remove() }
    try repo.plan(
      [
        validationRow("req-save", .acceptance, "exit 0", after: ["save-ui"]),
        validationRow("req-list", .acceptance, "exit 0", after: ["list-ui"]),
      ], tasks: ["save-ui": .done, "list-ui": .pending])
    let ledgerFile = repo.planDirectory.appending(path: "ledger.json")
    var ledger = try #require(
      try JSONSerialization.jsonObject(with: Data(contentsOf: ledgerFile)) as? [String: Any])
    #expect(ledger.removeValue(forKey: "waves") != nil)
    try JSONSerialization.data(withJSONObject: ledger).write(to: ledgerFile)

    let report = await repo.run(QARunRun.Options())
    let after = await repo.run(QARunRun.Options(after: "list-ui"), suffix: 2)

    #expect(report.verdict == .green, "\(report.message)")
    #expect(report.rows.map(\.result) == [.pass, .waiting])
    #expect(report.rows.last?.waitingOn == ["list-ui"])
    #expect(after.rows.map(\.requirement) == ["req-list"])
    #expect(after.rows.map(\.result) == [.pass])
  }

  @Test(
    "with no --plan it takes the 1 plan holding a validation.json, is GREEN with a note when none does, and BLOCKED naming each when 2 do — catches rows run from the wrong plan"
  )
  func planChoice() async throws {
    let repo = try await QARepo()
    defer { repo.remove() }

    let none = await repo.run(QARunRun.Options())
    try repo.plan(
      [validationRow("req-save", .acceptance, "exit 0", after: ["save-ui"])],
      tasks: ["save-ui": .done])
    let one = await repo.run(QARunRun.Options(), suffix: 2)
    try repo.plan(
      [validationRow("req-list", .acceptance, "exit 0", after: ["list-ui"])],
      tasks: ["list-ui": .done], slug: "2026-10-04-lists")
    let two = await repo.run(QARunRun.Options(), suffix: 3)
    let named = await repo.run(QARunRun.Options(plan: "2026-10-04-lists"), suffix: 4)

    #expect(none.verdict == .green)
    #expect(none.rows.isEmpty)
    #expect(none.notes.contains { $0.contains(ValidationTable.fileName) })
    #expect(one.plan == QARepo.slug)
    #expect(one.rows.map(\.requirement) == ["req-save"])
    #expect(two.verdict == .blocked)
    #expect(two.message.contains(QARepo.slug) && two.message.contains("2026-10-04-lists"))
    #expect(named.rows.map(\.requirement) == ["req-list"])
  }
}

@Suite("qa adopt")
struct QAAdoptCommandTests {
  static func prepare(_ checkout: URL, plan: String, files: [String: String]) throws {
    let folder = checkout.appending(path: ".harness/qa/\(plan)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    for (name, text) in files {
      try Data(text.utf8).write(to: folder.appending(path: name))
    }
  }

  func adopt(_ repo: QARepo, _ worktree: String) async -> QAAdoptReport {
    await QAAdoptRun.run(
      worktree: worktree, root: repo.root,
      git: LiveGit(runner: repo.runner, repositoryRoot: repo.root.path), runner: repo.runner)
  }

  @Test(
    "adopt replaces the plan's qa/ with the worktree's .harness/qa/<plan>/, leaving no file of the old copy — catches a stale check run from an earlier adoption"
  )
  func copiesFromWorktree() async throws {
    let repo = try await QARepo()
    defer { repo.remove() }
    let worktree = repo.root.deletingLastPathComponent()
      .appending(path: repo.root.lastPathComponent + "-validation", directoryHint: .isDirectory)
    defer { TestTemporaryDirectory.remove(worktree) }
    try await repo.git("worktree", "add", "-q", "-b", "validation", worktree.path, "main")
    try repo.qaFile("stale.state.sh", "exit 0\n")
    try Self.prepare(
      worktree, plan: QARepo.slug,
      files: ["save.state.sh": "exit 1\n", "save.flow.json": "{}\n"])

    let report = await adopt(repo, worktree.path)

    #expect(report.verdict == .green, "\(report.message)")
    #expect(report.adopted.map(\.plan) == [QARepo.slug])
    #expect(report.adopted.first?.files == 2)
    let names = try FileManager.default.contentsOfDirectory(
      atPath: repo.planDirectory.appending(path: "qa").path
    ).sorted()
    #expect(names == ["save.flow.json", "save.state.sh"])
  }

  @Test(
    "adopt refuses a folder outside this repository's checkouts and copies nothing — catches checks taken in from any directory"
  )
  func refusesOutside() async throws {
    let repo = try await QARepo()
    defer { repo.remove() }
    let outside = try TestTemporaryDirectory.make("swiftgate-qa-outside").resolvingSymlinksInPath()
    defer { TestTemporaryDirectory.remove(outside) }
    try Self.prepare(outside, plan: QARepo.slug, files: ["evil.state.sh": "exit 0\n"])

    let report = await adopt(repo, outside.path)

    #expect(report.verdict == .red)
    #expect(report.message.contains("checkout"))
    #expect(report.adopted.isEmpty)
    #expect(
      !FileManager.default.fileExists(
        atPath: repo.planDirectory.appending(path: "qa/evil.state.sh").path))
  }

  @Test(
    "adopt is RED for a checkout with no prepared folder, or one naming no plan — catches a missing validation output adopted as an empty table of checks"
  )
  func refusesEmptyOrUnknown() async throws {
    let repo = try await QARepo()
    defer { repo.remove() }

    let empty = await adopt(repo, repo.root.path)
    try Self.prepare(repo.root, plan: "no-such-plan", files: ["x.state.sh": "exit 0\n"])
    let unknown = await adopt(repo, repo.root.path)

    #expect(empty.verdict == .red)
    #expect(empty.message.contains(".harness/qa"))
    #expect(unknown.verdict == .red)
    #expect(unknown.message.contains("no-such-plan"))
    #expect(!FileManager.default.fileExists(atPath: repo.planDirectory("no-such-plan").path))
  }
}
