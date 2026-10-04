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
  /// A backend that sends test source to a third-party host, with no `send_to` naming that host.
  case judgeHostNotNamed(path: String, backend: JudgeBackend, host: String)
  /// `send_to` names a host other than the one the backend sends to.
  case judgeHostMismatch(path: String, value: String, backend: JudgeBackend, host: String)
  /// `send_to` set while the backend is off (`nil`) or sends to no host a repository names.
  case judgeHostUnused(path: String, backend: JudgeBackend?)
  /// A model alias where the backend needs a versioned id, since an alias moves without a change
  /// in the repository.
  case judgeModelNotPinned(path: String, value: String, backend: JudgeBackend, pin: String)
  /// A key named like a credential; `.swiftgate.toml` is committed, so a key never goes there.
  case judgeSecretInConfig(path: String)
  /// A value that belongs to the other ``RepositoryProfile``, such as a `slice` gate in an owned
  /// repository or a moving model alias in a brownfield clone.
  case notInProfile(path: String, value: String, profile: RepositoryProfile, allowed: [String])
  /// A brownfield area of kind `xcode` with no `[areas.xcode]` table.
  case xcodeTableMissing(path: String, area: String)
  /// An `[areas.xcode]` table on an area whose kind isn't `xcode`.
  case xcodeTableUnexpected(path: String, area: String, kind: AreaKind)
  /// Both or neither of keys only 1 of which may be set.
  case exactlyOne(path: String, keys: [String])

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
      .missingReason(let path, _, _), .duplicateName(let path, _),
      .judgeHostNotNamed(let path, _, _), .judgeHostMismatch(let path, _, _, _),
      .judgeHostUnused(let path, _), .judgeModelNotPinned(let path, _, _, _),
      .judgeSecretInConfig(let path):
      path
    case .unsupportedSchema: "schema"
    case .tooManyFlows: "flows"
    case .judgeThresholdsInverted: "judge"
    case .notInProfile, .xcodeTableMissing, .xcodeTableUnexpected, .exactlyOne: ""
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
    case .judgeHostNotNamed(let path, let backend, let host):
      "\(path): backend \"\(backend.rawValue)\" sends test source to \(host); add "
        + "send_to = \"\(host)\" to [judge] to allow it"
    case .judgeHostMismatch(let path, let value, let backend, let host):
      "\(path): \"\(value)\" is not the host backend \"\(backend.rawValue)\" sends to "
        + "(allowed: \"\(host)\")"
    case .judgeHostUnused(let path, let backend?):
      "\(path): backend \"\(backend.rawValue)\" sends to no host named here; remove send_to"
    case .judgeHostUnused(let path, nil):
      "\(path): the judge is off, so send_to allows nothing; remove it"
    case .judgeModelNotPinned(let path, let value, let backend, let pin):
      "\(path): \"\(value)\" is an alias that can move to a new \(backend.rawValue) model; "
        + "pin a versioned id such as \"\(pin)\", or remove model to use \"\(pin)\""
    case .judgeSecretInConfig(let path):
      "\(path): looks like a credential, and \(Config.fileName) is committed; set the key in "
        + "the environment ("
        + JudgeBackend.allCases.compactMap { backend in
          backend.keyVariable.map { "\(backend.rawValue): \($0)" }
        }.joined(separator: ", ") + ") and remove it here"
    case .notInProfile, .xcodeTableMissing, .xcodeTableUnexpected, .exactlyOne: ""
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
