/// What one judge call cost and how long it took, as far as the backend reports it. A `nil` field
/// means the backend didn't report it, never zero.
public struct JudgeUsage: Sendable, Equatable, Codable {
  /// Every prompt token the backend processed, cached reads and writes included.
  public let inputTokens: Int?
  public let outputTokens: Int?
  public let costUSD: Double?
  public let wallMilliseconds: Int
  /// The backend's own time for the call, when it reports one apart from wall time.
  public let backendMilliseconds: Int?
  /// The model that answered, as the backend names it, which can differ from the requested alias.
  public let servedModel: String?
  /// Answered from the local cache, so no backend call was made.
  public let cached: Bool

  public init(
    inputTokens: Int? = nil, outputTokens: Int? = nil, costUSD: Double? = nil,
    wallMilliseconds: Int, backendMilliseconds: Int? = nil, servedModel: String? = nil,
    cached: Bool = false
  ) {
    self.inputTokens = inputTokens
    self.outputTokens = outputTokens
    self.costUSD = costUSD
    self.wallMilliseconds = wallMilliseconds
    self.backendMilliseconds = backendMilliseconds
    self.servedModel = servedModel
    self.cached = cached
  }

  public static func milliseconds(_ duration: Duration) -> Int {
    let (seconds, attoseconds) = duration.components
    return Int(seconds) * 1000 + Int(attoseconds / 1_000_000_000_000_000)
  }
}

/// A judge's answers together with what producing them cost.
public struct JudgeReply: Sendable, Equatable {
  public let answers: [JudgeAnswer]
  public let usage: JudgeUsage?

  public init(answers: [JudgeAnswer], usage: JudgeUsage?) {
    self.answers = answers
    self.usage = usage
  }
}
