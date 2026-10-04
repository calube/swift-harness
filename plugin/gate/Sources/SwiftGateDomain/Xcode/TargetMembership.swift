/// A target as membership answers name it.
public struct XcodeTarget: Sendable, Hashable {
  public let name: String
  public let isTest: Bool

  public init(name: String, isTest: Bool) {
    self.name = name
    self.isTest = isTest
  }
}

/// Which targets of 1 Xcode project build a repository path, from the project's explicit build
/// phases and its synchronized folders. Paths are repository-relative.
public struct TargetMembership: Sendable {
  public let project: PBXProject
  /// The `.xcodeproj` directory, repository-relative, such as `ios/App.xcodeproj`.
  public let projectPath: String
  private let entries: [Entry]

  public init(project: PBXProject, projectPath: String) {
    self.project = project
    self.projectPath = projectPath
    let resolver = PBXPathResolver(project: project, projectPath: projectPath)
    let groups = project.synchronizedRootGroups
    entries = project.nativeTargets.map { target in
      var compiled: Set<String> = []
      var included: Set<String> = []
      for phase in target.buildPhases {
        let paths = phase.fileReferenceIDs.flatMap(resolver.paths(ofReference:))
        included.formUnion(paths)
        if phase.isSources { compiled.formUnion(paths) }
      }
      var folders: [SynchronizedFolder] = []
      var adopted: Set<String> = []
      for group in groups {
        guard let root = resolver.path(of: group.id) else { continue }
        let sets = group.exceptions.filter { $0.targetID == target.id }
        if target.synchronizedGroupIDs.contains(group.id) {
          folders.append(
            SynchronizedFolder(
              root: root, excluded: sets.flatMap(\.membershipExceptions),
              explicitFolders: group.explicitFolders))
        } else {
          // A set naming a target that doesn't own the folder lists the files that target takes in.
          for set in sets {
            adopted.formUnion(set.membershipExceptions.compactMap { pbxJoin(root, $0) })
          }
        }
      }
      return Entry(
        target: XcodeTarget(name: target.name, isTest: target.isTest), compiled: compiled,
        included: included.union(adopted), adopted: adopted, folders: folders)
    }
  }

  /// Targets whose Sources phase compiles the path, explicitly or through a synchronized folder.
  public func targets(compiling path: String) -> [XcodeTarget] {
    let compilable = Self.isCompilable(path)
    return entries.filter { entry in
      entry.compiled.contains(path)
        || (compilable
          && (entry.adopted.contains(path)
            || entry.folders.contains { $0.takes(path, intoSources: true) }))
    }.map(\.target)
  }

  /// Targets any of whose build phases hold the path, or whose synchronized folders take it in.
  public func targets(including path: String) -> [XcodeTarget] {
    entries.filter { entry in
      entry.included.contains(path)
        || ancestors(of: path).contains { entry.included.contains($0) }
        || entry.folders.contains { $0.takes(path, intoSources: false) }
    }.map(\.target)
  }

  /// Folders that hold a file some target compiles, and every synchronized folder.
  public var sourceRoots: [String] {
    var roots: Set<String> = []
    for entry in entries {
      roots.formUnion(entry.compiled.map(pbxDirectory(of:)))
      roots.formUnion(entry.folders.map(\.root))
    }
    return roots.sorted()
  }

  /// `xcode.file-not-in-target` for each new Swift file under a source root that no target
  /// compiles. `inclusion` picks the remedy the message names.
  public func newFileFindings(
    _ newFiles: [String], inclusion: XcodeInclusion
  ) throws(ReportContractViolation) -> [Finding] {
    let roots = sourceRoots
    var findings: [Finding] = []
    for path in newFiles where path.hasSuffix(".swift") {
      let enclosing = roots.filter { $0.isEmpty || path.hasPrefix($0 + "/") }
      guard let root = enclosing.max(by: { $0.count < $1.count }),
        targets(compiling: path).isEmpty
      else { continue }
      let rootName = root.isEmpty ? "the repository root" : "`\(root)`"
      findings.append(
        try Finding(
          ruleID: BrownfieldRuleID.fileNotInTarget.rawValue, severity: .major, file: path,
          line: nil,
          message:
            "`\(path)` is a new Swift file under \(rootName), but no target of `\(projectPath)` compiles it. \(remedy(path, inclusion))",
          failureScenario:
            "The build never compiles `\(path)`, so its code and its tests don't run while the area's build stays green."
        ))
    }
    return findings
  }

  private func remedy(_ path: String, _ inclusion: XcodeInclusion) -> String {
    switch inclusion {
    case .explicit:
      "Add it with `swiftgate xcode add-file \(path) --target <target>`."
    case .synchronized:
      "Move it under a target's synchronized folder, or drop the exception that leaves it out."
    case .xcodegen:
      "Cover it with a target's `sources` in the XcodeGen spec and run `xcodegen generate`."
    case .tuist:
      "Cover it with a target's `sources` in `Project.swift` and run `tuist generate`."
    }
  }

  /// Extensions a Sources phase compiles when a synchronized folder holds the file; anything
  /// else in the folder is a resource or a header.
  private static let compilableExtensions: Set<String> = [
    "swift", "m", "mm", "c", "cc", "cpp", "cxx", "metal", "s", "xcdatamodeld", "mlmodel",
    "mlpackage", "intentdefinition",
  ]

  private static func isCompilable(_ path: String) -> Bool {
    guard let name = path.split(separator: "/").last, let dot = name.lastIndex(of: ".") else {
      return false
    }
    return compilableExtensions.contains(String(name[name.index(after: dot)...]))
  }
}

private struct Entry: Sendable {
  let target: XcodeTarget
  let compiled: Set<String>
  let included: Set<String>
  /// Files of folders this target doesn't own that an exception set adds to it.
  let adopted: Set<String>
  let folders: [SynchronizedFolder]
}

private struct SynchronizedFolder: Sendable {
  let root: String
  /// Paths relative to the folder that this target leaves out.
  let excluded: [String]
  let explicitFolders: [String]

  func takes(_ path: String, intoSources: Bool) -> Bool {
    guard let relative = relative(path, to: root) else { return false }
    if excluded.contains(where: { covers($0, relative) }) { return false }
    if intoSources, explicitFolders.contains(where: { covers($0, relative) }) { return false }
    return true
  }
}

/// Resolves each object's path through its parent groups' `path` and `sourceTree`, relative to
/// the repository root.
struct PBXPathResolver {
  let project: PBXProject
  let projectDirectory: String?
  let parents: [String: String]

  init(project: PBXProject, projectPath: String) {
    self.project = project
    projectDirectory = pbxJoin(pbxDirectory(of: projectPath), project.projectDirPath)
    var parents: [String: String] = [:]
    for object in project.objects.values {
      for child in object.strings("children") { parents[child] = object.id }
    }
    self.parents = parents
  }

  func path(of id: String) -> String? {
    guard let object = project.objects[id] else { return nil }
    let base: String?
    switch object.string("sourceTree") ?? "<group>" {
    case "<group>": base = parents[id].map(path(of:)) ?? projectDirectory
    case "SOURCE_ROOT": base = projectDirectory
    default: return nil
    }
    guard let base else { return nil }
    guard let own = object.string("path") else { return base }
    return pbxJoin(base, own)
  }

  /// A build file's reference: a file, or a variant or version group standing for its children.
  /// A variant group without its own `path` would resolve to its parent's folder, so only its
  /// children stand for it.
  func paths(ofReference id: String) -> [String] {
    guard let object = project.objects[id] else { return [] }
    let children = object.strings("children")
    let own =
      children.isEmpty || object.string("path") != nil ? path(of: id).map { [$0] } ?? [] : []
    return own + children.compactMap(path(of:))
  }
}

/// `base/relative` with `.` and `..` folded; nil when it climbs above the repository root.
func pbxJoin(_ base: String, _ relative: String) -> String? {
  var parts: [Substring] = []
  for part in (base + "/" + relative).split(separator: "/") {
    switch part {
    case ".": continue
    case "..":
      guard !parts.isEmpty else { return nil }
      parts.removeLast()
    default: parts.append(part)
    }
  }
  return parts.joined(separator: "/")
}

func pbxDirectory(of path: String) -> String {
  guard let slash = path.lastIndex(of: "/") else { return "" }
  return String(path[..<slash])
}

private func ancestors(of path: String) -> [String] {
  var result: [String] = []
  var current = pbxDirectory(of: path)
  while !current.isEmpty {
    result.append(current)
    current = pbxDirectory(of: current)
  }
  return result
}

private func relative(_ path: String, to root: String) -> String? {
  if root.isEmpty { return path }
  guard path.hasPrefix(root + "/") else { return nil }
  return String(path.dropFirst(root.count + 1))
}

/// Whether an exception or explicit-folder entry names the path or a folder holding it.
private func covers(_ entry: String, _ relative: String) -> Bool {
  relative == entry || relative.hasPrefix(entry + "/")
}
