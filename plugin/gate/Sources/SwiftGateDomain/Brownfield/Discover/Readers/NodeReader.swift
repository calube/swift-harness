import Foundation

/// Reads `package.json` and its workspace file: an area per package with its test, lint and build scripts.
///
/// A workspace root (a `workspaces` field, `pnpm-workspace.yaml` or `lerna.json`) is no area itself;
/// each package its globs match is 1, and any other `package.json` under it is a sample or a
/// template. Outside a workspace, every `package.json` with a name or scripts is a package. The
/// package manager comes from the `packageManager` field or the nearest lockfile; with neither,
/// npm is a guess and so is every command that runs through it.
public struct NodeReader: EcosystemReader {
  public init() {}

  public func areas(in tree: TrackedTreeSnapshot) -> [ProposedArea] {
    let manifests = tree.paths.filter {
      CICommandMining.basename($0) == "package.json"
        && !$0.split(separator: "/").contains("node_modules")
    }
    var packages: [String: [String: Any]] = [:]
    for path in manifests {
      guard let data = tree.read(path),
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      else { continue }
      packages[CICommandMining.dirname(path)] = object
    }
    let listed = Set(tree.paths)
    var workspaces: [String: [String]] = [:]
    for (directory, object) in packages {
      if let globs = workspaceGlobs(directory: directory, package: object, tree: tree) {
        workspaces[directory] = globs
      }
    }

    var areas: [ProposedArea] = []
    for directory in packages.keys.sorted() {
      guard let object = packages[directory], workspaces[directory] == nil else { continue }
      let owners = workspaces.keys.filter {
        $0 != directory && ManifestPaths.isUnder(directory, $0)
      }
      let workspace = owners.max { $0.count < $1.count }
      if let workspace {
        guard let globs = workspaces[workspace],
          WorkspaceGlobs.matches(globs, ManifestPaths.relative(directory, to: workspace))
        else { continue }
      } else {
        guard object["name"] != nil || object["scripts"] != nil,
          !ManifestPaths.isSample(directory)
        else { continue }
      }
      areas.append(
        area(
          directory: directory, package: object, workspace: workspace,
          workspacePackage: workspace.flatMap { packages[$0] }, listed: listed))
    }
    return areas
  }

  private func area(
    directory: String, package: [String: Any], workspace: String?,
    workspacePackage: [String: Any]?, listed: Set<String>
  ) -> ProposedArea {
    let manifest = ManifestPaths.join(directory, "package.json")
    let manager = PackageManager.detect(
      directory: directory, package: package, workspace: workspace,
      workspacePackage: workspacePackage, listed: listed)
    let scripts = package["scripts"] as? [String: Any] ?? [:]
    let scriptConfidence: Confidence = manager.stated ? .found : .guessed
    var commands: [AreaStep: Sourced<String>] = [:]
    var missing: [AreaStep: String] = [:]

    if let test = scripts["test"] as? String {
      if test.contains("no test specified") {
        missing[.test] = "the test script in \(manifest) is npm's placeholder"
      } else {
        commands[.test] = Sourced(
          value: "\(manager.name) run test", source: manifest, confidence: scriptConfidence)
        if Self.takesFiles(test) {
          let separator = manager.name == "npm" ? " --" : ""
          commands[.testFiles] = Sourced(
            value: "\(manager.name) run test\(separator) {files}", source: manifest,
            confidence: .guessed)
        }
      }
    } else {
      missing[.test] = "no test script in \(manifest)"
    }

    if scripts["lint"] is String {
      commands[.lint] = Sourced(
        value: "\(manager.name) run lint", source: manifest, confidence: scriptConfidence)
    } else if let (config, tool) = lintConfig(from: directory, listed: listed) {
      commands[.lint] = Sourced(
        value: "\(manager.exec) \(tool) {files}", source: config, confidence: .guessed)
    } else {
      missing[.lint] = "no lint script in \(manifest) and no eslint or biome config"
    }

    if scripts["build"] is String {
      commands[.build] = Sourced(
        value: "\(manager.name) run build", source: manifest, confidence: scriptConfidence)
    }

    let dependencies = ["dependencies", "devDependencies"].compactMap {
      package[$0] as? [String: Any]
    }
    let typescript =
      listed.contains(ManifestPaths.join(directory, "tsconfig.json"))
      || dependencies.contains { $0["typescript"] != nil }
    let prefix = directory == "." ? "" : directory + "/"
    return ProposedArea(
      name: directory == "." ? "node" : CICommandMining.basename(directory), root: directory,
      language: typescript ? .typescript : .javascript, kind: .node, source: manifest,
      commands: commands, missing: missing,
      testGlobs: ["**/*.test.*", "**/*.spec.*", "**/__tests__/**"].map { prefix + $0 },
      xcode: nil, generatedProjectTracked: nil)
  }

  /// Whether `script` is 1 runner that takes test files as trailing arguments, so
  /// `test_files` can append them.
  static func takesFiles(_ script: String) -> Bool {
    guard !script.contains("&&"), !script.contains("||"), !script.contains(";"),
      !script.contains("|")
    else { return false }
    let runners: Set<String> = ["jest", "vitest", "mocha", "ava"]
    return script.split(separator: " ").contains { word in
      var name = CICommandMining.basename(String(word))
      if name.hasSuffix(".js") { name.removeLast(3) }
      return runners.contains(name)
    }
  }

  /// The globs that make `directory` a workspace root, or `nil` when it is none.
  private func workspaceGlobs(directory: String, package: [String: Any], tree: TrackedTreeSnapshot)
    -> [String]?
  {
    if let globs = package["workspaces"] as? [String] { return globs }
    if let object = package["workspaces"] as? [String: Any],
      let globs = object["packages"] as? [String]
    {
      return globs
    }
    if let text = ManifestPaths.text(tree, ManifestPaths.join(directory, "pnpm-workspace.yaml")) {
      return YAMLList.items(under: "packages", in: text)
    }
    if let data = tree.read(ManifestPaths.join(directory, "lerna.json")),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    {
      return object["packages"] as? [String] ?? ["packages/*"]
    }
    return nil
  }

  /// The nearest eslint or biome config at or above `directory`, and the tool it configures.
  private func lintConfig(from directory: String, listed: Set<String>) -> (String, String)? {
    let eslint = [
      "eslint.config.js", "eslint.config.mjs", "eslint.config.cjs", "eslint.config.ts",
      "eslint.config.mts", "eslint.config.cts", ".eslintrc", ".eslintrc.js", ".eslintrc.cjs",
      ".eslintrc.json", ".eslintrc.yml", ".eslintrc.yaml",
    ]
    for ancestor in ManifestPaths.ancestors(directory) {
      for name in eslint where listed.contains(ManifestPaths.join(ancestor, name)) {
        return (ManifestPaths.join(ancestor, name), "eslint")
      }
      for name in ["biome.json", "biome.jsonc"]
      where listed.contains(ManifestPaths.join(ancestor, name)) {
        return (ManifestPaths.join(ancestor, name), "biome check")
      }
    }
    return nil
  }
}

/// How a node package installs and runs its scripts.
private struct PackageManager {
  let name: String
  /// Whether a `packageManager` field or a lockfile names it.
  let stated: Bool

  /// Runs a dependency's binary.
  var exec: String {
    switch name {
    case "pnpm": "pnpm exec"
    case "yarn": "yarn exec"
    case "bun": "bunx"
    default: "npx"
    }
  }

  static let lockfiles: [(String, String)] = [
    ("pnpm-lock.yaml", "pnpm"), ("yarn.lock", "yarn"), ("bun.lock", "bun"), ("bun.lockb", "bun"),
    ("package-lock.json", "npm"), ("npm-shrinkwrap.json", "npm"),
  ]

  static func detect(
    directory: String, package: [String: Any], workspace: String?,
    workspacePackage: [String: Any]?, listed: Set<String>
  ) -> PackageManager {
    for field in [package["packageManager"], workspacePackage?["packageManager"]] {
      if let field = field as? String, let name = field.split(separator: "@").first,
        ["npm", "pnpm", "yarn", "bun"].contains(String(name))
      {
        return PackageManager(name: String(name), stated: true)
      }
    }
    for ancestor in ManifestPaths.ancestors(directory) {
      for (file, name) in lockfiles where listed.contains(ManifestPaths.join(ancestor, file)) {
        return PackageManager(name: name, stated: true)
      }
    }
    return PackageManager(name: "npm", stated: false)
  }
}

/// The items of 1 top-level list in a YAML file such as `pnpm-workspace.yaml`. A line reader, not
/// a YAML parser: the key at column 0, then its `- item` lines.
private enum YAMLList {
  static func items(under key: String, in text: String) -> [String] {
    var items: [String] = []
    var inside = false
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if line.first.map({ !$0.isWhitespace }) == true {
        inside = trimmed.hasPrefix("\(key):")
        continue
      }
      guard inside, trimmed.hasPrefix("- ") else { continue }
      var item = trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces)
      if let hash = item.range(of: " #") { item = String(item[..<hash.lowerBound]) }
      items.append(item.trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")))
    }
    return items
  }
}

/// Workspace globs as npm, yarn and pnpm read them: `*` within 1 segment, `**` across any number,
/// and a leading `!` excluding what it matches.
private enum WorkspaceGlobs {
  static func matches(_ globs: [String], _ path: String) -> Bool {
    let segments = path.split(separator: "/").map(String.init)[...]
    var included = false
    for glob in globs {
      let negated = glob.hasPrefix("!")
      let pattern = (negated ? String(glob.dropFirst()) : glob)
        .split(separator: "/").map(String.init).filter { $0 != "." }[...]
      if match(pattern, segments) { included = !negated }
    }
    return included
  }

  private static func match(_ pattern: ArraySlice<String>, _ path: ArraySlice<String>) -> Bool {
    guard let head = pattern.first else { return path.isEmpty }
    if head == "**" {
      let rest = pattern.dropFirst()
      return (path.startIndex...path.endIndex).contains { match(rest, path[$0...]) }
    }
    guard let segment = path.first, fnmatch(head, segment, 0) == 0 else { return false }
    return match(pattern.dropFirst(), path.dropFirst())
  }
}

/// Repository-relative path helpers the node, Python and Ruby readers share.
enum ManifestPaths {
  /// Directories whose packages are vendored copies, samples or test inputs, never an area.
  static let sampleSegments: Set<String> = [
    "node_modules", "vendor", "fixtures", "fixture", "__fixtures__", "testdata", "templates",
    "template", "examples", "example",
  ]

  static func isSample(_ directory: String) -> Bool {
    directory.split(separator: "/").contains { sampleSegments.contains(String($0)) }
  }

  static func join(_ directory: String, _ name: String) -> String {
    directory == "." ? name : "\(directory)/\(name)"
  }

  /// Whether `path` is `directory` or inside it.
  static func isUnder(_ path: String, _ directory: String) -> Bool {
    directory == "." || path == directory || path.hasPrefix(directory + "/")
  }

  static func relative(_ path: String, to directory: String) -> String {
    directory == "." ? path : path == directory ? "." : String(path.dropFirst(directory.count + 1))
  }

  /// `directory`, then each parent up to the repository root `.`.
  static func ancestors(_ directory: String) -> [String] {
    var result = [directory]
    var current = directory
    while current != "." {
      current = CICommandMining.dirname(current)
      result.append(current)
    }
    return result
  }

  static func text(_ tree: TrackedTreeSnapshot, _ path: String) -> String? {
    tree.read(path).map { String(decoding: $0, as: UTF8.self) }
  }
}
