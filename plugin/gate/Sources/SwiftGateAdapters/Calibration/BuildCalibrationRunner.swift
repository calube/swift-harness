import Foundation
import SwiftGateDomain

/// Runs one build agent on one seed: builds the seed's repository in a sandbox, runs the agent
/// there through `claude -p` with its own prompt and tools, then judges what it left behind
/// against the label. Git and `swift test` go through `tools`; only the agent goes through
/// `agent`, so a test can play the agent and still judge a real repository.
public struct BuildCalibrationRunner: Sendable {
  /// One judged case, with what the agent run cost when `claude` reported it.
  public struct CaseRun: Sendable, Equatable {
    public let result: CalibrationRecord.CaseResult
    public let costUSD: Double?
    public let durationMilliseconds: Int?
    /// Kept for inspection when a label was missed; removed otherwise.
    public let sandbox: String?
  }

  public static let plan = "calibrate"
  static let identity = [
    "-c", "user.name=swiftgate calibrate", "-c", "user.email=calibrate@swiftgate.invalid",
  ]
  /// Git state a parent process can leak (a hook sets these) would point every command at the
  /// wrong repository.
  static let gitEnvironment: [String: String?] = [
    "GIT_DIR": nil, "GIT_WORK_TREE": nil, "GIT_INDEX_FILE": nil, "GIT_COMMON_DIR": nil,
    "GIT_OBJECT_DIRECTORY": nil, "GIT_PREFIX": nil,
  ]

  private let agentRunner: any ProcessRunner
  private let tools: any ProcessRunner
  private let root: URL
  private let sandboxRoot: URL
  private let pluginBin: String
  private let executable: String
  private let agentTimeout: Duration
  private let testTimeout: Duration
  public let defaultModel: String
  /// Every agent's model for this run in place of its frontmatter's; a pass made with one is
  /// never fresh.
  public let modelOverride: String?

  /// - Parameters:
  ///   - root: the repository holding the seeds.
  ///   - sandboxRoot: where each case's repository is built, one directory per case; give each
  ///     run its own.
  ///   - pluginBin: put first on the agent's `PATH`, so its `swiftgate` is this checkout's.
  ///   - defaultModel: for an agent whose frontmatter names none.
  ///   - modelOverride: every agent's model in place of its frontmatter's, for experiments.
  public init(
    agent: any ProcessRunner, tools: any ProcessRunner, root: URL, sandboxRoot: URL,
    pluginBin: String, defaultModel: String, modelOverride: String? = nil,
    executable: String = "claude",
    agentTimeout: Duration = .seconds(3600), testTimeout: Duration = .seconds(1200)
  ) {
    self.agentRunner = agent
    self.tools = tools
    self.root = root
    self.sandboxRoot = sandboxRoot
    self.pluginBin = pluginBin
    self.defaultModel = defaultModel
    self.modelOverride = modelOverride
    self.executable = executable
    self.agentTimeout = agentTimeout
    self.testTimeout = testTimeout
  }

  public func model(of agent: BuildCalibrationSeeds.Agent) -> String {
    modelOverride ?? agent.model ?? defaultModel
  }

  public func run(agent: BuildCalibrationSeeds.Agent, seed: BuildCalibrationSeeds.Case)
    async throws(CalibrationCaseError) -> CaseRun
  {
    guard let role = BuildCalibrationRole(rawValue: agent.name) else {
      throw .seedDefect("\(agent.name) isn't a build agent calibrate build can seed")
    }
    let sandbox = sandboxRoot.appending(
      path: "\(agent.name)-\(seed.name)", directoryHint: .isDirectory)
    // A leftover from an earlier run under the same root would be laid over, not replaced.
    TemporaryDirectories.remove(sandbox)
    let repository = Sandbox(
      directory: sandbox, seed: root.appending(path: seed.directory, directoryHint: .isDirectory),
      tools: tools)
    let setup = try await repository.setUp(role: role, caseName: seed.name)
    let prompt = try Self.prompt(seed.input, setup: setup, sandbox: sandbox)
    let refsBefore = try await repository.refs()

    let reply = try await runAgent(agent, prompt: prompt, in: repository.repo.path)
    var answers: [CalibrationRecord.QuestionResult] = []
    func answer(_ question: String, _ expected: String, _ answered: String) {
      answers.append(
        .init(question: question, expected: expected, answered: answered, probability: 1))
    }

    let tip = try await repository.revision("refs/heads/\(setup.branch)")
    switch Self.decodeReturn(reply.result) {
    case .success(let decoded):
      answer("outcome", seed.label.outcome.rawValue, decoded.outcome.rawValue)
      answer(
        "return", "matches",
        try await repository.returnFindings(
          decoded, taskID: seed.name, branch: setup.branch, tip: tip, gate: seed.label.gate,
          proofRequired: role == .worker, taskGateStepsRequired: role == .worker))
    case .failure(let problem):
      answer("outcome", seed.label.outcome.rawValue, "no return: \(problem.reason)")
      answer("return", "matches", "no return")
    }
    answer(
      "scope", "inside-write-set",
      try await repository.scope(from: setup.startCommit, to: tip, writeSet: seed.label.writeSet))
    answer(
      "refs", "unchanged",
      try await repository.refChanges(before: refsBefore, allowed: setup.branch))
    if role == .fixer, let mainCommit = setup.mainCommit, let taskCommit = setup.taskCommit {
      answer(
        "resolution", "resolved",
        try await repository.resolution(tip: tip, parents: [mainCommit, taskCommit]))
    }
    answer(
      "tests", "passed",
      try await repository.acceptance(tip: tip, tests: seed.label.tests, timeout: testTimeout))

    let met = answers.allSatisfy(\.met)
    if met { TemporaryDirectories.remove(sandbox) }
    return CaseRun(
      result: .init(
        agent: agent.name, caseName: seed.name, model: model(of: agent), answers: answers),
      costUSD: reply.costUSD, durationMilliseconds: reply.durationMilliseconds,
      sandbox: met ? nil : sandbox.path)
  }

  // MARK: - The agent

  struct Reply {
    let result: String
    let costUSD: Double?
    let durationMilliseconds: Int?
  }

  func invocation(_ agent: BuildCalibrationSeeds.Agent, prompt: String, in directory: String)
    -> ProcessInvocation
  {
    let tools =
      (agent.tools ?? "Read, Grep, Glob, Edit, Write, Bash").split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: ",")
    let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
    var environment = Self.gitEnvironment
    environment["PATH"] = "\(pluginBin):\(path)"
    return ProcessInvocation(
      executable: executable,
      arguments: [
        "-p", "--output-format", "json", "--system-prompt", agent.systemPrompt,
        "--tools", tools, "--permission-mode", "bypassPermissions",
        // No user, project or local settings (so no plugin hooks or user permissions), no MCP
        // servers, no transcript: the agent runs on its own prompt and tools only.
        "--setting-sources", "", "--strict-mcp-config", "--no-session-persistence",
        "--settings", #"{"verbose":false}"#,
        "--model", model(of: agent),
      ],
      environmentOverlay: environment, workingDirectory: directory,
      standardInput: Data(prompt.utf8), timeout: agentTimeout)
  }

  private func runAgent(_ agent: BuildCalibrationSeeds.Agent, prompt: String, in directory: String)
    async throws(CalibrationCaseError) -> Reply
  {
    let output: ProcessOutput
    do {
      output = try await agentRunner.run(invocation(agent, prompt: prompt, in: directory))
    } catch {
      throw .blocked("\(executable) didn't finish: \(error)")
    }
    guard
      let object = (try? JSONSerialization.jsonObject(with: output.stdout.bytes))
        as? [String: Any]
    else {
      throw .blocked(
        "\(executable) exited \(output.status) without a JSON result: "
          + String(output.stderr.text.suffix(400)))
    }
    guard output.status.isSuccess, object["is_error"] as? Bool != true,
      let result = object["result"] as? String
    else {
      throw .blocked(
        "\(executable) reported an error (\(output.status)): "
          + String((object["result"] as? String ?? output.stderr.text).suffix(400)))
    }
    return Reply(
      result: result, costUSD: object["total_cost_usd"] as? Double,
      durationMilliseconds: object["duration_ms"] as? Int)
  }

  struct UnreadableReturn: Error {
    let reason: String
  }

  /// The agent's final message is one `TaskReturn` object, possibly fenced.
  static func decodeReturn(_ text: String) -> Result<TaskReturn, UnreadableReturn> {
    guard let open = text.firstIndex(of: "{"), let close = text.lastIndex(of: "}"), open < close
    else { return .failure(UnreadableReturn(reason: "the reply holds no JSON object")) }
    do {
      return .success(try TaskReturnJSON.decode(Data(text[open...close].utf8)))
    } catch {
      return .failure(UnreadableReturn(reason: "\(error)"))
    }
  }

  static let placeholders = [
    "worktree", "branch", "plan", "task", "contextPack", "mainCommit", "taskCommit",
  ]

  /// Fills `{{name}}` placeholders; one left over, or unknown, is a seed defect.
  static func prompt(_ input: String, setup: Sandbox.Setup, sandbox: URL)
    throws(CalibrationCaseError) -> String
  {
    let values: [String: String?] = [
      "worktree": setup.worktree, "branch": setup.branch, "plan": plan, "task": setup.task,
      "contextPack": setup.contextPack, "mainCommit": setup.mainCommit,
      "taskCommit": setup.taskCommit,
    ]
    var text = input
    for (name, value) in values {
      guard let value else { continue }
      text = text.replacingOccurrences(of: "{{\(name)}}", with: value)
    }
    if let range = text.range(of: "{{") {
      let name = text[range.upperBound...].prefix { $0 != "}" }
      throw .seedDefect(
        "input.md uses `{{\(name)}}`, which this agent's setup doesn't fill (known: "
          + "\(placeholders.joined(separator: ", ")))")
    }
    return text
  }
}

/// One case's scratch repository and the git and `swift` calls that set it up and judge it.
struct Sandbox {
  struct Setup {
    let worktree: String
    /// The branch the agent commits to.
    let branch: String
    let task: String
    /// Where the agent's branch started: the scope is measured from here.
    let startCommit: String
    let contextPack: String?
    let mainCommit: String?
    let taskCommit: String?
  }

  let directory: URL
  let seed: URL
  let tools: any ProcessRunner

  var repo: URL { directory.appending(path: "repo", directoryHint: .isDirectory) }

  func setUp(role: BuildCalibrationRole, caseName: String) async throws(CalibrationCaseError)
    -> Setup
  {
    try overlay("base", into: repo)
    try await git(["init", "-q", "-b", "main"])
    try await git(["config", "core.hooksPath", ".git/hooks"])
    try await git(["config", "commit.gpgsign", "false"])
    let base = try await commit("seed: base")
    let taskBranch = "\(BuildCalibrationRunner.plan)/\(caseName)"
    switch role {
    case .worker:
      try await git(["update-ref", "refs/remotes/origin/main", base])
      try await git(["checkout", "-q", "-b", taskBranch])
      let pack = directory.appending(path: "context-pack.md")
      do {
        try FileManager.default.copyItem(at: seed.appending(path: "context.md"), to: pack)
      } catch {
        throw .blocked("can't copy the context pack: \(error)")
      }
      return Setup(
        worktree: repo.path, branch: taskBranch, task: caseName, startCommit: base,
        contextPack: pack.path, mainCommit: nil, taskCommit: nil)
    case .fixer:
      try await git(["checkout", "-q", "-b", taskBranch])
      try overlay("task", into: repo)
      let taskCommit = try await commit("seed: the merging task")
      try await git(["checkout", "-q", "main"])
      try overlay("main", into: repo)
      let mainCommit = try await commit("seed: the task already on main")
      try await git(["update-ref", "refs/remotes/origin/main", mainCommit])
      let fixBranch = "\(BuildCalibrationRunner.plan)/fix-\(caseName)"
      try await git(["checkout", "-q", "-b", fixBranch])
      let merge = try await run(["merge", "--no-ff", "--no-edit", taskBranch])
      let unmerged = try await git(["ls-files", "-u"])
      guard !merge.status.isSuccess, !unmerged.isEmpty else {
        throw .seedDefect("merging main/ and task/ doesn't conflict, so there's nothing to fix")
      }
      return Setup(
        worktree: repo.path, branch: fixBranch, task: caseName, startCommit: mainCommit,
        contextPack: nil, mainCommit: mainCommit, taskCommit: taskCommit)
    }
  }

  // MARK: Judging

  func revision(_ ref: String) async throws(CalibrationCaseError) -> String? {
    let output = try await run(["rev-parse", "--verify", "--quiet", "\(ref)^{commit}"])
    guard output.status.isSuccess else { return nil }
    return output.stdout.text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  func refs() async throws(CalibrationCaseError) -> [String: String] {
    var refs: [String: String] = [:]
    for line in try await git(["for-each-ref", "--format=%(refname) %(objectname)"])
      .split(separator: "\n")
    {
      let parts = line.split(separator: " ", maxSplits: 1)
      if parts.count == 2 { refs[String(parts[0])] = String(parts[1]) }
    }
    return refs
  }

  /// `unchanged`, or the refs other than the agent's branch that it moved, made or deleted, and
  /// a HEAD that left the branch.
  func refChanges(before: [String: String], allowed branch: String)
    async throws(CalibrationCaseError) -> String
  {
    let after = try await refs()
    let allowed = "refs/heads/\(branch)"
    var changes: [String] = []
    for name in Set(before.keys).union(after.keys).sorted() where name != allowed {
      switch (before[name], after[name]) {
      case (nil, .some): changes.append("created \(name)")
      case (.some, nil): changes.append("deleted \(name)")
      case (.some(let old), .some(let new)) where old != new: changes.append("moved \(name)")
      default: break
      }
    }
    let head = try await run(["symbolic-ref", "-q", "HEAD"])
    let headRef = head.stdout.text.trimmingCharacters(in: .whitespacesAndNewlines)
    if headRef != allowed {
      changes.append("HEAD is \(headRef.isEmpty ? "detached" : headRef), not \(allowed)")
    }
    return changes.isEmpty ? "unchanged" : changes.joined(separator: "; ")
  }

  /// `inside-write-set`, or the files the branch changed outside it.
  func scope(from start: String, to tip: String?, writeSet: [String])
    async throws(CalibrationCaseError) -> String
  {
    guard let tip else { return "no branch" }
    let changed = try await git(["diff", "--name-only", start, tip])
      .split(separator: "\n").map(String.init)
    if changed.isEmpty { return "no change" }
    let outside = changed.filter { !writeSet.contains($0) }
    return outside.isEmpty ? "inside-write-set" : "outside: \(outside.joined(separator: ", "))"
  }

  /// `resolved`, or what's left of the conflict: the merge in progress, unmerged paths, a tip
  /// missing either side, or conflict markers.
  func resolution(tip: String?, parents: [String]) async throws(CalibrationCaseError) -> String {
    var problems: [String] = []
    if try await revision("MERGE_HEAD") != nil { problems.append("merge still in progress") }
    let unmerged = try await git(["ls-files", "-u"])
    if !unmerged.isEmpty { problems.append("unmerged paths remain") }
    if let tip {
      for parent in parents
      where !(try await run(["merge-base", "--is-ancestor", parent, tip])).status.isSuccess {
        problems.append("tip doesn't contain \(parent.prefix(8))")
      }
      let markers = try await run(["grep", "-l", "-E", "^(<<<<<<<|>>>>>>>) ", tip])
      let files = markers.stdout.text.split(separator: "\n")
      if !files.isEmpty {
        problems.append("conflict markers in \(files.joined(separator: ", "))")
      }
    } else {
      problems.append("no branch")
    }
    return problems.isEmpty ? "resolved" : problems.joined(separator: "; ")
  }

  /// The return's claims against git and the sandbox's run store, as `build check-return`
  /// checks them. A worker's `review` is always `null` until the workflow fills it, so its
  /// absence isn't a finding here.
  /// - Parameters:
  ///   - proofRequired: a worker's green gate must prove and mutate its change, as
  ///     `build check-return` requires of a task; a fixer's need not.
  ///   - taskGateStepsRequired: a worker's green gate must run the task gate's impact, coverage
  ///     and app-build steps, as `build check-return` requires; a fixer's need not.
  func returnFindings(
    _ taskReturn: TaskReturn, taskID: String, branch: String, tip: String?, gate: CheckTier,
    proofRequired: Bool, taskGateStepsRequired: Bool
  ) async throws(CalibrationCaseError) -> String {
    var commits: [String: TaskReturnEvidence.CommitState] = [:]
    var surface: TaskReturnEvidence.CommitState?
    if let tip {
      for commit in taskReturn.commits {
        commits[commit] = try await state(of: commit, onBranchAt: tip)
      }
      if let surfaceCommit = taskReturn.surfaceCommit {
        surface = try await state(of: surfaceCommit, onBranchAt: tip)
      }
    }
    var gateRun: TaskReturnEvidence.GateRun?
    if let runID = taskReturn.gate?.runID {
      let history: (records: [RunHistoryRecord], invalidLines: Int)
      do {
        history = try RunStore(worktreeRoot: repo).readHistory()
      } catch {
        throw .blocked("can't read the sandbox's run history: \(error)")
      }
      if let record = history.records.last(where: { $0.runID == runID }) {
        gateRun = .init(record: record)
      }
    }
    var lastCommit: String?
    if let last = taskReturn.commits.last, commits[last] == .onBranch {
      lastCommit = try await revision(last)
    }
    let evidence = TaskReturnEvidence(
      branch: branch, branchExists: tip != nil, commits: commits, gateRun: gateRun,
      taskGate: gate, taskStatus: nil, proofRequired: proofRequired, surfaceCommit: surface,
      taskGateStepsRequired: taskGateStepsRequired, lastCommit: lastCommit)
    var problems = TaskReturnCheck.findings(taskReturn, evidence: evidence)
      .filter { $0.rule != .reviewMissing }.map { "\($0.rule.rawValue): \($0.message)" }
    if taskReturn.task != taskID {
      problems.insert("task is `\(taskReturn.task)`, not `\(taskID)`", at: 0)
    }
    return problems.isEmpty ? "matches" : problems.joined(separator: "; ")
  }

  private func state(of commit: String, onBranchAt tip: String)
    async throws(CalibrationCaseError) -> TaskReturnEvidence.CommitState
  {
    guard let full = try await revision(commit), commit.allSatisfy(\.isHexDigit) else {
      return .missing
    }
    let onBranch = try await run(["merge-base", "--is-ancestor", full, tip]).status.isSuccess
    return onBranch ? .onBranch : .offBranch
  }

  /// `passed`, or the labelled tests that failed or never ran, after the seed's `accept/` tests
  /// are laid over the branch tip in a separate worktree.
  func acceptance(tip: String?, tests: [String], timeout: Duration)
    async throws(CalibrationCaseError) -> String
  {
    guard let tip else { return "no branch" }
    let judge = directory.appending(path: "judge", directoryHint: .isDirectory)
    try await git(["worktree", "add", "-q", "--detach", judge.path, tip])
    try overlay("accept", into: judge)
    let xunit = directory.appending(path: "xunit.xml").path
    let output: ProcessOutput
    do {
      var environment = BuildCalibrationRunner.gitEnvironment
      // A coverage-instrumented parent would otherwise write the nested run's profiles into its
      // own profile path.
      environment["LLVM_PROFILE_FILE"] = directory.appending(path: "profile-%p.profraw").path
      output = try await tools.run(
        ProcessInvocation(
          executable: "swift", arguments: ["test", "--xunit-output", xunit],
          environmentOverlay: environment, workingDirectory: judge.path, timeout: timeout))
    } catch {
      throw .blocked("swift test didn't finish: \(error)")
    }
    var cases: [XUnitTestCase] = []
    var reports = 0
    for path in [xunit, LiveSwiftPM.swiftTestingReportPath(for: xunit)] {
      guard let data = FileManager.default.contents(atPath: path) else { continue }
      reports += 1
      do {
        cases += try XUnitReport.parse(data)
      } catch {
        return "unreadable test report: \(error.detail)"
      }
    }
    guard reports > 0 else {
      return "no test report (swift test \(output.status)): "
        + String(output.stderr.text.suffix(300) + output.stdout.text.suffix(300))
    }
    var problems: [String] = []
    for test in tests {
      guard let id = BuildCalibrationTestID(test) else { continue }
      let matches = cases.filter { $0.className == id.className && $0.name == id.name }
      if matches.isEmpty {
        problems.append("not run: \(test)")
      } else if !matches.allSatisfy({ $0.outcome == .passed }) {
        problems.append("failed: \(test)")
      }
    }
    return problems.isEmpty ? "passed" : problems.joined(separator: "; ")
  }

  // MARK: Plumbing

  /// Copies every file under the seed's `name/` over `destination`, making directories.
  func overlay(_ name: String, into destination: URL) throws(CalibrationCaseError) {
    let source = seed.appending(path: name, directoryHint: .isDirectory)
    let fileManager = FileManager.default
    do {
      try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
      guard let enumerator = fileManager.enumerator(atPath: source.path) else {
        throw CalibrationCaseError.seedDefect("can't list the seed's \(name)/")
      }
      while let relative = enumerator.nextObject() as? String {
        let from = source.appending(path: relative)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: from.path, isDirectory: &isDirectory),
          !isDirectory.boolValue
        else { continue }
        let to = destination.appending(path: relative)
        try fileManager.createDirectory(
          at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: to.path) { try fileManager.removeItem(at: to) }
        try fileManager.copyItem(at: from, to: to)
      }
    } catch let error as CalibrationCaseError {
      throw error
    } catch {
      throw .blocked("can't lay the seed's \(name)/ over \(destination.path): \(error)")
    }
  }

  private func commit(_ message: String) async throws(CalibrationCaseError) -> String {
    try await git(["add", "-A"])
    try await git(BuildCalibrationRunner.identity + ["commit", "-q", "-m", message])
    guard let head = try await revision("HEAD") else {
      throw .blocked("git committed but HEAD doesn't resolve")
    }
    return head
  }

  /// Runs git in the sandbox repository and returns stdout; a nonzero exit is `blocked`.
  @discardableResult
  private func git(_ arguments: [String]) async throws(CalibrationCaseError) -> String {
    let output = try await run(arguments)
    guard output.status.isSuccess else {
      throw .blocked(
        "git \(arguments.joined(separator: " ")) exited \(output.status): "
          + output.stderr.text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    return output.stdout.text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func run(_ arguments: [String]) async throws(CalibrationCaseError) -> ProcessOutput {
    do {
      return try await tools.run(
        ProcessInvocation(
          executable: "git", arguments: ["-C", repo.path] + arguments,
          environmentOverlay: BuildCalibrationRunner.gitEnvironment, timeout: .seconds(120)))
    } catch {
      throw .blocked("git \(arguments.joined(separator: " ")) didn't finish: \(error)")
    }
  }
}
