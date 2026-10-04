/// A value of an old-style (OpenStep) property list, the format `project.pbxproj` is written in.
public indirect enum PlistValue: Sendable, Equatable {
  case string(String)
  case data([UInt8])
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
  case invalidData(line: Int)
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
  public var isTest: Bool { false }
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
    objects = [:]
    rootObjectID = ""
  }

  public var rootObject: PBXObject? { objects[rootObjectID] }

  public var mainGroupID: String? { nil }

  /// The project's `projectDirPath`, relative to the folder holding the `.xcodeproj`.
  public var projectDirPath: String { "" }

  /// The root object's targets that are native targets, in the project's order.
  public var nativeTargets: [PBXNativeTarget] { [] }

  public var synchronizedRootGroups: [PBXSynchronizedRootGroup] { [] }
}
