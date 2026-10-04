import Foundation

/// A worker's pack in a brownfield clone, which has no design, no module graph and no owned
/// standards: the task's ledger entry, its `PLAN.md` section and the plan's assumptions, the
/// config areas its write set lies in with their commands, and the harness's brownfield rules.
public struct BrownfieldWorkerInputs: Sendable, Equatable {
  public let task: LedgerTask
  /// The plan's live `PLAN.md`.
  public let plan: ContextSource
  /// Every area `config.toml` holds; the pack keeps the ones the task's write set lies in.
  public let areas: [BrownfieldArea]
  /// The harness's `docs/standards.md`, whose brownfield profile section holds the rules.
  public let standards: ContextSource
  public let dependencyNotes: [DependencyReturnNotes]

  public init(
    task: LedgerTask, plan: ContextSource, areas: [BrownfieldArea], standards: ContextSource,
    dependencyNotes: [DependencyReturnNotes]
  ) {
    self.task = task
    self.plan = plan
    self.areas = areas
    self.standards = standards
    self.dependencyNotes = dependencyNotes
  }
}

extension ContextPack {
  /// The heading the brownfield rules' section of the standards doc starts with.
  public static let brownfieldRulesHeading = "Brownfield profile"

  public static func brownfieldWorkerPack(_ inputs: BrownfieldWorkerInputs) throws -> ContextPack {
    ContextPack(role: .worker, slices: [])
  }

  /// The areas holding `writeSet`, in config order: each entry belongs to the area with the
  /// longest root that contains it.
  public static func areas(holding writeSet: [String], in areas: [BrownfieldArea])
    -> [BrownfieldArea]
  {
    []
  }
}
