import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain

/// The text `module-graph` prints, which the design and plan skills pass to
/// `context-pack --module-graph`: SessionStart's module map, then one `<Target> -> <Dependency>`
/// line per target dependency. A research-lane pack keeps the lines naming a touched module, so
/// every edge names both ends on one line.
enum ModuleGraphDump {
  /// The map lines are SessionStart's own entries in SessionStart's format, uncut: the session's
  /// copy is clipped to the hook output cap, and a pack's must not be. Edges run over every
  /// module, test targets included, sorted by module then dependency; an external product (one no
  /// described package vends) is an edge named as the product.
  static func lines(_ graph: ModuleGraph) -> [String] {
    let entries = SessionStartHook.moduleEntries(of: graph)
    var lines: [String] = []
    if !entries.isEmpty {
      lines.append("Modules by package (role, kind):")
      let packages = Dictionary(grouping: entries, by: \.package)
      for package in packages.keys.sorted() {
        let modules = (packages[package] ?? []).map { "\($0.name) (\($0.role), \($0.kind))" }
        lines.append("- \(package): \(modules.joined(separator: ", "))")
      }
    }
    for module in graph.modules {
      for dependency in (module.dependencies + module.externalProducts).sorted() {
        lines.append("\(module.name) -> \(dependency)")
      }
    }
    return lines
  }
}

/// The body of `module-graph`. It loads the graph through the same `ConfigLoader` and
/// `ModuleGraphLoader` that `arch`, `design-scope` and SessionStart use.
enum ModuleGraphRun {
  enum Outcome: Sendable, Equatable {
    case dumped(String)
    case failed(message: String)
  }

  static func run(root: URL, swiftPM: any SwiftPM) async -> Outcome {
    let config: Config
    switch StaticCheckInputs.loadConfig(root: root) {
    case .success(let loaded?):
      config = loaded
    case .success(nil):
      return .failed(message: "no \(ConfigLoader.fileName): there is no module graph to dump")
    case .failure(let failure):
      switch failure.outcome {
      case .blocked(let reason), .invalid(let reason, _): return .failed(message: reason)
      case .checked: return .failed(message: "\(ConfigLoader.fileName) could not be loaded")
      }
    }
    do throws(ModuleGraphLoadError) {
      let graph = try await ModuleGraphLoader(swiftPM: swiftPM, root: root).load(config: config)
      return .dumped(ModuleGraphDump.lines(graph).map { $0 + "\n" }.joined())
    } catch {
      return .failed(message: "can't load the module graph: \(error.description)")
    }
  }
}

struct ModuleGraphCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "module-graph",
    abstract: "Print the repository's module graph for a context pack's --module-graph file.",
    discussion:
      "Describes every package the .swiftgate.toml packages globs name and prints, one per line: "
      + "`Modules by package (role, kind):`, then `- <package>: <Module> (<role>, <kind>), …` "
      + "per package (test targets left out), then `<Target> -> <Dependency>` for every target "
      + "dependency, test targets and external products included, sorted by target then "
      + "dependency. Exit 0 with the dump on stdout, or in --output. Exit 2, with no dump and no "
      + "--output file written, when .swiftgate.toml is missing or invalid, a packages glob "
      + "matches no package, a local dependency is outside the globs, or swift package describe "
      + "fails.")

  @Option(
    name: .customLong("repo"),
    help: "The repository to describe. Defaults to the working directory.")
  var repository: String?

  @Option(
    name: .customLong("output"),
    help: "Write the dump to this file, creating its directory, instead of stdout.")
  var output: String?

  func run() async throws {
    let workingDirectory = URL(
      filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
    let root =
      repository.map {
        URL(filePath: $0, directoryHint: .isDirectory, relativeTo: workingDirectory)
      }
      ?? workingDirectory
    switch await ModuleGraphRun.run(root: root, swiftPM: ScopeResolution.liveSwiftPM(root: root)) {
    case .dumped(let text):
      guard let output else {
        FileHandle.standardOutput.write(Data(text.utf8))
        return
      }
      let file = URL(filePath: output, relativeTo: workingDirectory)
      do {
        try FileManager.default.createDirectory(
          at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file, options: .atomic)
      } catch {
        throw fail("can't write `\(output)`: \(error.localizedDescription)")
      }
    case .failed(let message):
      throw fail(message)
    }
  }

  private func fail(_ message: String) -> ExitCode {
    FileHandle.standardError.write(Data("swiftgate module-graph: \(message)\n".utf8))
    return ExitCode(Verdict.blocked.exitCode)
  }
}
