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
    do {
      return try JSONDecoder().decode(FlowJSON.self, from: data)
    } catch let DecodingError.dataCorrupted(context) {
      throw FlowJSONError(
        reason: (context.underlyingError as NSError?)?.userInfo[NSDebugDescriptionErrorKey]
          as? String ?? context.debugDescription)
    } catch {
      throw FlowJSONError(reason: "\(error)")
    }
  }

  /// The JSON Schema type name of this value, as messages name it.
  public var kindName: String {
    switch self {
    case .null: "null"
    case .bool: "boolean"
    case .integer: "integer"
    case .number: "number"
    case .string: "string"
    case .array: "array"
    case .object: "object"
    }
  }

  /// The value as a number, for an integer or a number.
  public var numeric: Double? {
    switch self {
    case .integer(let value): Double(value)
    case .number(let value): value
    default: nil
    }
  }

  /// JSON equality: an integer equals the number of the same value.
  public func sameValue(as other: FlowJSON) -> Bool {
    if let left = numeric, let right = other.numeric { return left == right }
    switch (self, other) {
    case (.array(let left), .array(let right)):
      return left.count == right.count
        && zip(left, right).allSatisfy { $0.sameValue(as: $1) }
    case (.object(let left), .object(let right)):
      return left.count == right.count
        && left.allSatisfy { key, value in right[key].map(value.sameValue(as:)) ?? false }
    default:
      return self == other
    }
  }

  /// The value as compact JSON text, for messages.
  public var rendered: String {
    switch self {
    case .null: "null"
    case .bool(let value): "\(value)"
    case .integer(let value): "\(value)"
    case .number(let value): "\(value)"
    case .string(let value): "\"\(value)\""
    case .array(let values): "[" + values.map(\.rendered).joined(separator: ",") + "]"
    case .object(let fields):
      "{"
        + fields.keys.sorted().map { "\"\($0)\":\(fields[$0]?.rendered ?? "null")" }
        .joined(separator: ",") + "}"
    }
  }
}

extension FlowJSON: Decodable {
  /// Tries the narrowest kind first, so `true` stays a boolean and `3` an integer.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Int.self) {
      self = .integer(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([FlowJSON].self) {
      self = .array(value)
    } else {
      self = .object(try container.decode([String: FlowJSON].self))
    }
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

  public init(number: Int, command: String, input: [String: FlowJSON], fields: [String: FlowJSON]) {
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
    let json: FlowJSON
    do {
      json = try FlowJSON.parse(data)
    } catch {
      throw FlowStepsError(reason: "it isn't JSON: \(error)")
    }
    guard case .array(let items) = json else {
      throw FlowStepsError(reason: "it is a JSON \(json.kindName), not a list of steps")
    }
    var steps: [FlowStep] = []
    for (offset, item) in items.enumerated() {
      let number = offset + 1
      guard case .object(let fields) = item else {
        throw FlowStepsError(
          reason: "step \(number) is a JSON \(item.kindName), not a {\"command\", \"input\"} object"
        )
      }
      guard case .string(let command)? = fields["command"] else {
        throw FlowStepsError(reason: "step \(number) has no string `command`")
      }
      guard case .object(let input)? = fields["input"] else {
        throw FlowStepsError(reason: "step \(number) (`\(command)`) has no object `input`")
      }
      steps.append(FlowStep(number: number, command: command, input: input, fields: fields))
    }
    return steps
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
