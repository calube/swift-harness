/// The contract commit a brownfield run lands on its plan branch before `plan import`, read as the
/// contract task's done return. The run skill commits the contract and gates it in the plan
/// checkout before the plan has a ledger, so the task never runs through a worker: its return is
/// built here from that commit and its gate run, or it stays `pending` with the reason.
public enum ContractLanding {
  public static let unlandedWriteRuleID = "plan-import.contract-write-unlanded"
  public static let scenarioSeamRuleID = "plan-import.scenario-seam-missing"
  public static let refreshMarkerRuleID = "plan-import.refresh-marker-unplaced"

  public enum Outcome: Sendable, Equatable {
    /// The return to record, with the task set `done`.
    case done(TaskReturn)
    /// Why the task stays `pending`.
    case pending(reason: String)
  }

  /// Reads `runID` from the plan checkout's `history` and checks it gated the commit at the tip of
  /// `planBranch`, `planBranchTip`, GREEN, at a brownfield tier.
  public static func outcome(
    task: String, runID: String, history: [RunHistoryRecord], planBranch: String,
    planBranchTip: String?
  ) -> Outcome {
    guard let tip = planBranchTip else {
      return .pending(reason: "\(planBranch) names no commit, so no contract has landed on it")
    }
    guard let run = history.last(where: { $0.runID == runID }) else {
      return .pending(reason: "run \(runID) isn't in the plan checkout's gate history")
    }
    guard let tier = TaskReturnEvidence.GateRun.tier(ofCommand: run.command),
      tier.profile == .brownfield
    else {
      return .pending(
        reason: "run \(runID) was `\(run.command ?? "an unnamed command")`, not a "
          + "`check --tier` run at a brownfield tier")
    }
    guard run.verdict == .green else {
      return .pending(
        reason: "run \(runID) (\(tier.rawValue)) is \(run.verdict.rawValue); fix the contract, "
          + "gate it again and import with that run")
    }
    guard let head = run.headCommit, head == tip, run.base != head else {
      let gated = run.headCommit ?? "no recorded commit"
      return .pending(
        reason: "run \(runID) gated \(gated), not the contract commit \(tip) at the tip of "
          + "\(planBranch); commit the contract, gate it in the plan checkout and import with "
          + "that run")
    }
    return .done(
      TaskReturn(
        task: task, outcome: .readyToMerge, commits: [tip],
        gate: TaskReturn.Gate(tier: tier, verdict: .green, runID: runID), review: nil,
        testsAdded: [],
        notes:
          "The contract commit \(tip) landed on \(planBranch) before the plan was imported; "
          + "its \(tier.rawValue) gate, run \(runID), was GREEN.",
        designConflict: nil))
  }

  /// The base the GREEN gate run `runID` compared the contract commit with: the commit the
  /// contract's changed files are read from.
  public static func gatedBase(runID: String, history: [RunHistoryRecord]) -> String? {
    history.last(where: { $0.runID == runID })?.base
  }

  /// What the contract commit holds, against the base its gate run read.
  public struct Commit: Sendable, Equatable {
    public let tip: String
    public let base: String
    /// Files that differ between `base` and `tip`.
    public let changedFiles: [String]
    /// Every file at `tip`, used to tell a directory written without a trailing `/` from a file.
    public let files: [String]
    /// The Swift sources outside test folders in the `xcode` areas at `tip`, by path; `nil` when
    /// the plan's flows don't launch through the scenario argument, so nothing needs reading.
    public let appSources: [String: String]?
    /// The requirements whose flow rows pull to refresh, and the Swift sources of the app and
    /// the packages it links at `tip`; `nil` when no flow row refreshes.
    public let refresh: Refresh?

    public init(
      tip: String, base: String, changedFiles: [String], files: [String],
      appSources: [String: String]?, refresh: Refresh? = nil
    ) {
      self.tip = tip
      self.base = base
      self.changedFiles = changedFiles
      self.files = files
      self.appSources = appSources
      self.refresh = refresh
    }
  }

  /// What the refresh marker check reads: a plan's refresh requirements and the sources that
  /// must pin their drag's end.
  public struct Refresh: Sendable, Equatable {
    public let requirements: [String]
    public let sources: [String: String]

    public init(requirements: [String], sources: [String: String]) {
      self.requirements = requirements
      self.sources = sources
    }
  }

  /// `outcome`, kept `pending` when the contract commit leaves a file of the task's `writes`
  /// untouched, when the plan's flows need the scenario seam and no app source reads it, or when
  /// a flow row pulls to refresh and no app source pins the bottom marker its drag ends on.
  public static func checked(_ outcome: Outcome, writes: [String], commit: Commit) -> Outcome {
    guard case .done = outcome else { return outcome }
    var gaps: [String] = []
    let unlanded = unlandedWrites(writes, changedFiles: commit.changedFiles, files: commit.files)
    if !unlanded.isEmpty {
      let named = unlanded.map { "`\($0)`" }.joined(separator: ", ")
      let them = unlanded.count == 1 ? "it" : "them"
      let gap: String =
        "\(unlandedWriteRuleID): the contract task writes \(named), but the contract commit "
        + "\(commit.tip) leaves \(them) as at \(commit.base). A write in a Bash call a guard "
        + "denied never ran; write \(them) again"
      gaps.append(gap)
    }
    if let sources = commit.appSources, !readsScenarioArgument(sources) {
      gaps.append(
        "\(scenarioSeamRuleID): the plan's flows launch the app with "
          + "`\(SimSession.scenarioArgument) <name>`, but no Swift source in an `xcode` area at "
          + "\(commit.tip) reads that argument outside a comment, so every flow would run "
          + "against the live service. Add the seam to the composition root: read the argument "
          + "after `\(SimSession.scenarioArgument)` in `ProcessInfo.processInfo.arguments` and "
          + "set the client to that scenario's fake before the root store is built")
    }
    if let refresh = commit.refresh, !refresh.requirements.isEmpty,
      !pinsBottomMarker(refresh.sources)
    {
      let named = refresh.requirements.map { "`\($0)`" }.joined(separator: ", ")
      gaps.append(
        "\(refreshMarkerRuleID): the flow rows of \(named) pull to refresh, but no Swift source "
          + "of the app at \(commit.tip) pins an identified element to the bottom of the "
          + "screen's safe area outside a comment, so a worker may place the drag's end as a list "
          + "row, where the drag pulls nothing. Place it in the refreshable view the contract "
          + "stubs, after any identifier on the list: `.safeAreaInset(edge: .bottom, spacing: 0) "
          + "{ Color.clear.frame(height: 1).accessibilityElement().accessibilityIdentifier("
          + "<bottom id>) }`")
    }
    guard !gaps.isEmpty else { return outcome }
    return .pending(
      reason: gaps.joined(separator: "; ")
        + "; commit the fix, gate it in the plan checkout and import with that run")
  }

  /// The literal file paths in `writes` that `changedFiles` lacks. A `/`-terminated entry, a
  /// glob, and an entry `files` holds paths under, all name a directory, which any 1 changed
  /// file may satisfy, so none is checked.
  public static func unlandedWrites(_ writes: [String], changedFiles: [String], files: [String])
    -> [String]
  {
    let changed = Set(changedFiles)
    return writes.filter { path in
      guard !path.hasSuffix("/"), !path.contains(where: { "*?[{".contains($0) }) else {
        return false
      }
      let inside = path + "/"
      guard !files.contains(where: { $0.hasPrefix(inside) }),
        !changedFiles.contains(where: { $0.hasPrefix(inside) })
      else { return false }
      return !changed.contains(path)
    }
  }

  /// Whether the plan's flows launch the app through ``SimSession/scenarioArgument``: the plan
  /// names it and has at least 1 `flow` row.
  public static func needsScenarioSeam(planText: String, hasFlowRows: Bool) -> Bool {
    hasFlowRows && planText.contains(SimSession.scenarioArgument)
  }

  /// Whether `path` is a Swift source under 1 of `appRoots` (an `xcode` area's root, `.` for the
  /// repository) and outside every folder named `…Tests`, where a UI test passes the argument
  /// rather than reading it.
  public static func isAppSource(_ path: String, appRoots: [String]) -> Bool {
    guard path.hasSuffix(".swift") else { return false }
    let folders = path.split(separator: "/").dropLast()
    guard !folders.contains(where: { $0.hasSuffix("Tests") }) else { return false }
    return appRoots.contains { root in
      let trimmed = root.hasSuffix("/") ? String(root.dropLast()) : root
      return trimmed == "." || trimmed.isEmpty || path.hasPrefix(trimmed + "/")
    }
  }

  /// Whether a source reads the scenario argument: it names it, with or without its leading
  /// `-`, outside a comment. A doc comment describing the seam doesn't read it.
  public static func readsScenarioArgument(_ sources: [String: String]) -> Bool {
    let name = String(SimSession.scenarioArgument.drop(while: { $0 == "-" }))
    guard let lexer = NeutralLexer(language: .swift) else { return false }
    return sources.values.contains { text in
      guard text.contains(name) else { return false }
      let lines = text.split(separator: "\n", omittingEmptySubsequences: false).enumerated().map {
        NeutralSourceLine(number: $0.offset + 1, text: String($0.element))
      }
      return lexer.lex(lines).contains { line in
        occurrences(of: name, in: String(line.raw))
          > line.comments.reduce(0) { $0 + occurrences(of: name, in: $1) }
      }
    }
  }

  /// The requirements, in `flowRequirements` order, whose title names a refresh: their flow drags
  /// the list to a marker pinned to the bottom of the screen's safe area.
  public static func refreshRequirements(
    flowRequirements: [String], titles: [String: String]
  ) -> [String] {
    var seen: Set<String> = []
    return flowRequirements.filter { requirement in
      guard let title = titles[requirement], seen.insert(requirement).inserted else {
        return false
      }
      return title.lowercased().split(whereSeparator: { !$0.isLetter }).contains {
        $0.hasPrefix("refresh")
      }
    }
  }

  /// Whether a source pins an identified element to the bottom of a safe area: a
  /// `.safeAreaInset(edge: .bottom…)` whose content sets an accessibility identifier, outside a
  /// comment. A marker placed as a list row scrolls with the rows, and a drag to it can't pull.
  public static func pinsBottomMarker(_ sources: [String: String]) -> Bool {
    guard let lexer = NeutralLexer(language: .swift) else { return false }
    return sources.values.contains { text in
      guard text.contains("safeAreaInset") else { return false }
      let lines = text.split(separator: "\n", omittingEmptySubsequences: false).enumerated().map {
        NeutralSourceLine(number: $0.offset + 1, text: String($0.element))
      }
      let code = lexer.lex(lines).map(\.codeString).joined(separator: "\n")
      return bottomInsets(in: code).contains { $0.contains("accessibilityIdentifier(") }
    }
  }

  /// The arguments and content of each `.safeAreaInset(edge: .bottom…) { … }` in `code`, which
  /// holds no comment or string text.
  private static func bottomInsets(in code: String) -> [Substring] {
    var found: [Substring] = []
    var rest = code[...]
    while let call = rest.range(of: ".safeAreaInset(") {
      guard let arguments = balanced(code, from: call.upperBound, open: "(", close: ")") else {
        break
      }
      rest = code[arguments.upperBound...]
      let spelled = code[call.upperBound..<arguments.upperBound].filter { !$0.isWhitespace }
      guard spelled.hasPrefix("edge:.bottom") else { continue }
      let after = code[arguments.upperBound...].drop { $0.isWhitespace }
      guard after.first == "{",
        let content = balanced(
          code, from: code.index(after: after.startIndex), open: "{", close: "}")
      else {
        found.append(code[call.upperBound..<arguments.upperBound])
        continue
      }
      found.append(code[call.upperBound..<content.upperBound])
      rest = code[content.upperBound...]
    }
    return found
  }

  /// The range from `start` to just past the `close` that balances an `open` before `start`.
  private static func balanced(
    _ code: String, from start: String.Index, open: Character, close: Character
  ) -> Range<String.Index>? {
    var depth = 1
    var index = start
    while index < code.endIndex {
      let character = code[index]
      if character == open { depth += 1 }
      if character == close {
        depth -= 1
        if depth == 0 { return start..<code.index(after: index) }
      }
      index = code.index(after: index)
    }
    return nil
  }

  private static func occurrences(of name: String, in text: String) -> Int {
    text.components(separatedBy: name).count - 1
  }
}
