import Foundation

/// How 1 of the report's inputs was read.
public enum RunReportInput<Value: Sendable & Equatable>: Sendable, Equatable {
  case read(Value)
  /// No file at `path`: nothing was recorded there.
  case missing(path: String)
  /// `source` exists but didn't decode, or couldn't be located; `reason` says which.
  case unreadable(source: String, reason: String)
}

/// A plan's newest build run: what it started with and what it recorded.
public struct RunReportBuild: Sendable, Equatable {
  public let record: BuildRunRecord
  public let log: BuildEventLog

  public init(record: BuildRunRecord, log: BuildEventLog) {
    self.record = record
    self.log = log
  }
}

/// Everything the end-of-run report reads, already loaded.
public struct BrownfieldRunReportInputs: Sendable, Equatable {
  public let slug: String
  public let planBranch: String
  /// The plan branch's head commit; `nil` when the branch doesn't exist.
  public let planBranchHead: String?
  /// `<plan-dir>/PLAN.md`'s text.
  public let plan: RunReportInput<String>
  /// `baseline/<tree>.json` at the plan branch's base tree.
  public let baseline: RunReportInput<BaselineFile>
  /// `discover/last.json`.
  public let discover: RunReportInput<DiscoverRecord>
  public let build: RunReportInput<RunReportBuild>

  public init(
    slug: String, planBranch: String, planBranchHead: String?, plan: RunReportInput<String>,
    baseline: RunReportInput<BaselineFile>, discover: RunReportInput<DiscoverRecord>,
    build: RunReportInput<RunReportBuild>
  ) {
    self.slug = slug
    self.planBranch = planBranch
    self.planBranchHead = planBranchHead
    self.plan = plan
    self.baseline = baseline
    self.discover = discover
    self.build = build
  }
}

/// The report a brownfield run ends with (design §11.6): the final verdict, the assumptions, the
/// baseline failures, the build-only areas, the dropped steps, the review fallbacks and the plan
/// branch to merge.
public struct BrownfieldRunReport: Sendable, Equatable, Encodable {
  /// The report's file in the plan dir.
  public static let fileName = "REPORT.md"

  /// The branch `swiftgate run` creates for a plan at the user's `HEAD`.
  public static func planBranch(slug: String) -> String { "swift-harness/\(slug)" }

  /// 1 report section. `note` says why its source couldn't be read; it is `nil` when the items
  /// are the whole answer, including none.
  public struct Section<Item: Sendable & Equatable & Encodable>: Sendable, Equatable, Encodable {
    public let items: [Item]
    public let note: String?

    public init(items: [Item], note: String?) {
      self.items = items
      self.note = note
    }
  }

  public struct Final: Sendable, Equatable, Encodable {
    public let verdict: Verdict
    public let runID: String

    public init(verdict: Verdict, runID: String) {
      self.verdict = verdict
      self.runID = runID
    }
  }

  public struct BaselineFailureLine: Sendable, Equatable, Encodable {
    public let area: String
    public let step: AreaStep
    /// `nil` when the whole step failed with no test id to read.
    public let test: String?

    public init(area: String, step: AreaStep, test: String?) {
      self.area = area
      self.step = step
      self.test = test
    }
  }

  public struct DroppedStep: Sendable, Equatable, Encodable {
    public let area: String
    public let step: AreaStep
    public let reason: String

    public init(area: String, step: AreaStep, reason: String) {
      self.area = area
      self.step = step
      self.reason = reason
    }
  }

  public let plan: String
  public let planBranch: String
  public let planBranchHead: String?
  /// The last `final` gate the plan's newest build run recorded; `nil` when none was.
  public let final: Final?
  /// Why ``final`` is `nil`, or what to know about the log it came from.
  public let finalNote: String?
  public let assumptions: Section<String>
  public let baselineFailures: Section<BaselineFailureLine>
  /// Each `## Areas` bullet of `PLAN.md` marked `build-only`, as written.
  public let buildOnlyAreas: Section<String>
  public let droppedSteps: Section<DroppedStep>
  public let reviewFallbacks: Section<String>

  public init(
    plan: String, planBranch: String, planBranchHead: String?, final: Final?, finalNote: String?,
    assumptions: Section<String>, baselineFailures: Section<BaselineFailureLine>,
    buildOnlyAreas: Section<String>, droppedSteps: Section<DroppedStep>,
    reviewFallbacks: Section<String>
  ) {
    self.plan = plan
    self.planBranch = planBranch
    self.planBranchHead = planBranchHead
    self.final = final
    self.finalNote = finalNote
    self.assumptions = assumptions
    self.baselineFailures = baselineFailures
    self.buildOnlyAreas = buildOnlyAreas
    self.droppedSteps = droppedSteps
    self.reviewFallbacks = reviewFallbacks
  }

  public static func make(_ inputs: BrownfieldRunReportInputs) -> BrownfieldRunReport {
    let empty = Section<String>(items: [], note: nil)
    return BrownfieldRunReport(
      plan: inputs.slug, planBranch: inputs.planBranch, planBranchHead: inputs.planBranchHead,
      final: nil, finalNote: nil, assumptions: empty,
      baselineFailures: Section(items: [], note: nil), buildOnlyAreas: empty,
      droppedSteps: Section(items: [], note: nil), reviewFallbacks: empty)
  }

  /// The report as Markdown, the final verdict on its first line.
  public var text: String { "" }
}
