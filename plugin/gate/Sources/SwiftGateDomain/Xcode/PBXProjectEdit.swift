import CryptoKit
import Foundation

/// Why a file couldn't be added to a project.
public enum PBXProjectEditError: Error, Sendable, Equatable {
  case unparsable(PBXProjectError)
  case targetNotFound(String, known: [String])
  case noSourcesPhase(target: String)
  /// The extension isn't 1 a Sources phase compiles.
  case notASourceFile(String)
  /// No group of the project holds the path's folder or any folder above it.
  case outsideProject(String)
  /// The text around an object the edit touches isn't laid out the way Xcode writes it, so it
  /// can't be edited without rewriting it.
  case unrecognizedLayout(String)
}

/// The objects 1 add created or extended.
public struct PBXAddedFile: Sendable, Equatable {
  public let fileReferenceID: String
  public let buildFileID: String
  /// The group the file reference joined; `nil` when an existing reference was reused.
  public let groupID: String?
  public let sourcesPhaseID: String

  public init(
    fileReferenceID: String, buildFileID: String, groupID: String?, sourcesPhaseID: String
  ) {
    self.fileReferenceID = fileReferenceID
    self.buildFileID = buildFileID
    self.groupID = groupID
    self.sourcesPhaseID = sourcesPhaseID
  }
}

public enum PBXAddFileResult: Sendable, Equatable {
  /// `text` is the whole edited `project.pbxproj`.
  case added(PBXAddedFile, text: String)
  /// The target already compiles the path, explicitly or through a synchronized folder.
  case alreadyCompiled
}

/// Adds 1 source file to 1 target of a `project.pbxproj` by inserting lines, so every byte the
/// edit doesn't need stays as it was.
public enum PBXProjectEdit {
  /// - Parameters:
  ///   - path: repository-relative.
  ///   - projectPath: the `.xcodeproj` directory, repository-relative.
  public static func addFile(
    _ path: String, target: String, projectPath: String, to text: String
  ) throws(PBXProjectEditError) -> PBXAddFileResult {
    let project: PBXProject
    do {
      project = try PBXProject(parsing: text)
    } catch {
      throw .unparsable(error)
    }
    let targets = project.nativeTargets
    guard let native = targets.first(where: { $0.name == target }) else {
      throw .targetNotFound(target, known: targets.map(\.name))
    }
    let membership = TargetMembership(project: project, projectPath: projectPath)
    if membership.targets(compiling: path).contains(where: { $0.name == target }) {
      return .alreadyCompiled
    }
    let name = String(path.split(separator: "/").last ?? Substring(path))
    guard let fileType = fileType(of: name) else { throw .notASourceFile(path) }
    guard let phase = native.buildPhases.first(where: \.isSources) else {
      throw .noSourcesPhase(target: target)
    }

    let resolver = PBXPathResolver(project: project, projectPath: projectPath)
    var taken = Set(project.objects.keys)
    let buildFileID = freshID("buildFile", path: path, target: target, taken: &taken)
    var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

    let existing = project.objects.values
      .filter { $0.isa == "PBXFileReference" && resolver.path(of: $0.id) == path }
      .map(\.id).min()
    let fileReferenceID: String
    var groupID: String?
    if let existing {
      fileReferenceID = existing
    } else {
      let (group, relative) = try enclosingGroup(of: path, project: project, resolver: resolver)
      fileReferenceID = freshID("fileReference", path: path, target: target, taken: &taken)
      groupID = group
      let nameField = relative == name ? "" : "name = \(quoted(name)); "
      try insertObject(
        "\(fileReferenceID) /* \(name) */ = {isa = PBXFileReference; lastKnownFileType = \(fileType); \(nameField)path = \(quoted(relative)); sourceTree = \"<group>\"; };",
        id: fileReferenceID, section: "PBXFileReference", into: &lines)
      try appendItem(
        "\(fileReferenceID) /* \(name) */", to: "children", of: group, in: &lines)
    }
    try insertObject(
      "\(buildFileID) /* \(name) in Sources */ = {isa = PBXBuildFile; fileRef = \(fileReferenceID) /* \(name) */; };",
      id: buildFileID, section: "PBXBuildFile", into: &lines)
    try appendItem("\(buildFileID) /* \(name) in Sources */", to: "files", of: phase.id, in: &lines)

    let edited = lines.joined(separator: "\n")
    guard let reread = try? PBXProject(parsing: edited),
      TargetMembership(project: reread, projectPath: projectPath).targets(compiling: path)
        .contains(where: { $0.name == target })
    else {
      throw .unrecognizedLayout("the edited project doesn't compile \(path) in \(target)")
    }
    return .added(
      PBXAddedFile(
        fileReferenceID: fileReferenceID, buildFileID: buildFileID, groupID: groupID,
        sourcesPhaseID: phase.id),
      text: edited)
  }

  /// A 24-digit uppercase hex object id derived from `kind`, `path` and `target` only.
  public static func stableID(_ kind: String, path: String, target: String) -> String {
    let digest = SHA256.hash(data: Data("swiftgate:\(kind):\(target):\(path)".utf8))
    return digest.prefix(12).map { byte in
      let hex = String(byte, radix: 16, uppercase: true)
      return hex.count == 1 ? "0" + hex : hex
    }.joined()
  }

  /// The stable id, salted until it names no existing object.
  private static func freshID(
    _ kind: String, path: String, target: String, taken: inout Set<String>
  ) -> String {
    var id = stableID(kind, path: path, target: target)
    var salt = 1
    while taken.contains(id) {
      id = stableID("\(kind)#\(salt)", path: path, target: target)
      salt += 1
    }
    taken.insert(id)
    return id
  }

  /// The deepest group whose folder holds `path`, and `path` relative to it. Among groups of
  /// the same folder, one with its own `path` wins over a name-only group, then the main group.
  private static func enclosingGroup(
    of path: String, project: PBXProject, resolver: PBXPathResolver
  ) throws(PBXProjectEditError) -> (id: String, relative: String) {
    let candidates = project.objects.values.filter { $0.isa == "PBXGroup" }.compactMap {
      group -> (PBXObject, String)? in
      guard let folder = resolver.path(of: group.id) else { return nil }
      guard folder.isEmpty || path.hasPrefix(folder + "/") else { return nil }
      return (group, folder)
    }
    let best = candidates.min { lhs, rhs in
      rank(lhs, project) < rank(rhs, project)
    }
    guard let (group, folder) = best else { throw .outsideProject(path) }
    return (group.id, folder.isEmpty ? path : String(path.dropFirst(folder.count + 1)))
  }

  private static func rank(_ candidate: (PBXObject, String), _ project: PBXProject)
    -> (Int, Int, Int, String)
  {
    let (group, folder) = candidate
    return (
      -folder.count, group.string("path") == nil ? 1 : 0,
      group.id == project.mainGroupID ? 0 : 1, group.id
    )
  }

  private static let fileTypes: [String: String] = [
    "swift": "sourcecode.swift", "m": "sourcecode.c.objc", "mm": "sourcecode.cpp.objcpp",
    "c": "sourcecode.c.c", "cc": "sourcecode.cpp.cpp", "cpp": "sourcecode.cpp.cpp",
    "cxx": "sourcecode.cpp.cpp", "metal": "sourcecode.metal", "s": "sourcecode.asm",
  ]

  private static func fileType(of name: String) -> String? {
    guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return nil }
    return fileTypes[String(name[name.index(after: dot)...])]
  }

  /// Bare when the parser reads it back unquoted, as Xcode writes it.
  private static func quoted(_ value: String) -> String {
    let bare = value.utf8.allSatisfy { byte in
      switch byte {
      case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
        UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "_"), UInt8(ascii: "$"),
        UInt8(ascii: "/"), UInt8(ascii: ":"), UInt8(ascii: "."), UInt8(ascii: "-"):
        true
      default: false
      }
    }
    if bare, !value.isEmpty { return value }
    let escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
      .replacingOccurrences(of: "\n", with: "\\n")
    return "\"\(escaped)\""
  }

  /// Inserts a 1-line object in id order within its section, creating the section in name
  /// order when the project has none.
  private static func insertObject(
    _ object: String, id: String, section: String, into lines: inout [String]
  ) throws(PBXProjectEditError) {
    let begin = "/* Begin \(section) section */"
    let end = "/* End \(section) section */"
    guard let start = lines.firstIndex(of: begin) else {
      let sections = lines.indices.filter {
        lines[$0].hasPrefix("/* Begin ") && lines[$0].hasSuffix(" section */")
      }
      guard
        let lastEnd = lines.lastIndex(where: {
          $0.hasPrefix("/* End ") && $0.hasSuffix(" section */")
        })
      else {
        throw .unrecognizedLayout("no object sections")
      }
      if let next = sections.first(where: { lines[$0] > begin }) {
        lines.insert(contentsOf: [begin, "\t\t" + object, end, ""], at: next)
      } else {
        lines.insert(contentsOf: ["", begin, "\t\t" + object, end], at: lastEnd + 1)
      }
      return
    }
    guard let stop = lines[start...].firstIndex(of: end) else {
      throw .unrecognizedLayout("\(section) section has no end")
    }
    let objectLines = (start + 1..<stop).filter { index in
      let line = lines[index]
      let indent = line.prefix { $0 == "\t" || $0 == " " }
      return indent.count == indentation(lines, start + 1, stop).count
        && line.dropFirst(indent.count).first?.isHexDigit == true
    }
    let indent = indentation(lines, start + 1, stop)
    let position =
      objectLines.first { lines[$0].dropFirst(indent.count).prefix(id.count) > id } ?? stop
    lines.insert(indent + object, at: position)
  }

  /// The indentation of a section's first object, or Xcode's 2 tabs for an empty section.
  private static func indentation(_ lines: [String], _ from: Int, _ to: Int) -> String {
    guard from < to else { return "\t\t" }
    return String(lines[from].prefix { $0 == "\t" || $0 == " " })
  }

  /// Appends an item to an array field of a multi-line object, at the indentation of the
  /// field's items.
  private static func appendItem(
    _ item: String, to field: String, of objectID: String, in lines: inout [String]
  ) throws(PBXProjectEditError) {
    guard
      let start = lines.firstIndex(where: { line in
        let trimmed = line.drop { $0 == "\t" || $0 == " " }
        return trimmed.hasPrefix(objectID + " ") && trimmed.hasSuffix("= {")
          && (trimmed.hasPrefix(objectID + " = {") || trimmed.hasPrefix(objectID + " /*"))
      })
    else {
      throw .unrecognizedLayout("\(objectID) isn't a multi-line object")
    }
    let objectIndent = lines[start].prefix { $0 == "\t" || $0 == " " }
    let objectEnd = objectIndent + "};"
    guard let stop = lines[(start + 1)...].firstIndex(of: String(objectEnd)) else {
      throw .unrecognizedLayout("\(objectID) has no end")
    }
    guard
      let opener = (start + 1..<stop).first(where: {
        lines[$0].drop { $0 == "\t" || $0 == " " } == "\(field) = ("
      })
    else {
      throw .unrecognizedLayout("\(objectID) has no multi-line \(field)")
    }
    let fieldIndent = lines[opener].prefix { $0 == "\t" || $0 == " " }
    guard let closer = (opener + 1..<stop).first(where: { lines[$0] == fieldIndent + ");" })
    else {
      throw .unrecognizedLayout("\(objectID)'s \(field) has no end")
    }
    let itemIndent =
      closer > opener + 1
      ? String(lines[opener + 1].prefix { $0 == "\t" || $0 == " " })
      : fieldIndent + (fieldIndent.contains("\t") ? "\t" : "    ")
    lines.insert(itemIndent + item + ",", at: closer)
  }
}
