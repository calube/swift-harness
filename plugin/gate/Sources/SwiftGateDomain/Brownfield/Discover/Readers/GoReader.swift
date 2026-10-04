import Foundation

/// Reads `go.mod`: an area per module, `go test` with `-run`, golangci-lint when configured. Every
/// command runs from the module's directory, the area root.
///
/// golangci-lint finds a dotted `.golangci.*` itself, searching up from where it runs; any
/// other name is passed with `-c`. With no config, lint stays missing rather than guessed.
public struct GoReader: EcosystemReader {
  public init() {}

  static let lintConfigs = [
    ".golangci.yml", ".golangci.yaml", ".golangci.toml", ".golangci.json", "golangci.yml",
    "golangci.yaml", "golangci.toml", "golangci.json",
  ]

  public func areas(in tree: TrackedTreeSnapshot) -> [ProposedArea] {
    let listed = Set(tree.paths)
    return tree.paths.compactMap { path in
      guard CICommandMining.basename(path) == "go.mod", !BuildFilePaths.isSkipped(path) else {
        return nil
      }
      let root = CICommandMining.dirname(path)
      let found = { (command: String) in Sourced(value: command, source: path, confidence: .found) }
      var commands: [AreaStep: Sourced<String>] = [
        .test: found("go test ./..."),
        .testFiles: found("go test ./... -run {tests}"),
        .build: found("go build ./..."),
      ]
      var missing: [AreaStep: String] = [:]
      let config = BuildFilePaths.ancestors(of: root).lazy.flatMap { directory in
        Self.lintConfigs.map { BuildFilePaths.join(directory, $0) }
      }.first(where: listed.contains)
      if let config {
        let name = CICommandMining.basename(config)
        let flag =
          name.hasPrefix(".")
          ? "" : "-c \(CICommandMining.quote(BuildFilePaths.relativeFrom(root, to: config))) "
        commands[.lint] = Sourced(
          value: "golangci-lint run \(flag)./...", source: config, confidence: .found)
      } else {
        missing[.lint] = "no golangci-lint config"
      }
      return ProposedArea(
        name: Self.moduleName(BuildFilePaths.text(tree, path)) ?? BuildFilePaths.defaultName(root),
        root: root, language: .go, kind: .go, source: path, commands: commands, missing: missing,
        testGlobs: [BuildFilePaths.join(root, "**/*_test.go")], xcode: nil,
        generatedProjectTracked: nil)
    }
  }

  /// The last element of the `module` path, skipping a `/vN` major-version suffix.
  static func moduleName(_ text: String?) -> String? {
    guard let text else { return nil }
    for line in text.split(separator: "\n") {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard trimmed.hasPrefix("module ") else { continue }
      let module = trimmed.dropFirst("module ".count).prefix { $0 != " " }
        .split(separator: "/").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")) }
      guard var last = module.last else { return nil }
      if module.count > 1, last.hasPrefix("v"), last.dropFirst().allSatisfy(\.isNumber) {
        last = module[module.count - 2]
      }
      return last.isEmpty ? nil : last
    }
    return nil
  }
}
