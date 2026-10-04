import Foundation

/// Reads `Cargo.toml`: an area per workspace member, `cargo test` with a name filter, Clippy.
///
/// Every command runs from the crate's directory, the area root. A member names itself with
/// `-p <package>`, which cargo resolves against the workspace it finds above. Clippy ships with every rustup
/// toolchain, so it is always proposed, and `found` only when a `clippy.toml` configures it.
public struct CargoReader: EcosystemReader {
  public init() {}

  public func areas(in tree: TrackedTreeSnapshot) -> [ProposedArea] {
    let manifests: [(path: String, manifest: CargoManifest)] = tree.paths.compactMap { path in
      guard CICommandMining.basename(path) == "Cargo.toml", !BuildFilePaths.isSkipped(path),
        let text = BuildFilePaths.text(tree, path)
      else { return nil }
      return (path, CargoManifest(text))
    }
    let workspaces = Dictionary(
      manifests.filter { $0.manifest.members != nil }.map {
        (CICommandMining.dirname($0.path), $0.manifest)
      }, uniquingKeysWith: { first, _ in first })
    let clippyConfigs = Set(
      tree.paths.filter { ["clippy.toml", ".clippy.toml"].contains(CICommandMining.basename($0)) })

    return manifests.compactMap { path, manifest in
      guard let name = manifest.packageName else { return nil }
      let root = CICommandMining.dirname(path)
      let workspace = BuildFilePaths.ancestors(of: root).first { workspaces[$0] != nil }
      let member = workspace.flatMap { directory in
        workspaces[directory].flatMap {
          $0.contains(BuildFilePaths.relative(root, to: directory)) ? directory : nil
        }
      }
      let run = { (command: String) in
        member == nil ? "cargo \(command)" : "cargo \(command) -p \(name)"
      }
      let found = { (command: String) in Sourced(value: command, source: path, confidence: .found) }
      let clippy = BuildFilePaths.ancestors(of: root).lazy.flatMap { directory in
        ["clippy.toml", ".clippy.toml"].map { BuildFilePaths.join(directory, $0) }
      }.first(where: clippyConfigs.contains)
      return ProposedArea(
        name: name, root: root, language: .rust, kind: .cargo, source: path,
        commands: [
          .test: found(run("test")),
          .testFiles: found(run("test") + " -- {tests}"),
          .build: found(run("build")),
          .lint: Sourced(
            value: run("clippy"), source: clippy ?? path,
            confidence: clippy == nil ? .guessed : .found),
        ],
        missing: [:], testGlobs: [BuildFilePaths.join(root, "tests/**/*.rs")], xcode: nil,
        generatedProjectTracked: nil)
    }
  }
}

/// The parts of a `Cargo.toml` discovery needs: `[package] name` and `[workspace]`'s `members`
/// and `exclude`. A line reader, not a TOML parser: it reads keys at the start of a line inside
/// those 2 tables, which is how cargo itself writes them.
struct CargoManifest {
  var packageName: String?
  /// `nil` when the manifest has no `[workspace]` table.
  var members: [String]?
  var exclude: [String] = []

  init(_ text: String) {
    var table = ""
    var pendingKey: String?
    var pendingValue = ""
    for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
      let line = Self.uncommented(rawLine).trimmingCharacters(in: .whitespaces)
      if let key = pendingKey {
        pendingValue += " " + line
        if line.contains("]") {
          assign(key, pendingValue)
          pendingKey = nil
        }
        continue
      }
      if line.hasPrefix("[") {
        table = line.hasPrefix("[[") ? "" : String(line.dropFirst().prefix { $0 != "]" })
        if table == "workspace", members == nil { members = [] }
        continue
      }
      guard let equals = line.firstIndex(of: "=") else { continue }
      let key = line[..<equals].trimmingCharacters(in: .whitespaces)
      let value = String(line[line.index(after: equals)...])
      switch (table, key) {
      case ("package", "name"):
        packageName = BuildFilePaths.quotedStrings(value[...]).first
      case ("workspace", "members"), ("workspace", "exclude"):
        if value.contains("[") && !value.contains("]") {
          pendingKey = key
          pendingValue = value
        } else {
          assign(key, value)
        }
      default: continue
      }
    }
  }

  private mutating func assign(_ key: String, _ value: String) {
    let strings = BuildFilePaths.quotedStrings(value[...]).map { path in
      var path = Substring(path)
      while path.hasPrefix("./") { path = path.dropFirst(2) }
      while path.hasSuffix("/") { path = path.dropLast() }
      return String(path)
    }
    if key == "members" { members = strings } else { exclude = strings }
  }

  /// Whether `relative` (to the workspace's directory) is a member: the root package, or a
  /// `members` glob it matches outside `exclude`.
  func contains(_ relative: String) -> Bool {
    if relative == "." { return true }
    if exclude.contains(where: { relative == $0 || relative.hasPrefix($0 + "/") }) { return false }
    let segments = relative.split(separator: "/").map(String.init)
    return (members ?? []).contains { pattern in
      let parts = pattern.split(separator: "/").map(String.init)
      return parts.count == segments.count
        && zip(parts, segments).allSatisfy { fnmatch($0, $1, 0) == 0 }
    }
  }

  private static func uncommented(_ line: Substring) -> Substring {
    var quote: Character?
    for index in line.indices {
      let character = line[index]
      if let open = quote {
        if character == open { quote = nil }
      } else if character == "\"" || character == "'" {
        quote = character
      } else if character == "#" {
        return line[..<index]
      }
    }
    return line
  }
}
