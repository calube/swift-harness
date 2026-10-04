import Foundation

/// The part of a task's plan section the run viewer's task drawer shows: the goal, why, scope,
/// acceptance and out-of-scope lines, as the plan's author wrote them.
public struct TaskBrief: Sendable, Equatable, Codable {
  /// The section's one-line goal.
  public let title: String
  /// `nil` when the section has no `- Why:` line.
  public let why: String?
  /// The first design section (`§…`) the why cites; `nil` when it cites none.
  public let designRef: String?
  public let scope: [String]
  public let acceptance: [String]
  public let outOfScope: [String]

  public init(
    title: String, why: String?, designRef: String?, scope: [String], acceptance: [String],
    outOfScope: [String]
  ) {
    self.title = title
    self.why = why
    self.designRef = designRef
    self.scope = scope
    self.acceptance = acceptance
    self.outOfScope = outOfScope
  }

  private enum CodingKeys: String, CodingKey {
    case title, why, designRef, scope, acceptance, outOfScope
  }

  /// `why` and `designRef` are omitted when `nil`, never written as an empty string.
  public func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(title, forKey: .title)
    try c.encodeIfPresent(why, forKey: .why)
    try c.encodeIfPresent(designRef, forKey: .designRef)
    try c.encode(scope, forKey: .scope)
    try c.encode(acceptance, forKey: .acceptance)
    try c.encode(outOfScope, forKey: .outOfScope)
  }
}

/// One `### <task-id>` section of a brownfield `PLAN.md`.
public struct LivePlanTask: Sendable, Equatable {
  public let id: String
  public let deps: [String]
  public let gate: CheckTier
  /// `nil` when the section names no model; the preset's worker model applies.
  public let model: TaskModel?
  public let estLines: Int
  /// Exact paths or `/`-terminated prefixes, repo-relative.
  public let writes: [String]
  public let brief: TaskBrief

  public init(
    id: String, deps: [String], gate: CheckTier, model: TaskModel?, estLines: Int,
    writes: [String], brief: TaskBrief
  ) {
    self.id = id
    self.deps = deps
    self.gate = gate
    self.model = model
    self.estLines = estLines
    self.writes = writes
    self.brief = brief
  }
}

/// A brownfield run's live plan, `<common>/swift-harness/plans/<slug>/PLAN.md`, as parsed.
public struct LivePlan: Sendable, Equatable {
  public let tasks: [LivePlanTask]
  /// One entry per bullet of the `## Assumptions` section: each reading made of an ambiguous spec.
  public let assumptions: [String]

  public init(tasks: [LivePlanTask], assumptions: [String]) {
    self.tasks = tasks
    self.assumptions = assumptions
  }
}

/// Why a `PLAN.md` can't become a ledger. Each case names the task and the line at fault.
public enum LivePlanError: Error, Sendable, Equatable {
  case noTasks
  case duplicateTask(String)
  case missingGoal(task: String)
  case missingField(task: String, field: String)
  case unknownGate(task: String, value: String)
  /// A tier of the owned profile, which a brownfield clone can't run.
  case ownedProfileGate(task: String, tier: CheckTier)
  case unknownModel(task: String, value: String)
  case invalidEstLines(task: String, value: String)
  case noWrites(task: String)
  case invalidWrite(task: String, path: String)
  case missingDependency(task: String, dependency: String)
  case cycle(ids: [String])

  public var message: String { "" }
}

/// Reads `PLAN.md` in the task-section shape the brownfield plan fixes.
public enum LivePlanParser {
  public static func parse(_ text: String) throws(LivePlanError) -> LivePlan {
    LivePlan(tasks: [], assumptions: [])
  }
}

extension LivePlan {
  /// The executor's ledger. A task id `existing` already holds keeps its status, branch, worktree
  /// and line count, so a re-import after an edit doesn't reset work in flight.
  public func ledger(
    maxParallel: Int, existing: Ledger?, worktree: (String) -> String
  ) throws(LivePlanError) -> Ledger {
    Ledger(schemaVersion: 1, resume: "", maxParallel: maxParallel, tasks: [], waves: [])
  }

  /// A live-plan `plan.json` carrying each task's brief. `existing`'s surface commit is kept.
  public func planFile(slug: String, resume: String, existing: PlanFile?) -> PlanFile {
    PlanFile(
      schemaVersion: 1, slug: slug, source: .livePlan(PlanFile.LivePlanSource(briefs: [:])),
      surfaceCommit: existing?.surfaceCommit, resume: resume)
  }
}

/// The `.git/info/exclude` line that keeps the root `PLAN.md` symlink out of `git status`.
public enum LivePlanExclude {
  public static let line = "/" + PlanFile.LivePlanSource.fileName

  /// `text` with ``line`` appended, or `nil` when it already holds the line.
  public static func adding(to text: String?) -> String? {
    nil
  }
}
