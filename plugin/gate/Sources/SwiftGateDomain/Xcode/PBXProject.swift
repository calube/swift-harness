/// A value of an old-style (OpenStep) property list, the format `project.pbxproj` is written in.
public indirect enum PlistValue: Sendable, Equatable {
  case string(String)
  case array([PlistValue])
  case dictionary([String: PlistValue])

  public var string: String? {
    if case .string(let value) = self { return value }
    return nil
  }

  public var array: [PlistValue]? {
    if case .array(let value) = self { return value }
    return nil
  }

  public var dictionary: [String: PlistValue]? {
    if case .dictionary(let value) = self { return value }
    return nil
  }
}

/// 1 entry of a project's `objects` table: its id, its `isa` and every other key.
public struct PBXObject: Sendable, Equatable {
  public let id: String
  public let isa: String
  public let fields: [String: PlistValue]

  public init(id: String, isa: String, fields: [String: PlistValue]) {
    self.id = id
    self.isa = isa
    self.fields = fields
  }

  public func string(_ key: String) -> String? { fields[key]?.string }

  /// The strings of an array field, such as `children` or `files`; empty when the key is absent.
  public func strings(_ key: String) -> [String] {
    fields[key]?.array?.compactMap(\.string) ?? []
  }
}

/// Why a `project.pbxproj` couldn't be read. Lines are 1-based.
public enum PBXProjectError: Error, Sendable, Equatable {
  case unexpectedCharacter(String, line: Int)
  case unexpectedEnd(expected: String)
  case unterminatedString(line: Int)
  case unterminatedComment(line: Int)
  case trailingContent(line: Int)
  /// A key the format requires, such as `objects` or `rootObject`, is absent or the wrong shape.
  case missingKey(String)
  /// An object the project points at, such as its root object, isn't in `objects`.
  case missingObject(String)
}

/// A build phase of a native target, with the file references of its build files. A build file
/// that names a package product rather than a file reference contributes nothing.
public struct PBXBuildPhase: Sendable, Equatable {
  public let id: String
  public let isa: String
  public let fileReferenceIDs: [String]

  public init(id: String, isa: String, fileReferenceIDs: [String]) {
    self.id = id
    self.isa = isa
    self.fileReferenceIDs = fileReferenceIDs
  }

  public var isSources: Bool { isa == "PBXSourcesBuildPhase" }
}

public struct PBXNativeTarget: Sendable, Equatable {
  public let id: String
  public let name: String
  public let productType: String?
  public let buildPhases: [PBXBuildPhase]
  public let synchronizedGroupIDs: [String]

  public init(
    id: String, name: String, productType: String?, buildPhases: [PBXBuildPhase],
    synchronizedGroupIDs: [String]
  ) {
    self.id = id
    self.name = name
    self.productType = productType
    self.buildPhases = buildPhases
    self.synchronizedGroupIDs = synchronizedGroupIDs
  }

  /// A unit or UI test bundle.
  public var isTest: Bool {
    guard let productType else { return false }
    return Self.testProductTypes.contains(productType)
  }

  private static let testProductTypes = Set(
    ["unit-test", "ui-testing"].map { "com.apple.product-type.bundle." + $0 })
}

/// 1 target's exceptions to a synchronized folder: paths relative to the folder.
public struct PBXSynchronizedExceptionSet: Sendable, Equatable {
  public let id: String
  public let targetID: String
  public let membershipExceptions: [String]

  public init(id: String, targetID: String, membershipExceptions: [String]) {
    self.id = id
    self.targetID = targetID
    self.membershipExceptions = membershipExceptions
  }
}

/// A `PBXFileSystemSynchronizedRootGroup`: a folder whose files join its targets by sitting in it.
public struct PBXSynchronizedRootGroup: Sendable, Equatable {
  public let id: String
  public let exceptions: [PBXSynchronizedExceptionSet]
  /// Subfolders, relative to the folder, that build as 1 opaque item.
  public let explicitFolders: [String]

  public init(id: String, exceptions: [PBXSynchronizedExceptionSet], explicitFolders: [String]) {
    self.id = id
    self.exceptions = exceptions
    self.explicitFolders = explicitFolders
  }
}

/// A parsed `project.pbxproj`. Parsing reads text only; the caller reads the file.
public struct PBXProject: Sendable, Equatable {
  public let objects: [String: PBXObject]
  public let rootObjectID: String

  public init(parsing text: String) throws(PBXProjectError) {
    var parser = PlistParser(bytes: Array(text.utf8))
    let top = try parser.parseDocument()
    guard case .dictionary(let table) = top else { throw .missingKey("objects") }
    guard let objectTable = table["objects"]?.dictionary else { throw .missingKey("objects") }
    guard let rootID = table["rootObject"]?.string else { throw .missingKey("rootObject") }
    var objects: [String: PBXObject] = [:]
    for (id, value) in objectTable {
      guard var fields = value.dictionary, let isa = fields["isa"]?.string else {
        throw .missingKey("isa of \(id)")
      }
      fields["isa"] = nil
      objects[id] = PBXObject(id: id, isa: isa, fields: fields)
    }
    guard objects[rootID] != nil else { throw .missingObject(rootID) }
    self.objects = objects
    self.rootObjectID = rootID
  }

  public var rootObject: PBXObject? { objects[rootObjectID] }

  public var mainGroupID: String? { rootObject?.string("mainGroup") }

  /// The project's `projectDirPath`, relative to the folder holding the `.xcodeproj`.
  public var projectDirPath: String { rootObject?.string("projectDirPath") ?? "" }

  /// The root object's targets that are native targets, in the project's order.
  public var nativeTargets: [PBXNativeTarget] {
    (rootObject?.strings("targets") ?? []).compactMap { id in
      guard let target = objects[id], target.isa == "PBXNativeTarget" else { return nil }
      return PBXNativeTarget(
        id: id, name: target.string("name") ?? id, productType: target.string("productType"),
        buildPhases: target.strings("buildPhases").compactMap(buildPhase),
        synchronizedGroupIDs: target.strings("fileSystemSynchronizedGroups"))
    }
  }

  /// Every synchronized folder, ordered by id so the answer doesn't depend on hashing.
  public var synchronizedRootGroups: [PBXSynchronizedRootGroup] {
    objects.values.filter { $0.isa == "PBXFileSystemSynchronizedRootGroup" }
      .sorted { $0.id < $1.id }
      .map { group in
        PBXSynchronizedRootGroup(
          id: group.id,
          exceptions: group.strings("exceptions").compactMap { id in
            guard let set = objects[id],
              set.isa == "PBXFileSystemSynchronizedBuildFileExceptionSet",
              let target = set.string("target")
            else { return nil }
            return PBXSynchronizedExceptionSet(
              id: id, targetID: target, membershipExceptions: set.strings("membershipExceptions"))
          },
          explicitFolders: group.strings("explicitFolders"))
      }
  }

  private func buildPhase(_ id: String) -> PBXBuildPhase? {
    guard let phase = objects[id] else { return nil }
    return PBXBuildPhase(
      id: id, isa: phase.isa,
      fileReferenceIDs: phase.strings("files").compactMap { objects[$0]?.string("fileRef") })
  }
}

/// A recursive-descent reader of the OpenStep property list grammar over UTF-8 bytes.
private struct PlistParser {
  let bytes: [UInt8]
  var index = 0
  var line = 1

  init(bytes: [UInt8]) { self.bytes = bytes }

  mutating func parseDocument() throws(PBXProjectError) -> PlistValue {
    let value = try parseValue()
    try skipTrivia()
    if index < bytes.count { throw .trailingContent(line: line) }
    return value
  }

  private mutating func parseValue() throws(PBXProjectError) -> PlistValue {
    try skipTrivia()
    guard index < bytes.count else { throw .unexpectedEnd(expected: "a value") }
    switch bytes[index] {
    case UInt8(ascii: "{"): return try parseDictionary()
    case UInt8(ascii: "("): return try parseArray()
    case UInt8(ascii: "\""): return .string(try parseQuoted())
    default:
      guard let word = parseUnquoted() else { throw unexpected() }
      return .string(word)
    }
  }

  private mutating func parseDictionary() throws(PBXProjectError) -> PlistValue {
    index += 1
    var table: [String: PlistValue] = [:]
    while true {
      try skipTrivia()
      guard index < bytes.count else { throw .unexpectedEnd(expected: "}") }
      if bytes[index] == UInt8(ascii: "}") {
        index += 1
        return .dictionary(table)
      }
      guard case .string(let key) = try parseValue() else { throw unexpected() }
      try expect("=")
      table[key] = try parseValue()
      try expect(";")
    }
  }

  private mutating func parseArray() throws(PBXProjectError) -> PlistValue {
    index += 1
    var items: [PlistValue] = []
    while true {
      try skipTrivia()
      guard index < bytes.count else { throw .unexpectedEnd(expected: ")") }
      if bytes[index] == UInt8(ascii: ")") {
        index += 1
        return .array(items)
      }
      items.append(try parseValue())
      try skipTrivia()
      guard index < bytes.count else { throw .unexpectedEnd(expected: ")") }
      if bytes[index] == UInt8(ascii: ",") {
        index += 1
      } else if bytes[index] != UInt8(ascii: ")") {
        throw unexpected()
      }
    }
  }

  private mutating func parseQuoted() throws(PBXProjectError) -> String {
    let startLine = line
    index += 1
    var out: [UInt8] = []
    while index < bytes.count {
      let byte = bytes[index]
      index += 1
      if byte == UInt8(ascii: "\"") { return String(decoding: out, as: UTF8.self) }
      if byte == UInt8(ascii: "\n") { line += 1 }
      guard byte == UInt8(ascii: "\\") else {
        out.append(byte)
        continue
      }
      guard index < bytes.count else { break }
      let escaped = bytes[index]
      index += 1
      switch escaped {
      case UInt8(ascii: "n"): out.append(0x0A)
      case UInt8(ascii: "t"): out.append(0x09)
      case UInt8(ascii: "r"): out.append(0x0D)
      default: out.append(escaped)
      }
    }
    throw .unterminatedString(line: startLine)
  }

  private mutating func parseUnquoted() -> String? {
    let start = index
    while index < bytes.count, Self.isUnquoted(bytes[index]) { index += 1 }
    guard index > start else { return nil }
    return String(decoding: bytes[start..<index], as: UTF8.self)
  }

  private static func isUnquoted(_ byte: UInt8) -> Bool {
    switch byte {
    case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
      UInt8(ascii: "0")...UInt8(ascii: "9"):
      true
    case UInt8(ascii: "_"), UInt8(ascii: "$"), UInt8(ascii: "+"), UInt8(ascii: "/"),
      UInt8(ascii: ":"), UInt8(ascii: "."), UInt8(ascii: "-"):
      true
    default: false
    }
  }

  private mutating func expect(_ character: Unicode.Scalar) throws(PBXProjectError) {
    try skipTrivia()
    guard index < bytes.count else { throw .unexpectedEnd(expected: String(character)) }
    guard bytes[index] == UInt8(ascii: character) else { throw unexpected() }
    index += 1
  }

  private func unexpected() -> PBXProjectError {
    .unexpectedCharacter(String(decoding: [bytes[index]], as: UTF8.self), line: line)
  }

  /// Whitespace, `//` line comments and `/* */` block comments, counting lines as it goes.
  private mutating func skipTrivia() throws(PBXProjectError) {
    while index < bytes.count {
      let byte = bytes[index]
      if byte == UInt8(ascii: "\n") {
        line += 1
        index += 1
      } else if byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\t")
        || byte == UInt8(ascii: "\r")
      {
        index += 1
      } else if byte == UInt8(ascii: "/"), index + 1 < bytes.count,
        bytes[index + 1] == UInt8(ascii: "/")
      {
        while index < bytes.count, bytes[index] != UInt8(ascii: "\n") { index += 1 }
      } else if byte == UInt8(ascii: "/"), index + 1 < bytes.count,
        bytes[index + 1] == UInt8(ascii: "*")
      {
        let startLine = line
        index += 2
        while true {
          guard index + 1 < bytes.count else { throw .unterminatedComment(line: startLine) }
          if bytes[index] == UInt8(ascii: "*"), bytes[index + 1] == UInt8(ascii: "/") {
            index += 2
            break
          }
          if bytes[index] == UInt8(ascii: "\n") { line += 1 }
          index += 1
        }
      } else {
        return
      }
    }
  }
}
