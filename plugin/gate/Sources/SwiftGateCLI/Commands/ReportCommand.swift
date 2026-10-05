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

  @Option(help: "A report folder to write the page again from its view.json, with no plan state.")
  var from: String?

  @Option(
    help: ArgumentHelp(
      "The report folder for --html, reports/<build run>/ under the state root when absent; the "
        + "file for --json."))
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
    let resolve = { (path: String) in
      path.hasPrefix("/") ? URL(filePath: path) : root.appending(path: path)
    }
    if let from {
      return rerender(
        RunReportFolder(directory: resolve(from)), display: from, format: format, out: out,
        pluginRoot: pluginRoot, blocked: blocked)
    }
    guard let buildRun else { return blocked("name a build run id or --from") }
    guard RunID.isValid(buildRun) else {
      return blocked("`\(buildRun)` is not a build run id")
    }
    let state = StateRootResolver.resolve(worktree: root)
    let reader = RunViewReader(
      commonDirectory: commonDirectory, stateRoot: state,
      profile: BuildPresetCatalog.profile(root: root))
    let input: RunViewInput
    do {
      input = try reader.read(buildRun: buildRun)
    } catch {
      return blocked("\(error)")
    }
    guard input.join != nil else { return blocked("no plan holds build run `\(buildRun)`") }
    var view = RunViewBuilder.build(input)
    if view.run.state != .done { view.run.snapshotAt = now }
    let runs = reader.runRoots.map { $0.url(RunLayout.runsDirectory, directoryHint: .isDirectory) }
    let carriage = RunReportFolder.carriage(
      view.validation?.linkedFiles ?? [], first: view.validation?.flowFiles ?? [], under: runs)
    if format == .html {
      view.evidenceBase = RunReportFolder.evidenceBase
      view.evidenceFiles = carriage.carried.sorted()
      for left in carriage.left {
        guard let reason = left.reason else { continue }
        view.damage.append(
          RunView.Damage(source: RunReportFolder.evidenceBase + left.relative, reason: reason))
      }
    }
    let json: Data
    do {
      if let rejection = try RunViewGuard.rejection(of: view) { return blocked("\(rejection)") }
      json = try RunViewJSON.encode(view)
    } catch {
      return blocked("the run view doesn't encode: \(error)")
    }

    switch format {
    case .json:
      guard let out else { return .printed(String(decoding: json, as: UTF8.self)) }
      do {
        let target = resolve(out)
        try FileManager.default.createDirectory(
          at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try json.write(to: target, options: .atomic)
      } catch {
        return blocked("\(out) can't be written: \(error.localizedDescription)")
      }
      return .wrote(path: out)
    case .html:
      guard let pluginRoot else {
        return blocked("run through the plugin's bin/swiftgate, which locates the viewer page")
      }
      let folder: RunReportFolder
      let display: String
      if let out {
        folder = RunReportFolder(directory: resolve(out))
        display =
          (out.hasSuffix("/") ? String(out.dropLast()) : out) + "/" + RunReportFolder.pageName
      } else {
        let path = "\(RunLayout.reportsDirectory)/\(buildRun)"
        folder = RunReportFolder(directory: state.url(path, directoryHint: .isDirectory))
        display = state.displayPath("\(path)/\(RunReportFolder.pageName)")
      }
      do {
        let page = Data(try ViewerTemplate.load(pluginRoot: pluginRoot).render(viewJSON: json).utf8)
        try folder.write(page: page, view: json, carrying: carriage, from: runs)
      } catch {
        return blocked("\(display): \(error)")
      }
      return .wrote(path: display)
    }
  }

  /// The page again from a report folder's own `view.json`, with no plan state or run store.
  private static func rerender(
    _ folder: RunReportFolder, display: String, format: Format, out: String?, pluginRoot: URL?,
    blocked: (String) -> Outcome
  ) -> Outcome {
    guard out == nil else { return blocked("--from writes the page back into its own folder") }
    let json: Data
    do {
      json = try folder.storedView()
    } catch {
      return blocked("\(display): \(error)")
    }
    guard format == .html else { return .printed(String(decoding: json, as: UTF8.self)) }
    guard let pluginRoot else {
      return blocked("run through the plugin's bin/swiftgate, which locates the viewer page")
    }
    let path =
      (display.hasSuffix("/") ? String(display.dropLast()) : display) + "/"
      + RunReportFolder.pageName
    do {
      try folder.writePage(
        Data(try ViewerTemplate.load(pluginRoot: pluginRoot).render(viewJSON: json).utf8))
    } catch {
      return blocked("\(path): \(error)")
    }
    return .wrote(path: path)
  }
}
