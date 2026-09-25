/// A format-neutral parsed config document. Adapters translate their syntax (TOML) into this tree;
/// ``ConfigSchema`` validates it into a ``Config``, so the rules live in one pure place.
public indirect enum ConfigValue: Sendable, Equatable {
  case string(String)
  case integer(Int64)
  case float(Double)
  case boolean(Bool)
  case array([ConfigValue])
  case table([String: ConfigValue])
  /// A value the source format supports but no config key accepts, such as a TOML date-time.
  case unsupported(typeName: String)

  public var typeName: String {
    switch self {
    case .string: "string"
    case .integer: "integer"
    case .float: "float"
    case .boolean: "boolean"
    case .array: "array"
    case .table: "table"
    case .unsupported(let typeName): typeName
    }
  }
}
