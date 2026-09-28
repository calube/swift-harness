import Foundation

/// What a Workflow script returns under `telemetry`: only numbers the Workflow runtime reported.
/// `workflows/review.js`, `design-research.js` and `design-review.js` all return this shape.
public struct WorkflowTelemetry: Sendable, Equatable, Codable {
  public struct Agent: Sendable, Equatable, Codable {
    /// The workflow's agent label, such as `review:concurrency` or `research:codebase`.
    public let label: String
    /// Whether the agent came back with a result.
    public let returned: Bool

    public init(label: String, returned: Bool) {
      self.label = label
      self.returned = returned
    }
  }

  /// The Workflow runtime's `budget.spent()` delta across the run: output tokens only, and it
  /// includes any main-loop output produced while the workflow ran. `nil` when the runtime gave
  /// the script no budget; ``unavailable`` then says so.
  public let outputTokens: Int?
  public let agents: [Agent]
  public let unavailable: [String]

  public init(outputTokens: Int?, agents: [Agent], unavailable: [String]) {
    self.outputTokens = outputTokens
    self.agents = agents
    self.unavailable = unavailable
  }

  /// Reads the `telemetry` object out of a workflow's saved return value.
  public static func decodeResult(_ data: Data) throws -> WorkflowTelemetry {
    struct Envelope: Decodable { let telemetry: WorkflowTelemetry }
    return try JSONDecoder().decode(Envelope.self, from: data).telemetry
  }
}

/// `review-telemetry.json` in the review's run directory (gitignored with `.harness/runs/`): what
/// one review cost, holding only numbers a tool reported. Anything no tool reports is named in
/// ``unavailable`` rather than estimated.
public struct ReviewTelemetry: Sendable, Equatable, Codable {
  public static let schemaVersion = 1
  public static let fileName = "review-telemetry.json"

  public typealias Agent = WorkflowTelemetry.Agent
  public typealias Workflow = WorkflowTelemetry

  public let schemaVersion: Int
  public let runID: String
  /// When `review-input` started the run, read from the run id.
  public let startedAt: String?
  public let finishedAt: String
  /// From the start of `review-input` to the end of `review-synth`.
  public let wallSeconds: Int?
  public let outputTokens: Int?
  public let agents: [Agent]?
  public let unavailable: [String]

  /// `workflow` is the workflow's report, or why it couldn't be read.
  public static func make(
    runID: String, finishedAt: Date, workflow: Result<Workflow, WorkflowUnavailable>
  ) -> ReviewTelemetry {
    var unavailable: [String] = []
    let started = startDate(runID: runID)
    if started == nil {
      unavailable.append(
        "wall time: the run id \(runID) carries no start time (expected yyyyMMddTHHmmssZ-<hex>)")
    }
    var reported: Workflow?
    switch workflow {
    case .success(let value):
      reported = value
      unavailable += value.unavailable
    case .failure(let failure):
      unavailable.append(
        "output tokens and agent calls: \(failure.reason)")
    }
    let formatter = ISO8601DateFormatter()
    return ReviewTelemetry(
      schemaVersion: schemaVersion, runID: runID,
      startedAt: started.map { formatter.string(from: $0) },
      finishedAt: formatter.string(from: finishedAt),
      wallSeconds: started.map { Int(finishedAt.timeIntervalSince($0).rounded()) },
      outputTokens: reported?.outputTokens, agents: reported?.agents, unavailable: unavailable)
  }

  public struct WorkflowUnavailable: Error, Sendable, Equatable {
    public let reason: String
    public init(reason: String) { self.reason = reason }
  }

  /// Reads the `telemetry` object out of the workflow's saved return value.
  public static func decodeWorkflow(_ data: Data) throws -> Workflow {
    try WorkflowTelemetry.decodeResult(data)
  }

  /// `RunID.make`'s leading UTC timestamp.
  static func startDate(runID: String) -> Date? {
    let stamp = runID.prefix(16)
    guard stamp.count == 16, runID.dropFirst(16).first == "-" else { return nil }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
    return formatter.date(from: String(stamp))
  }
}
