/// One problem in a `.swiftgate.toml`. `path` names the offending key in the file's own spelling,
/// such as `modules[2].kind`.
public enum ConfigIssue: Sendable, Equatable, CustomStringConvertible {
  case unknownKey(path: String)
  case missingKey(path: String)
  case wrongType(path: String, expected: String, found: String)
  case emptyValue(path: String)
  case outOfRange(path: String, value: String, allowed: String)
  case unsupportedSchema(found: Int)
  case unknownModuleKind(path: String, value: String)
  case unknownJudgeBackend(path: String, value: String)
  /// A closed field, such as a build preset's `review` or `worker_model`, holding a value none of
  /// its cases recognize.
  case unknownEnumValue(path: String, value: String, allowed: [String])
  case missingReason(path: String, module: String, rule: ReasonRule)
  case duplicateName(path: String, name: String)
  case tooManyFlows(count: Int, max: Int)
  case judgeThresholdsInverted(advisory: Double, block: Double)

  /// Why a module entry needs a `reason`.
  public enum ReasonRule: Sendable, Equatable {
    case nonDefaultKind(ModuleKind)
    case notHostTestable
  }

  public var path: String {
    switch self {
    case .unknownKey(let path), .missingKey(let path), .wrongType(let path, _, _),
      .emptyValue(let path), .outOfRange(let path, _, _), .unknownModuleKind(let path, _),
      .unknownJudgeBackend(let path, _), .unknownEnumValue(let path, _, _),
      .missingReason(let path, _, _), .duplicateName(let path, _):
      path
    case .unsupportedSchema: "schema"
    case .tooManyFlows: "flows"
    case .judgeThresholdsInverted: "judge"
    }
  }

  public var description: String {
    switch self {
    case .unknownKey(let path):
      "\(path): unknown key"
    case .missingKey(let path):
      "\(path): required key is missing"
    case .wrongType(let path, let expected, let found):
      "\(path): expected \(expected), found \(found)"
    case .emptyValue(let path):
      "\(path): must not be empty"
    case .outOfRange(let path, let value, let allowed):
      "\(path): \(value) is out of range (allowed: \(allowed))"
    case .unsupportedSchema(let found):
      "schema: \(found) is not supported (this swiftgate reads schema \(Config.supportedSchema))"
    case .unknownModuleKind(let path, let value):
      "\(path): unknown kind \"\(value)\" (allowed: "
        + ModuleKind.allCases.map(\.rawValue).joined(separator: ", ") + ")"
    case .unknownJudgeBackend(let path, let value):
      "\(path): unknown backend \"\(value)\" (allowed: none, "
        + JudgeBackend.allCases.map(\.rawValue).joined(separator: ", ") + ")"
    case .unknownEnumValue(let path, let value, let allowed):
      "\(path): unknown value \"\(value)\" (allowed: " + allowed.joined(separator: ", ") + ")"
    case .missingReason(let path, let module, .nonDefaultKind(let kind)):
      "\(path): module \"\(module)\" declares kind \"\(kind.rawValue)\" without a reason"
    case .missingReason(let path, let module, .notHostTestable):
      "\(path): module \"\(module)\" sets host_testable = false without a reason"
    case .duplicateName(let path, let name):
      "\(path): \"\(name)\" is declared more than once"
    case .tooManyFlows(let count, let max):
      "flows: \(count) flows declared, pyramid.max_flows is \(max)"
    case .judgeThresholdsInverted(let advisory, let block):
      "judge: advisory_threshold \(advisory) is above block_threshold \(block)"
    }
  }
}

/// Every problem found in a config, not just the first, so one edit fixes them all.
public struct ConfigValidationError: Error, Sendable, Equatable, CustomStringConvertible {
  public let issues: [ConfigIssue]

  public init(issues: [ConfigIssue]) {
    precondition(!issues.isEmpty, "a validation error carries at least one issue")
    self.issues = issues
  }

  public var description: String {
    issues.map(\.description).joined(separator: "\n")
  }
}
