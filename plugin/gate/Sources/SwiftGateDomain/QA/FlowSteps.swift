import Foundation

/// A JSON value from a batch steps file or the pinned tool's schemas, kept whole so a rule can
/// read any key of any step.
public indirect enum FlowJSON: Sendable, Equatable {
  case null
  case bool(Bool)
  case integer(Int)
  case number(Double)
  case string(String)
  case array([FlowJSON])
  case object([String: FlowJSON])

  public static func parse(_ data: Data) throws(FlowJSONError) -> FlowJSON {
    .null
  }
}

/// Why bytes aren't JSON.
public struct FlowJSONError: Error, Sendable, Equatable, CustomStringConvertible {
  public let reason: String

  public init(reason: String) {
    self.reason = reason
  }

  public var description: String { reason }
}

/// 1 step of an `agent-device batch` steps file: `{"command": "<name>", "input": {...}}`.
public struct FlowStep: Sendable, Equatable {
  /// 1-based, as `agent-device batch` numbers a step in its errors.
  public let number: Int
  public let command: String
  public let input: [String: FlowJSON]
  /// The whole step object, `command` and `input` included.
  public let fields: [String: FlowJSON]

  public init(number: Int, command: String, input: [String: FlowJSON], fields: [String: FlowJSON])
  {
    self.number = number
    self.command = command
    self.input = input
    self.fields = fields
  }
}

/// Reads a batch steps file (simulator QA amendment §6.1).
public enum FlowSteps {
  /// A prepared flow's file name ends with this, as in `qa/<name>.flow.json`.
  public static let fileSuffix = ".flow.json"

  /// - Throws: when the bytes aren't a JSON array of objects that each hold a string `command`
  ///   and an object `input`, naming the first step that isn't.
  public static func parse(_ data: Data) throws(FlowStepsError) -> [FlowStep] {
    []
  }
}

/// Why a steps file isn't a list of steps.
public struct FlowStepsError: Error, Sendable, Equatable, CustomStringConvertible {
  public let reason: String

  public init(reason: String) {
    self.reason = reason
  }

  public var description: String { reason }
}
