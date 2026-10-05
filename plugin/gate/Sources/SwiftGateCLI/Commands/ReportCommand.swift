import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain

/// `swiftgate report --html|--json <build run> [--out <path>]`: writes 1 build run's view as a
/// self-contained page, or prints it as JSON.
struct ReportCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "report",
    abstract: "Write a build run's report page, or print its run view as JSON.")

  @Flag(help: "Write a self-contained HTML page.")
  var html = false

  @Flag(help: "Print the run view as JSON.")
  var json = false

  @Argument(help: "The build run id; absent with --from.")
  var buildRun: String?

  @Option(help: "A report folder to write the page again from, with no plan state.")
  var from: String?

  @Option(
    help: "Where to write the page; reports/<build run>.html under the state root when absent.")
  var out: String?

  func validate() throws {
    guard html != json else { throw ValidationError("pass exactly 1 of --html and --json") }
    guard (buildRun == nil) != (from == nil) else {
      throw ValidationError("pass exactly 1 of a build run id and --from")
    }
  }

  func run() async throws {
    let root = URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
    let common: String
    do {
      common = try await LiveGit(runner: LiveProcessRunner(), repositoryRoot: root.path)
        .commonDirectory()
    } catch {
      FileHandle.standardError.write(Data("report: \(Verdict.blocked.rawValue) \(error)\n".utf8))
      throw ExitCode(Verdict.blocked.exitCode)
    }
    let pluginRoot = ProcessInfo.processInfo.environment["SWIFTGATE_HARNESS_ROOT"].map {
      URL(filePath: $0, directoryHint: .isDirectory)
    }
    let outcome = ReportRun.run(
      buildRun: buildRun, from: from, format: html ? .html : .json, out: out, root: root,
      commonDirectory: URL(filePath: common, directoryHint: .isDirectory), pluginRoot: pluginRoot,
      now: Date())
    switch outcome {
    case .wrote(let path):
      Console.write("report: wrote \(path)")
    case .printed(let text):
      Console.write(text)
    case .blocked(let message):
      FileHandle.standardError.write(Data("\(message)\n".utf8))
      throw ExitCode(Verdict.blocked.exitCode)
    }
  }
}

/// What `report` does, apart from resolving the repository: read, build, guard, then write or
/// print.
enum ReportRun {
  enum Format: Sendable, Equatable {
    case html
    case json
  }

  enum Outcome: Sendable, Equatable {
    /// The page or JSON went to `path`, as the message names it.
    case wrote(path: String)
    /// The JSON to print.
    case printed(String)
    /// Exit 2 with this message.
    case blocked(String)
  }

  /// - Parameters:
  ///   - root: the checkout `report` runs in; a relative `out` resolves against it.
  ///   - commonDirectory: the git common dir, absolute.
  ///   - pluginRoot: where `viewer/` lives; `nil` when unknown, which only `--html` needs.
  ///   - from: a report folder, whose `view.json` replaces reading the plan state.
  ///   - now: when a report of a run that hasn't ended says it was taken.
  static func run(
    buildRun: String?, from: String? = nil, format: Format, out: String?, root: URL,
    commonDirectory: URL, pluginRoot: URL?, now: Date = Date()
  ) -> Outcome {
    let blocked = { (message: String) in
      Outcome.blocked("report: \(Verdict.blocked.rawValue) \(message)")
    }
    guard let buildRun else { return blocked("--from isn't read yet") }
    guard RunID.isValid(buildRun) else {
      return blocked("`\(buildRun)` is not a build run id")
    }
    let state = StateRootResolver.resolve(worktree: root)
    let input: RunViewInput
    do {
      input = try RunViewReader(
        commonDirectory: commonDirectory, stateRoot: state,
        profile: BuildPresetCatalog.profile(root: root)
      ).read(buildRun: buildRun)
    } catch {
      return blocked("\(error)")
    }
    guard input.join != nil else { return blocked("no plan holds build run `\(buildRun)`") }
    var view = RunViewBuilder.build(input)
    if view.run.state != .done { view.run.snapshotAt = now }
    let json: Data
    do {
      if let rejection = try RunViewGuard.rejection(of: view) { return blocked("\(rejection)") }
      json = try RunViewJSON.encode(view)
    } catch {
      return blocked("the run view doesn't encode: \(error)")
    }

    let body: Data
    switch format {
    case .json:
      guard out != nil else { return .printed(String(decoding: json, as: UTF8.self)) }
      body = json
    case .html:
      guard let pluginRoot else {
        return blocked("run through the plugin's bin/swiftgate, which locates the viewer page")
      }
      do {
        body = Data(try ViewerTemplate.load(pluginRoot: pluginRoot).render(viewJSON: json).utf8)
      } catch {
        return blocked("\(error)")
      }
    }

    let target: URL
    let display: String
    if let out {
      target =
        out.hasPrefix("/") ? URL(filePath: out) : root.appending(path: out)
      display = out
    } else {
      let path = "\(RunLayout.reportsDirectory)/\(buildRun).html"
      target = state.url(path)
      display = state.displayPath(path)
    }
    do {
      try FileManager.default.createDirectory(
        at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
      try body.write(to: target, options: .atomic)
    } catch {
      return blocked("\(display) can't be written: \(error.localizedDescription)")
    }
    return .wrote(path: display)
  }
}
