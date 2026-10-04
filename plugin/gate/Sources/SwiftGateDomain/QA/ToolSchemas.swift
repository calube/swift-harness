import Foundation

/// 1 JSON Schema from the pinned tool's MCP `tools/list`, read with the closed set of keywords
/// those schemas use. A keyword outside it fails reading, naming itself, so a schema this type
/// would half-check never loads.
public final class FlowSchema: Sendable {
  /// The JSON Schema `type` names the pinned schemas use.
  enum Kind: String, Sendable {
    case object, array, string, integer, number, boolean, null

    func admits(_ value: FlowJSON) -> Bool {
      switch (self, value) {
      case (.object, .object), (.array, .array), (.string, .string), (.integer, .integer),
        (.number, .integer), (.number, .number), (.boolean, .bool), (.null, .null):
        true
      default:
        false
      }
    }
  }

  enum Additional: Sendable {
    case allowed
    case forbidden
    case schema(FlowSchema)
  }

  /// Every keyword the pinned schemas use. `description` and `commandInputFor` say nothing a
  /// value is checked against: the step rule checks `input` against its command's schema itself.
  static let keywords: Set<String> = [
    "type", "enum", "const", "properties", "required", "additionalProperties", "items",
    "minItems", "maxItems", "minimum", "maximum", "oneOf", "not", "description",
    "commandInputFor",
  ]

  let kind: Kind?
  let allowed: [FlowJSON]?
  let constant: FlowJSON?
  let properties: [String: FlowSchema]
  let required: [String]
  let additional: Additional
  let items: FlowSchema?
  let minItems: Int?
  let maxItems: Int?
  let minimum: Double?
  let maximum: Double?
  let oneOf: [FlowSchema]?
  let negated: FlowSchema?

  public init(json: FlowJSON, at path: String) throws(FlowSchemaError) {
    guard case .object(let fields) = json else {
      throw FlowSchemaError(path: path, reason: "a schema is a JSON object, not a \(json.kindName)")
    }
    if let unknown = fields.keys.sorted().first(where: { !Self.keywords.contains($0) }) {
      throw FlowSchemaError(path: path, reason: "unsupported schema keyword `\(unknown)`")
    }
    func fail(_ keyword: String, _ expected: String) -> FlowSchemaError {
      FlowSchemaError(path: path, reason: "`\(keyword)` must be \(expected)")
    }

    switch fields["type"] {
    case nil: kind = nil
    case .string(let name)?:
      guard let named = Kind(rawValue: name) else { throw fail("type", "a JSON Schema type name") }
      kind = named
    default: throw fail("type", "1 type name")
    }
    switch fields["enum"] {
    case nil: allowed = nil
    case .array(let values)?: allowed = values
    default: throw fail("enum", "an array")
    }
    constant = fields["const"]

    var properties: [String: FlowSchema] = [:]
    switch fields["properties"] {
    case nil: break
    case .object(let named)?:
      for (name, schema) in named {
        properties[name] = try FlowSchema(json: schema, at: Self.join(path, name))
      }
    default: throw fail("properties", "an object")
    }
    self.properties = properties

    switch fields["required"] {
    case nil: required = []
    case .array(let names)?:
      required = try names.map { name throws(FlowSchemaError) in
        guard case .string(let text) = name else { throw fail("required", "an array of names") }
        return text
      }
    default: throw fail("required", "an array of names")
    }
    switch fields["additionalProperties"] {
    case nil, .bool(true)?: additional = .allowed
    case .bool(false)?: additional = .forbidden
    case let schema?: additional = .schema(try FlowSchema(json: schema, at: Self.join(path, "*")))
    }
    items = try fields["items"].map { schema throws(FlowSchemaError) in
      try FlowSchema(json: schema, at: path + "[]")
    }
    func count(_ keyword: String) throws(FlowSchemaError) -> Int? {
      switch fields[keyword] {
      case nil: return nil
      case .integer(let value)?: return value
      default: throw fail(keyword, "an integer")
      }
    }
    func bound(_ keyword: String) throws(FlowSchemaError) -> Double? {
      guard let value = fields[keyword] else { return nil }
      guard let number = value.numeric else { throw fail(keyword, "a number") }
      return number
    }
    minItems = try count("minItems")
    maxItems = try count("maxItems")
    minimum = try bound("minimum")
    maximum = try bound("maximum")
    switch fields["oneOf"] {
    case nil: oneOf = nil
    case .array(let schemas)?:
      oneOf = try schemas.enumerated().map { offset, schema throws(FlowSchemaError) in
        try FlowSchema(json: schema, at: "\(path)/oneOf[\(offset)]")
      }
    default: throw fail("oneOf", "an array of schemas")
    }
    negated = try fields["not"].map { schema throws(FlowSchemaError) in
      try FlowSchema(json: schema, at: "\(path)/not")
    }
  }

  /// Every way `value` breaks this schema, each naming its place under `path`; empty when it
  /// conforms.
  public func violations(of value: FlowJSON, at path: String) -> [String] {
    if let kind, !kind.admits(value) {
      let choices = allowed.map { ", one of \(Self.list($0))" } ?? ""
      return [
        "`\(path)` must be \(Self.article(kind.rawValue))\(choices), not \(Self.article(value.kindName))"
      ]
    }
    var found: [String] = []
    if let allowed, !allowed.contains(where: { $0.sameValue(as: value) }) {
      found.append("`\(path)` is \(value.rendered), not one of \(Self.list(allowed))")
    }
    if let constant, !constant.sameValue(as: value) {
      found.append("`\(path)` is \(value.rendered), not \(constant.rendered)")
    }
    if case .object(let fields) = value {
      for name in required where fields[name] == nil {
        found.append("`\(path)` lacks the required key `\(name)`")
      }
      for name in fields.keys.sorted() {
        guard let field = fields[name] else { continue }
        if let schema = properties[name] {
          found += schema.violations(of: field, at: Self.join(path, name))
          continue
        }
        switch additional {
        case .allowed: break
        case .forbidden:
          let hint = Self.closest(to: name, in: properties.keys).map { " (did you mean `\($0)`?)" }
          found.append("`\(path)` has no key `\(name)`" + (hint ?? ""))
        case .schema(let schema):
          found += schema.violations(of: field, at: Self.join(path, name))
        }
      }
    }
    if case .array(let elements) = value {
      if let minItems, elements.count < minItems {
        found.append("`\(path)` holds \(elements.count) items, fewer than \(minItems)")
      }
      if let maxItems, elements.count > maxItems {
        found.append("`\(path)` holds \(elements.count) items, more than \(maxItems)")
      }
      if let items {
        for (offset, element) in elements.enumerated() {
          found += items.violations(of: element, at: "\(path)[\(offset)]")
        }
      }
    }
    if let number = value.numeric {
      if let minimum, number < minimum {
        found.append("`\(path)` is \(value.rendered), below the minimum \(FlowJSON.bound(minimum))")
      }
      if let maximum, number > maximum {
        found.append("`\(path)` is \(value.rendered), above the maximum \(FlowJSON.bound(maximum))")
      }
    }
    if let oneOf {
      let results = oneOf.map { $0.violations(of: value, at: path) }
      let matching = results.filter(\.isEmpty).count
      if matching == 0 {
        found.append(
          "`\(path)` matches none of its \(oneOf.count) forms: "
            + results.compactMap(\.first).joined(separator: "; or "))
      } else if matching > 1 {
        found.append("`\(path)` matches \(matching) of its forms, and must match exactly 1")
      }
    }
    if let negated, negated.violations(of: value, at: path).isEmpty {
      found.append("`\(path)` matches a form its schema rules out")
    }
    return found
  }

  static func join(_ path: String, _ key: String) -> String {
    path.isEmpty ? key : "\(path).\(key)"
  }

  static func article(_ noun: String) -> String {
    ("aeiou".contains(noun.first ?? "x") ? "an " : "a ") + noun
  }

  /// At most 8 values, then how many more.
  static func list(_ values: [FlowJSON]) -> String {
    let shown = values.prefix(8).map { value in
      if case .string(let text) = value { return text }
      return value.rendered
    }
    let more = values.count > shown.count ? " (and \(values.count - shown.count) more)" : ""
    return shown.joined(separator: ", ") + more
  }

  /// The key within 2 edits of `name`, when exactly 1 is closest.
  static func closest(to name: String, in keys: some Sequence<String>) -> String? {
    let scored = keys.map { ($0, distance(name, $0)) }.filter { $0.1 <= 2 }
    guard let best = scored.map(\.1).min() else { return nil }
    let winners = scored.filter { $0.1 == best }
    return winners.count == 1 ? winners[0].0 : nil
  }

  /// Levenshtein distance, ignoring case.
  static func distance(_ left: String, _ right: String) -> Int {
    let a = Array(left.lowercased())
    let b = Array(right.lowercased())
    guard !a.isEmpty else { return b.count }
    guard !b.isEmpty else { return a.count }
    var row = Array(0...b.count)
    for i in 1...a.count {
      var diagonal = row[0]
      row[0] = i
      for j in 1...b.count {
        let above = row[j]
        row[j] = min(above + 1, row[j - 1] + 1, diagonal + (a[i - 1] == b[j - 1] ? 0 : 1))
        diagonal = above
      }
    }
    return row[b.count]
  }
}

extension FlowJSON {
  /// A schema bound as a whole number when it is one.
  static func bound(_ value: Double) -> String {
    value.rounded() == value && abs(value) < 1e15 ? "\(Int(value))" : "\(value)"
  }
}

/// Why a schema file or 1 of its schemas can't be read, naming where.
public struct FlowSchemaError: Error, Sendable, Equatable, CustomStringConvertible {
  public let path: String
  public let reason: String

  public init(path: String, reason: String) {
    self.path = path
    self.reason = reason
  }

  public var description: String { path.isEmpty ? reason : "\(path): \(reason)" }
}

/// The pinned tool's step schemas: the shape of 1 batch step, and each command's input.
public struct ToolSchemas: Sendable {
  /// The `serverInfo.version` the schemas were captured from.
  public let version: String
  /// `batch`'s `steps.items`: which commands a step may name and which keys a step holds.
  public let step: FlowSchema
  /// Each tool's `inputSchema`, by tool name.
  public let commands: [String: FlowSchema]

  public init(version: String, step: FlowSchema, commands: [String: FlowSchema]) {
    self.version = version
    self.step = step
    self.commands = commands
  }

  /// Reads `{"serverInfo": {"version"}, "tools": [{"name", "inputSchema"}]}`, as the capture
  /// writes it.
  public static func parse(_ data: Data) throws(FlowSchemaError) -> ToolSchemas {
    let json: FlowJSON
    do {
      json = try FlowJSON.parse(data)
    } catch {
      throw FlowSchemaError(path: "", reason: "not JSON: \(error)")
    }
    guard case .object(let file) = json,
      case .object(let server)? = file["serverInfo"],
      case .string(let version)? = server["version"]
    else {
      throw FlowSchemaError(path: "", reason: "no `serverInfo.version`")
    }
    guard case .array(let tools)? = file["tools"] else {
      throw FlowSchemaError(path: "", reason: "no `tools` list")
    }
    var commands: [String: FlowSchema] = [:]
    var step: FlowSchema?
    for (offset, tool) in tools.enumerated() {
      guard case .object(let fields) = tool, case .string(let name)? = fields["name"],
        let input = fields["inputSchema"]
      else {
        throw FlowSchemaError(
          path: "tools[\(offset)]", reason: "a tool needs a `name` and an `inputSchema`")
      }
      commands[name] = try FlowSchema(json: input, at: name)
      if name == "batch" {
        guard case .object(let schema) = input,
          case .object(let properties)? = schema["properties"],
          case .object(let steps)? = properties["steps"], let items = steps["items"]
        else {
          throw FlowSchemaError(path: "batch", reason: "no `properties.steps.items` schema")
        }
        step = try FlowSchema(json: items, at: "batch.steps[]")
      }
    }
    guard let step else {
      throw FlowSchemaError(path: "", reason: "no `batch` tool, so no step schema")
    }
    return ToolSchemas(version: version, step: step, commands: commands)
  }
}
