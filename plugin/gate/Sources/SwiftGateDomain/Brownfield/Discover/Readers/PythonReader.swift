import Foundation

/// Reads `pyproject.toml` and `setup.cfg`: an area per project, the test runner with a filter, its linter.
///
/// A project is a `pyproject.toml` with a `[project]` or `[tool.poetry]` table, or a `setup.cfg`
/// with `[metadata]` or `[options]`; a file holding only tool settings configures the projects
/// under it. pytest is found when a file in the project configures it or the project depends on
/// it, and guessed when the project only holds `test_*.py` files. The linter is the nearest ruff,
/// flake8 or pylint config at or above the project, as each tool itself looks for one. Commands
/// run through the nearest lockfile's tool (uv, Poetry or PDM), else `python -m`.
public struct PythonReader: EcosystemReader {
  public init() {}

  public func areas(in tree: TrackedTreeSnapshot) -> [ProposedArea] {
    let listed = Set(tree.paths)
    var projects: [String: String] = [:]
    for path in tree.paths.sorted() {
      let name = CICommandMining.basename(path)
      guard name == "pyproject.toml" || name == "setup.cfg" else { continue }
      let directory = CICommandMining.dirname(path)
      guard projects[directory] == nil || name == "pyproject.toml",
        !ManifestPaths.isSample(directory),
        let text = ManifestPaths.text(tree, path)
      else { continue }
      let tables = INITables.names(in: text)
      let isProject =
        name == "pyproject.toml"
        ? tables.contains("project") || INITables.configures("poetry", tables)
        : tables.contains("metadata") || tables.contains("options")
      if isProject { projects[directory] = path }
    }
    return projects.keys.sorted().compactMap { directory in
      projects[directory].map {
        area(directory: directory, manifest: $0, tree: tree, listed: listed)
      }
    }
  }

  private func area(
    directory: String, manifest: String, tree: TrackedTreeSnapshot, listed: Set<String>
  ) -> ProposedArea {
    let runner = runnerPrefix(from: directory, listed: listed)
    var commands: [AreaStep: Sourced<String>] = [:]
    var missing: [AreaStep: String] = [:]

    let pytest: (source: String, confidence: Confidence)? =
      pytestConfig(in: directory, tree: tree, listed: listed).map { ($0, .found) }
      ?? (hasTests(under: directory, paths: tree.paths) ? (manifest, .guessed) : nil)
    if let pytest {
      commands[.test] = Sourced(
        value: "\(runner)pytest", source: pytest.source, confidence: pytest.confidence)
      commands[.testFiles] = Sourced(
        value: "\(runner)pytest {files}", source: pytest.source, confidence: pytest.confidence)
    } else {
      missing[.test] = "no pytest configuration or test files in \(directory)"
    }

    if let (source, tool) = linter(from: directory, tree: tree, listed: listed) {
      commands[.lint] = Sourced(
        value: "\(runner)\(tool) {files}", source: source, confidence: .found)
    } else {
      missing[.lint] = "no ruff, flake8 or pylint config at or above \(directory)"
    }

    let prefix = directory == "." ? "" : directory + "/"
    return ProposedArea(
      name: directory == "." ? "python" : CICommandMining.basename(directory), root: directory,
      language: .python, kind: .python, source: manifest, commands: commands, missing: missing,
      testGlobs: ["**/test_*.py", "**/*_test.py"].map { prefix + $0 }, xcode: nil,
      generatedProjectTracked: nil)
  }

  private func runnerPrefix(from directory: String, listed: Set<String>) -> String {
    for ancestor in ManifestPaths.ancestors(directory) {
      for (lockfile, runner) in [("uv.lock", "uv"), ("poetry.lock", "poetry"), ("pdm.lock", "pdm")]
      where listed.contains(ManifestPaths.join(ancestor, lockfile)) {
        return "\(runner) run "
      }
    }
    return "python -m "
  }

  /// The file in `directory` that configures pytest or lists it as a dependency.
  private func pytestConfig(in directory: String, tree: TrackedTreeSnapshot, listed: Set<String>)
    -> String?
  {
    let pyproject = ManifestPaths.join(directory, "pyproject.toml")
    if let text = ManifestPaths.text(tree, pyproject),
      INITables.configures("pytest", INITables.names(in: text))
        || Self.dependsOnPytest(text)
    {
      return pyproject
    }
    let pytestINI = ManifestPaths.join(directory, "pytest.ini")
    if listed.contains(pytestINI) { return pytestINI }
    for (file, table) in [("setup.cfg", "tool:pytest"), ("tox.ini", "pytest")] {
      let path = ManifestPaths.join(directory, file)
      if let text = ManifestPaths.text(tree, path), INITables.names(in: text).contains(table) {
        return path
      }
    }
    return nil
  }

  /// Whether a line outside a comment names the `pytest` package itself, not a plugin such as
  /// `pytest-cov` or a module path such as `pytest.mark`.
  static func dependsOnPytest(_ text: String) -> Bool {
    let word: (Character) -> Bool = { $0.isLetter || $0.isNumber || "-_.".contains($0) }
    for line in text.split(separator: "\n") {
      var content = Substring(line)
      if let hash = content.firstIndex(of: "#") { content = content[..<hash] }
      var search = content.startIndex
      while let range = content.range(of: "pytest", range: search..<content.endIndex) {
        let before =
          range.lowerBound == content.startIndex
          ? nil : content[content.index(before: range.lowerBound)]
        let after = range.upperBound == content.endIndex ? nil : content[range.upperBound]
        if !(before.map(word) ?? false), !(after.map(word) ?? false) { return true }
        search = range.upperBound
      }
    }
    return false
  }

  private func hasTests(under directory: String, paths: [String]) -> Bool {
    paths.contains { path in
      guard ManifestPaths.isUnder(path, directory), path.hasSuffix(".py") else { return false }
      let name = CICommandMining.basename(path)
      return name.hasPrefix("test_") || name.hasSuffix("_test.py")
    }
  }

  /// The nearest linter config at or above `directory`, and the command that runs it.
  private func linter(from directory: String, tree: TrackedTreeSnapshot, listed: Set<String>)
    -> (String, String)?
  {
    for ancestor in ManifestPaths.ancestors(directory) {
      let path = { ManifestPaths.join(ancestor, $0) }
      let tables = { (file: String) in
        ManifestPaths.text(tree, path(file)).map(INITables.names(in:)) ?? []
      }
      for file in ["ruff.toml", ".ruff.toml"] where listed.contains(path(file)) {
        return (path(file), "ruff check")
      }
      if INITables.configures("ruff", tables("pyproject.toml")) {
        return (path("pyproject.toml"), "ruff check")
      }
      if listed.contains(path(".flake8")) { return (path(".flake8"), "flake8") }
      for file in ["setup.cfg", "tox.ini"] where tables(file).contains("flake8") {
        return (path(file), "flake8")
      }
      for file in [".pylintrc", "pylintrc"] where listed.contains(path(file)) {
        return (path(file), "pylint")
      }
      if INITables.configures("pylint", tables("pyproject.toml")) {
        return (path("pyproject.toml"), "pylint")
      }
    }
    return nil
  }
}

/// The section names of an INI or TOML file: each line that opens `[name]` or `[[name]]`.
private enum INITables {
  static func names(in text: String) -> Set<String> {
    var names: Set<String> = []
    for line in text.split(separator: "\n") {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard trimmed.hasPrefix("["), let close = trimmed.firstIndex(of: "]") else { continue }
      let name = trimmed[trimmed.index(after: trimmed.startIndex)..<close]
        .trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
      if !name.isEmpty { names.insert(name) }
    }
    return names
  }

  /// Whether `tables` holds `[tool.<tool>]` or 1 of its subtables.
  static func configures(_ tool: String, _ tables: Set<String>) -> Bool {
    tables.contains { $0.split(separator: ".").prefix(2).elementsEqual(["tool", tool[...]]) }
  }
}
