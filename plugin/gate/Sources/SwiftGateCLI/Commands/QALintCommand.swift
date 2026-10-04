import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateRules

/// `qa lint`'s behaviour, apart from argument parsing so tests and `qa run` drive it directly.
enum QALintRun {
  static let command = "qa lint"
  static let harnessRootVariable = "SWIFTGATE_HARNESS_ROOT"

  /// What the rules check against: the pinned step schemas and the declared identifiers.
  struct Inputs: Sendable {
    var schemas: ToolSchemas
    var ids: FlowIDs
  }

  /// Loads the step schemas from `pluginRoot` and the identifiers `root`'s config names.
  /// - Returns: the inputs, or why the lint can't run.
  static func inputs(root: URL, pluginRoot: URL?) -> Result<Inputs, QALintBlocked> {
    guard let pluginRoot else {
      return .failure(
        QALintBlocked(
          message:
            "\(harnessRootVariable) is unset, so the pinned step schemas can't be found; run "
            + "through the plugin's bin/swiftgate"))
    }
    let schemas: ToolSchemas
    do {
      schemas = try ToolSchemaStore.load(pluginRoot: pluginRoot)
    } catch {
      return .failure(QALintBlocked(message: "loading the step schemas: \(error)"))
    }
    let loaded: LoadedConfig?
    do {
      loaded = try ConfigLoader().loadProfile(repositoryRoot: root)
    } catch {
      return .failure(QALintBlocked(message: "the config doesn't load: \(error)"))
    }
    let config: Config
    switch loaded {
    case .owned(let owned)?: config = owned
    case .brownfield?:
      return .success(
        Inputs(
          schemas: schemas,
          ids: .unconfigured(reason: "a brownfield clone's config.toml declares no accessibility ids")))
    case nil:
      return .success(
        Inputs(
          schemas: schemas, ids: .unconfigured(reason: "this repository has no \(Config.fileName)")))
    }
    guard let path = config.qa.accessibilityIDs else {
      return .success(
        Inputs(
          schemas: schemas,
          ids: .unconfigured(reason: "`[qa] accessibility_ids` is not set in \(Config.fileName)")))
    }
    let source: String
    do {
      source = try String(contentsOf: root.appending(path: path), encoding: .utf8)
    } catch {
      return .failure(
        QALintBlocked(
          message:
            "`[qa] accessibility_ids` names \(path), which doesn't read: "
            + error.localizedDescription))
    }
    do {
      let ids = try AccessibilityIDReader.read(source: source, path: path)
      return .success(Inputs(schemas: schemas, ids: .declared(source: path, ids: ids)))
    } catch {
      return .failure(QALintBlocked(message: "reading the accessibility ids: \(error)"))
    }
  }

  /// Lints each flow file, a path relative to `root` or absolute.
  static func run(files: [String], root: URL, pluginRoot: URL?) -> FlowLintReport {
    guard !files.isEmpty else {
      return .blocked("no flow file named; pass 1 or more batch steps files", files: [])
    }
    let inputs: Inputs
    switch Self.inputs(root: root, pluginRoot: pluginRoot) {
    case .success(let loaded): inputs = loaded
    case .failure(let blocked): return .blocked(blocked.message, files: files)
    }
    var read: [(path: String, data: Data)] = []
    for file in files {
      let url = file.hasPrefix("/") ? URL(filePath: file) : root.appending(path: file)
      do {
        read.append((file, try Data(contentsOf: url)))
      } catch {
        return .blocked("\(file) doesn't read: \(error.localizedDescription)", files: files)
      }
    }
    return FlowRules.lint(files: read, schemas: inputs.schemas, ids: inputs.ids)
  }

  static func render(_ report: FlowLintReport, json: Bool) -> String {
    guard !json else {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      return String(decoding: (try? encoder.encode(report)) ?? Data(), as: UTF8.self)
    }
    return (["\(command): \(report.verdict.rawValue) \(report.message)"]
      + report.findings.map { "  \($0.ruleID) \($0.file): \($0.message)" })
      .joined(separator: "\n")
  }
}

/// Why `qa lint` couldn't run its rules.
struct QALintBlocked: Error, Sendable, Equatable {
  var message: String
}

/// `swiftgate qa lint <flow file>... [--json]`.
struct QALintCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "lint",
    abstract: "Check agent-device batch steps files offline, before any device boots.")

  @Argument(help: "The batch steps files to check, such as qa/<name>.flow.json.")
  var files: [String]

  @Flag(help: "Print JSON.")
  var json = false

  func run() throws {
    let root = URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
    let pluginRoot = ProcessInfo.processInfo.environment[QALintRun.harnessRootVariable].map {
      URL(filePath: $0, directoryHint: .isDirectory)
    }
    let report = QALintRun.run(files: files, root: root, pluginRoot: pluginRoot)
    Console.write(QALintRun.render(report, json: json))
    if report.verdict != .green { throw ExitCode(report.verdict.exitCode) }
  }
}
