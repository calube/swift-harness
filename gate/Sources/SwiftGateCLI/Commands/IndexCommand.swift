import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain

struct IndexCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "index",
    abstract:
      "Read-modify-write index.json under a FileLock so concurrent local sessions serialise.",
    subcommands: [IndexSetCommand.self])
}

/// `PlanStatus` is a domain type with no ArgumentParser dependency; this is the one place that
/// makes it usable as a typed argument, via the free `init?(argument:)` `RawRepresentable` gives
/// any `ExpressibleByArgument` conformer whose `RawValue` is `String` (spec §5.8: `index set`
/// parses `status` through ArgumentParser, not a hand-rolled switch).
extension PlanStatus: ExpressibleByArgument {}

/// Why `index set` did not update the index. Every case maps to exit 2 (spec §6.1: "gate error").
enum IndexSetError: Error, Sendable, Equatable {
  /// The given string isn't one of ``PlanStatus``'s cases.
  case invalidStatus(String)
  case git(GitError)
  case layout(PlanStateLayoutError)
  case store(PlanIndexStoreError)

  var verdict: Verdict {
    switch self {
    case .invalidStatus: .blocked
    case .git(let error): error.verdict
    case .layout: .blocked
    case .store(let error): error.verdict
    }
  }
}

/// The testable core of `index set` (spec §5.8, §6.2): resolve the shared plan root from the
/// repository's git common dir, then upsert `slug` under the index lock. `IndexSetCommand.run()`
/// wires this to the real `cwd` and a real `Git`; tests inject a fake or a second worktree's git.
///
/// `status` stays a raw `String` here (rather than a typed `PlanStatus` parameter) so an unknown
/// value is rejected with this command's own exit(2) + allowed-values message instead of
/// ArgumentParser's generic usage-error exit code; parsing it happens first, before any git or
/// filesystem work.
enum IndexSetRun {
  static func run(
    slug: String, status: String, resume: String, git: any Git,
    store: (String) -> PlanIndexStore = { PlanIndexStore(path: $0) }
  ) async -> Result<PlanIndex, IndexSetError> {
    guard let planStatus = PlanStatus(argument: status) else {
      return .failure(.invalidStatus(status))
    }
    let commonDirectory: String
    do {
      commonDirectory = try await git.commonDirectory()
    } catch {
      return .failure(.git(error))
    }
    let layout: PlanStateLayout
    do {
      layout = try PlanStateLayout(commonDirectory: commonDirectory)
    } catch {
      return .failure(.layout(error))
    }
    do {
      let updated = try await store(layout.indexFile).update {
        $0.settingStatus(slug: slug, status: planStatus.rawValue, resume: resume)
      }
      return .success(updated)
    } catch {
      return .failure(.store(error))
    }
  }
}

enum IndexSetReport {
  struct Outcome: Sendable, Equatable, Encodable {
    let slug: String
    let status: String
    let planCount: Int
  }

  static let allowedStatusValues = PlanStatus.allCases.map(\.rawValue).joined(separator: ", ")

  static func render(_ index: PlanIndex, slug: String, status: String, format: OutputFormat)
    throws -> String
  {
    switch format {
    case .json:
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      return String(
        decoding: try encoder.encode(
          Outcome(slug: slug, status: status, planCount: index.plans.count)), as: UTF8.self)
    case .human:
      return "index set: \(slug) -> \(status) (\(index.plans.count) plan(s) in index)"
    }
  }

  static func renderError(_ error: IndexSetError, format: OutputFormat) -> String {
    if case .invalidStatus(let value) = error {
      switch format {
      case .json:
        let values = PlanStatus.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ",")
        return
          "{\"command\":\"index set\",\"error\":\"invalid status\",\"value\":\"\(value)\",\"allowed\":[\(values)]}"
      case .human:
        return "index set: '\(value)' is not a plan status; allowed values: \(allowedStatusValues)"
      }
    }
    switch format {
    case .json:
      let escaped = "\(error)".replacingOccurrences(of: "\"", with: "'")
      return "{\"command\":\"index set\",\"error\":\"\(escaped)\"}"
    case .human:
      return "index set: \(error)"
    }
  }
}

struct IndexSetCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "set",
    abstract: "Set a plan's status and resume note in index.json.")

  @Argument(help: "The plan's slug.")
  var slug: String

  @Argument(help: "The plan's status (one of: \(IndexSetReport.allowedStatusValues)).")
  var status: String

  @Argument(help: "The resume note.")
  var resume: String

  @OptionGroup var output: OutputOptions

  func run() async throws {
    let root = URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
    let git = LiveGit(runner: LiveProcessRunner(), repositoryRoot: root.path)
    switch await IndexSetRun.run(slug: slug, status: status, resume: resume, git: git) {
    case .success(let index):
      Console.write(
        try IndexSetReport.render(index, slug: slug, status: status, format: output.format))
    case .failure(let error):
      Console.write(IndexSetReport.renderError(error, format: output.format))
      throw ExitCode(error.verdict.exitCode)
    }
  }
}
