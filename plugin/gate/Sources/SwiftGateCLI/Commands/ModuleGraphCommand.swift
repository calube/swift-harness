import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain

/// The body of `module-graph`, apart from argument parsing and stdout. It loads the graph through
/// the same `ConfigLoader` and `ModuleGraphLoader` that `arch`, `design-scope` and SessionStart
/// use, so the dump can't disagree with the map a session was shown.
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
      return .dumped(ModuleGraphDump.lines(graph).joined(separator: "\n"))
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
      + "dependency. Exit 0 with the dump on stdout. Exit 2, with nothing on stdout, when "
      + ".swiftgate.toml is missing or invalid, a packages glob matches no package, a local "
      + "dependency is outside the globs, or swift package describe fails.")

  func run() async throws {
    let root = URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
    switch await ModuleGraphRun.run(root: root, swiftPM: ScopeResolution.liveSwiftPM(root: root)) {
    case .dumped(let text):
      Console.write(text)
    case .failed(let message):
      FileHandle.standardError.write(Data("swiftgate module-graph: \(message)\n".utf8))
      throw ExitCode(Verdict.blocked.exitCode)
    }
  }
}
