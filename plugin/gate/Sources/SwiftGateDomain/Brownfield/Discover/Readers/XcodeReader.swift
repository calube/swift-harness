import Foundation

/// Reads Xcode projects and workspaces: schemes from shared `.xcscheme` files, test targets and the inclusion kind.
///
/// 1 area per generator manifest (a Tuist `Workspace.swift` or `Project.swift`, an XcodeGen
/// `project.yml`), then per workspace, then per project no earlier area claims. Every area is
/// rooted at its manifest's or container's directory, where its commands run. Nothing is built:
/// the warm-up's build proves the scheme.
public struct XcodeReader: EcosystemReader {
  public init() {}

  public func areas(in tree: TrackedTreeSnapshot) -> [ProposedArea] {
    Self.units(in: tree).map { $0.proposed(tree) }
  }

  /// Directories whose `Package.swift` an Xcode area already builds: each area's own directory,
  /// and every local package its projects or workspace reference.
  static func packageDirectories(claimedIn tree: TrackedTreeSnapshot) -> Set<String> {
    let packages = Set(
      tree.paths.filter { SwiftDiscoverPaths.basename($0) == "Package.swift" }.map(
        SwiftDiscoverPaths.dirname))
    var claimed: Set<String> = []
    for unit in units(in: tree) {
      claimed.insert(unit.root)
      for project in unit.projects {
        guard let text = tree.read(project.pbxproj).map({ String(decoding: $0, as: UTF8.self) })
        else { continue }
        for relative in localPackagePaths(in: text) {
          if let path = SwiftDiscoverPaths.resolve(relative, in: project.directory) {
            claimed.insert(path)
          }
        }
      }
      claimed.formUnion(unit.workspaceReferences.filter(packages.contains))
    }
    return claimed.intersection(packages)
  }

  // MARK: - Units

  struct Project {
    /// `<dir>/<name>.xcodeproj`.
    let path: String
    var pbxproj: String { path + "/project.pbxproj" }
    var directory: String { SwiftDiscoverPaths.dirname(path) }
  }

  struct Unit {
    var root: String
    var name: String
    var source: String
    var inclusion: XcodeInclusion?
    var manifest: String?
    var workspace: String?
    var projects: [Project]
    /// The project a generator writes, tracked or not.
    var generatedProject: String? = nil
    /// Directories a workspace's file references point at.
    var workspaceReferences: [String] = []
    var declaredSchemes: [String] = []
    var generatedProjectTracked: Bool?
  }

  static func units(in tree: TrackedTreeSnapshot) -> [Unit] {
    let paths = tree.paths
    var projects = paths.filter { $0.hasSuffix(".xcodeproj/project.pbxproj") }.map {
      Project(path: SwiftDiscoverPaths.dirname($0))
    }
    var units: [Unit] = []
    func claim(_ predicate: (Project) -> Bool) -> [Project] {
      let taken = projects.filter(predicate)
      projects.removeAll(where: predicate)
      return taken
    }

    let tuist = paths.filter { path in
      ["Project.swift", "Workspace.swift"].contains(SwiftDiscoverPaths.basename(path))
        && text(tree, path)?.contains("import ProjectDescription") == true
    }
    var tuistProjects = tuist.filter { SwiftDiscoverPaths.basename($0) == "Project.swift" }
    for manifest in tuist where SwiftDiscoverPaths.basename(manifest) == "Workspace.swift" {
      let root = SwiftDiscoverPaths.dirname(manifest)
      let members = tuistProjects.filter {
        SwiftDiscoverPaths.isUnder(SwiftDiscoverPaths.dirname($0), root)
      }
      tuistProjects.removeAll(where: members.contains)
      units.append(
        tuistUnit(
          tree, manifest: manifest, anchor: "Workspace(", members: [manifest] + members,
          claim: claim))
    }
    for manifest in tuistProjects {
      units.append(
        tuistUnit(tree, manifest: manifest, anchor: "Project(", members: [manifest], claim: claim))
    }

    for manifest in paths
    where ["project.yml", "project.yaml"].contains(
      SwiftDiscoverPaths.basename(manifest))
    {
      guard let spec = text(tree, manifest), let name = topLevelValue("name", in: spec),
        topLevelValue("targets", in: spec) != nil || topLevelValue("include", in: spec) != nil
      else { continue }
      let root = SwiftDiscoverPaths.dirname(manifest)
      let generated = SwiftDiscoverPaths.join(root, "\(name).xcodeproj")
      let owned = claim { $0.path == generated }
      units.append(
        Unit(
          root: root, name: name, source: manifest, inclusion: .xcodegen, manifest: manifest,
          workspace: nil, projects: owned, generatedProject: generated,
          generatedProjectTracked: !owned.isEmpty))
    }

    for data in paths where data.hasSuffix(".xcworkspace/contents.xcworkspacedata") {
      let workspace = SwiftDiscoverPaths.dirname(data)
      let parts = SwiftDiscoverPaths.components(workspace)
      // A project's own `project.xcworkspace`, a package's `.swiftpm` workspace and a
      // playground's workspace are never opened on their own.
      guard SwiftDiscoverPaths.dirname(workspace).hasSuffix(".xcodeproj") == false,
        !parts.contains(".swiftpm"), !parts.contains(where: { $0.hasSuffix(".playground") }),
        let xml = tree.read(data)
      else { continue }
      let root = SwiftDiscoverPaths.dirname(workspace)
      let references = WorkspaceReferences.paths(in: xml, directory: root)
      let owned = claim { references.contains($0.path) }
      if let index = units.firstIndex(where: { $0.root == root && $0.inclusion != nil }) {
        units[index].workspace = workspace
        units[index].projects += owned
        units[index].workspaceReferences += references
        continue
      }
      units.append(
        Unit(
          root: root, name: stem(workspace), source: data, inclusion: nil, manifest: nil,
          workspace: workspace, projects: owned, workspaceReferences: references))
    }

    for project in projects {
      units.append(
        Unit(
          root: project.directory, name: stem(project.path), source: project.pbxproj,
          inclusion: nil, manifest: nil, workspace: nil, projects: [project]))
    }
    return units
  }

  private static func tuistUnit(
    _ tree: TrackedTreeSnapshot, manifest: String, anchor: String, members: [String],
    claim: ((Project) -> Bool) -> [Project]
  ) -> Unit {
    let root = SwiftDiscoverPaths.dirname(manifest)
    let manifestText = text(tree, manifest) ?? ""
    let name =
      SwiftDiscoverText.quoted(after: "name:", following: anchor, in: manifestText)
      ?? SwiftDiscoverPaths.basename(root)
    let directories = Set(members.map(SwiftDiscoverPaths.dirname))
    let owned = claim { directories.contains($0.directory) }
    let schemes = members.flatMap { member in
      declaredTuistSchemes(in: text(tree, member) ?? "")
    }
    return Unit(
      root: root, name: name, source: manifest, inclusion: .tuist, manifest: manifest,
      workspace: SwiftDiscoverPaths.join(root, "\(name).xcworkspace"), projects: owned,
      declaredSchemes: schemes, generatedProjectTracked: !owned.isEmpty)
  }

  // MARK: - Reading files

  static func text(_ tree: TrackedTreeSnapshot, _ path: String) -> String? {
    tree.read(path).map { String(decoding: $0, as: UTF8.self) }
  }

  static func stem(_ path: String) -> String {
    let base = SwiftDiscoverPaths.basename(path)
    guard let dot = base.lastIndex(of: ".") else { return base }
    return String(base[..<dot])
  }

  /// A YAML key at column 0 and its inline value, which is empty for a block.
  static func topLevelValue(_ key: String, in yaml: String) -> String? {
    for line in yaml.split(separator: "\n", omittingEmptySubsequences: false)
    where line.hasPrefix(key + ":") {
      return line.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
        .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }
    return nil
  }

  /// Every `.scheme(name: "…")` a Tuist manifest spells as a literal.
  static func declaredTuistSchemes(in manifest: String) -> [String] {
    var schemes: [String] = []
    var rest = manifest[...]
    while let range = rest.range(of: ".scheme(") {
      rest = rest[range.upperBound...]
      let body = rest.drop { $0.isWhitespace }
      guard body.hasPrefix("name:") else { continue }
      if let name = SwiftDiscoverText.quoted(after: "name:", in: String(body)) {
        schemes.append(name)
      }
    }
    return schemes
  }

  /// `relativePath` of every `XCLocalSwiftPackageReference` in a `project.pbxproj`.
  static func localPackagePaths(in pbxproj: String) -> [String] {
    var paths: [String] = []
    var rest = pbxproj[...]
    while let isa = rest.range(of: "isa = XCLocalSwiftPackageReference;") {
      let end =
        rest.range(of: "};", range: isa.upperBound..<rest.endIndex)?.lowerBound
        ?? rest.endIndex
      let object = rest[isa.upperBound..<end]
      if let key = object.range(of: "relativePath = ") {
        let value = object[key.upperBound...].prefix { $0 != ";" }
        paths.append(value.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")))
      }
      rest = rest[end...]
    }
    return paths
  }

  struct Scheme {
    let name: String
    let path: String
    let testTargets: [String]
  }

  /// Shared schemes only: a scheme under `xcuserdata` is 1 user's and never reaches a clone.
  static func sharedSchemes(_ unit: Unit, _ tree: TrackedTreeSnapshot) -> [Scheme] {
    let containers = unit.projects.map(\.path) + [unit.workspace].compactMap { $0 }
    return tree.paths.compactMap { path in
      guard path.hasSuffix(".xcscheme"),
        containers.contains(where: { path.hasPrefix($0 + "/xcshareddata/xcschemes/") })
      else { return nil }
      let xml = text(tree, path) ?? ""
      return Scheme(name: stem(path), path: path, testTargets: testableNames(in: xml))
    }.sorted { $0.name < $1.name }
  }

  static func testableNames(in scheme: String) -> [String] {
    var names: [String] = []
    var rest = scheme[...]
    while let start = rest.range(of: "<TestableReference") {
      let end = rest.range(of: "</TestableReference>", range: start.upperBound..<rest.endIndex)
      let block = rest[start.upperBound..<(end?.lowerBound ?? rest.endIndex)]
      if let name = SwiftDiscoverText.quoted(
        after: "BlueprintName =", in: String(block))
      {
        names.append(name)
      }
      rest = rest[(end?.upperBound ?? rest.endIndex)...]
    }
    return names
  }
}

extension XcodeReader.Unit {
  func proposed(_ tree: TrackedTreeSnapshot) -> ProposedArea {
    let schemes = XcodeReader.sharedSchemes(self, tree)
    let names = Array(Set(schemes.map(\.name) + declaredSchemes)).sorted()
    let inclusion = self.inclusion ?? observedInclusion(tree)
    let project = workspace == nil ? projects.first?.path ?? generatedProject : nil
    let container =
      workspace.map { "-workspace \(word($0))" } ?? project.map { "-project \(word($0))" }
    var commands: [AreaStep: Sourced<String>] = [:]
    var missing: [AreaStep: String] = [:]
    let buildScheme = preferred(names)
    if let container, let buildScheme {
      let schemeSource = schemes.first { $0.name == buildScheme }?.path ?? source
      commands[.build] = Sourced(
        value:
          "xcodebuild build \(container) -scheme \(SwiftDiscoverText.shellWord(buildScheme))"
          + " -destination \(destination(buildScheme, generic: true)) -skipMacroValidation",
        source: schemeSource, confidence: .found)
    } else {
      missing[.build] = "no shared scheme in tracked files"
    }
    let testable = schemes.filter { !$0.testTargets.isEmpty }
    if let container, let testScheme = preferred(testable.map(\.name)),
      let scheme = testable.first(where: { $0.name == testScheme })
    {
      // The simulator a test runs on is this machine's to name; the warm-up proves the guess.
      commands[.test] = Sourced(
        value:
          "xcodebuild test \(container) -scheme \(SwiftDiscoverText.shellWord(testScheme))"
          + " -destination \(destination(testScheme, generic: false)) -skipMacroValidation",
        source: scheme.path, confidence: .guessed)
    } else {
      missing[.test] = "no shared scheme with a test target in tracked files"
    }
    if let lint = SwiftDiscoverLint.command(root: root, tree: tree) {
      commands[.lint] = lint
    } else {
      missing[.lint] = SwiftDiscoverLint.missingReason
    }
    let testTargets = Array(Set(testable.flatMap(\.testTargets))).sorted()
    return ProposedArea(
      name: SwiftDiscoverText.areaName(root == "." ? name : SwiftDiscoverPaths.basename(root)),
      root: root, language: .swift, kind: .xcode, source: source, commands: commands,
      missing: missing,
      testGlobs: testTargets.map { SwiftDiscoverPaths.join(root, "**/\($0)/**/*.swift") },
      xcode: Sourced(
        value: XcodeAreaConfig(
          workspace: workspace, project: project,
          inclusion: inclusion, manifest: manifest, schemes: names),
        source: manifest ?? source, confidence: .found),
      generatedProjectTracked: generatedProjectTracked)
  }

  /// Synchronized only when every project it builds holds a synchronized root group, since a file
  /// added to an explicit project still needs its 4 entries.
  private func observedInclusion(_ tree: TrackedTreeSnapshot) -> XcodeInclusion {
    let synchronized = projects.map {
      XcodeReader.text(tree, $0.pbxproj)?.contains("PBXFileSystemSynchronizedRootGroup") == true
    }
    return !synchronized.isEmpty && synchronized.allSatisfy { $0 } ? .synchronized : .explicit
  }

  /// The scheme named after the area, then 1 for iOS, then the first by name.
  private func preferred(_ schemes: [String]) -> String? {
    let sorted = schemes.sorted()
    return sorted.first { $0 == name } ?? sorted.first { $0.contains("iOS") } ?? sorted.first
  }

  private func destination(_ scheme: String, generic: Bool) -> String {
    let platform =
      [
        ("macOS", "macOS"), ("tvOS", "tvOS Simulator"), ("watchOS", "watchOS Simulator"),
        ("visionOS", "visionOS Simulator"),
      ].first { scheme.contains($0.0) }?.1 ?? "iOS Simulator"
    if generic { return AreaCommandExpansion.shellQuoted("generic/platform=\(platform)") }
    let device =
      switch platform {
      case "macOS": ""
      case "tvOS Simulator": ",name=Apple TV"
      case "watchOS Simulator": ",name=Apple Watch Series 11 (46mm)"
      case "visionOS Simulator": ",name=Apple Vision Pro"
      default: ",name=iPhone 17"
      }
    return AreaCommandExpansion.shellQuoted("platform=\(platform)\(device)")
  }

  private func word(_ path: String) -> String {
    SwiftDiscoverText.shellWord(SwiftDiscoverPaths.relative(path, from: root))
  }
}

/// The directories an `.xcworkspace`'s `FileRef`s point at, resolved through their enclosing
/// `Group`s.
enum WorkspaceReferences {
  static func paths(in xml: Data, directory: String) -> [String] {
    let delegate = Delegate(directory: directory)
    let parser = XMLParser(data: xml)
    parser.delegate = delegate
    parser.parse()
    return delegate.paths
  }

  private final class Delegate: NSObject, XMLParserDelegate {
    var stack: [String]
    var paths: [String] = []

    init(directory: String) { stack = [directory] }

    func parser(
      _ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
      qualifiedName: String?, attributes: [String: String]
    ) {
      guard element == "FileRef" || element == "Group" else { return }
      let base = stack.last ?? "."
      var resolved = base
      if let location = attributes["location"], let colon = location.firstIndex(of: ":") {
        let scheme = location[..<colon]
        let relative = String(location[location.index(after: colon)...])
        if scheme == "group" || scheme == "container" {
          resolved = SwiftDiscoverPaths.resolve(relative, in: base) ?? base
        }
      }
      if element == "Group" {
        stack.append(resolved)
      } else if resolved != base {
        paths.append(resolved)
      }
    }

    func parser(
      _ parser: XMLParser, didEndElement element: String, namespaceURI: String?,
      qualifiedName: String?
    ) {
      if element == "Group", stack.count > 1 { stack.removeLast() }
    }
  }
}
