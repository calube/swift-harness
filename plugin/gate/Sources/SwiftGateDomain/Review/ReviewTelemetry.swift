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

    public init(from decoder: any Decoder) throws {
      try TelemetryKey.requireOnly(["label", "returned"], in: decoder)
      let container = try decoder.container(keyedBy: TelemetryKey.self)
      label = try container.decode(String.self, forKey: TelemetryKey("label"))
      returned = try container.decode(Bool.self, forKey: TelemetryKey("returned"))
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

  /// Closed: an unknown key, a missing `outputTokens` key, a negative count, or a `null` count
  /// with nothing in ``unavailable`` fails and names itself.
  public init(from decoder: any Decoder) throws {
    try TelemetryKey.requireOnly(["outputTokens", "agents", "unavailable"], in: decoder)
    let container = try decoder.container(keyedBy: TelemetryKey.self)
    let tokensKey = TelemetryKey("outputTokens")
    guard container.contains(tokensKey) else {
      throw DecodingError.keyNotFound(
        tokensKey,
        .init(codingPath: decoder.codingPath, debugDescription: "outputTokens must be present"))
    }
    outputTokens = try container.decode(Int?.self, forKey: tokensKey)
    agents = try container.decode([Agent].self, forKey: TelemetryKey("agents"))
    unavailable = try container.decode([String].self, forKey: TelemetryKey("unavailable"))
    if let outputTokens, outputTokens < 0 {
      throw DecodingError.dataCorruptedError(
        forKey: tokensKey, in: container, debugDescription: "outputTokens \(outputTokens) < 0")
    }
    if outputTokens == nil, unavailable.isEmpty {
      throw DecodingError.dataCorruptedError(
        forKey: tokensKey, in: container,
        debugDescription: "outputTokens is null and unavailable names no reason")
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: TelemetryKey.self)
    try container.encode(outputTokens, forKey: TelemetryKey("outputTokens"))
    try container.encode(agents, forKey: TelemetryKey("agents"))
    try container.encode(unavailable, forKey: TelemetryKey("unavailable"))
  }

  /// Reads the `telemetry` object out of a workflow's saved return value.
  public static func decodeResult(_ data: Data) throws -> WorkflowTelemetry {
    struct Envelope: Decodable { let telemetry: WorkflowTelemetry }
    return try JSONDecoder().decode(Envelope.self, from: data).telemetry
  }
}

/// Any JSON key, so a closed record can name a key it doesn't know.
struct TelemetryKey: CodingKey, Hashable {
  let stringValue: String
  var intValue: Int? { nil }

  init(_ name: String) { stringValue = name }
  init?(stringValue: String) { self.stringValue = stringValue }
  init?(intValue: Int) { nil }

  /// Fails naming the first key of the object `decoder` holds that isn't in `allowed`.
  static func requireOnly(_ allowed: Set<String>, in decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: TelemetryKey.self)
    let unknown = container.allKeys.map(\.stringValue).filter { !allowed.contains($0) }.sorted()
    if let first = unknown.first {
      throw DecodingError.dataCorrupted(
        .init(codingPath: decoder.codingPath, debugDescription: "unknown key `\(first)`"))
    }
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
