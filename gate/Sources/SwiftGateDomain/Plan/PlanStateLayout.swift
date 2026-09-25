/// Where shared, uncommitted plan state lives (spec §4 storage model):
/// `<git common dir>/swift-harness/plans/{index.json, <plan>/{plan.json, ledger.json,
/// orchestrator.lock}}`. The common dir is shared by every linked worktree, unlike `.harness/`,
/// which `git worktree add` never copies. Pure path arithmetic; the common dir comes from
/// `Git.commonDirectory()`, already absolute and canonical.
public struct PlanStateLayout: Sendable, Equatable {
  /// One plan's directory and files.
  public struct Plan: Sendable, Equatable {
    public let directory: String

    public var planFile: String { directory + "/plan.json" }
    public var ledgerFile: String { directory + "/ledger.json" }
    public var orchestratorLock: String { directory + "/orchestrator.lock" }
  }

  /// `<common dir>/swift-harness/plans`.
  public let root: String

  /// - Throws: ``PlanStateLayoutError/relativeCommonDirectory(_:)`` unless `commonDirectory` is
  ///   absolute; a relative one would resolve against whatever cwd the caller happens to have.
  public init(commonDirectory: String) throws(PlanStateLayoutError) {
    guard commonDirectory.hasPrefix("/") else {
      throw .relativeCommonDirectory(commonDirectory)
    }
    var base = Substring(commonDirectory)
    while base.hasSuffix("/") { base = base.dropLast() }
    root = base + "/swift-harness/plans"
  }

  public var indexFile: String { root + "/index.json" }

  /// - Throws: ``PlanStateLayoutError/invalidPlanName(_:)`` for a name that is not a single path
  ///   component, since it would address another plan's files or the index.
  public func plan(_ name: String) throws(PlanStateLayoutError) -> Plan {
    let isSingleComponent =
      !name.isEmpty && name != "." && name != ".."
      && !name.contains(where: { $0 == "/" || $0 == "\0" || $0.isNewline })
    guard isSingleComponent else { throw .invalidPlanName(name) }
    return Plan(directory: root + "/" + name)
  }
}

public enum PlanStateLayoutError: Error, Sendable, Equatable {
  case relativeCommonDirectory(String)
  case invalidPlanName(String)
}
