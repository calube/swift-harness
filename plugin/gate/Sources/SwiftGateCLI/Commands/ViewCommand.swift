import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import Synchronization

/// `swiftgate view [--build-run <id>] [--port <n>] [--ensure]`: serves the run viewer on
/// 127.0.0.1 as the run goes, in the foreground or from 1 detached server per repository.
struct ViewCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "view",
    abstract: "Serve a live run viewer on 127.0.0.1.")

  @Option(help: "The build run id; the newest run when absent.")
  var buildRun: String?

  @Option(help: "The port to listen on; any free port when absent.")
  var port: Int?

  @Flag(
    help:
      "Reuse the repository's detached viewer server, or start one, and print its URL. SWIFTGATE_VIEW=off starts none."
  )
  var ensure = false

  /// The server `--ensure` starts: it follows the newest build run, saves its record, and exits
  /// once its lifetime ends.
  @Flag(help: .hidden)
  var detached = false

  func validate() throws {
    if let port, !(1...65_535).contains(port) {
      throw ValidationError("--port takes 1 to 65535, not \(port)")
    }
    if ensure, buildRun != nil || port != nil || detached {
      throw ValidationError(
        "--ensure follows the newest build run on the repository's saved port; drop --build-run, --port and --detached"
      )
    }
  }

  func run() async throws {
    func blocked(_ message: String) -> ExitCode {
      FileHandle.standardError.write(Data("view: \(Verdict.blocked.rawValue) \(message)\n".utf8))
      return ExitCode(Verdict.blocked.exitCode)
    }
    let environment = ProcessInfo.processInfo.environment
    if ensure, ViewServerSwitch.isOff(environment[ViewServerSwitch.environmentKey]) {
      FileHandle.standardError.write(
        Data("view: SWIFTGATE_VIEW=off, so no live viewer runs and no URL is printed\n".utf8))
      return
    }
    let root = URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
    let common: String
    do {
      common = try await LiveGit(runner: LiveProcessRunner(), repositoryRoot: root.path)
        .commonDirectory()
    } catch {
      throw blocked("\(error)")
    }
    let commonURL = URL(filePath: common, directoryHint: .isDirectory)
    guard let pluginRoot = environment["SWIFTGATE_HARNESS_ROOT"] else {
      throw blocked("run through the plugin's bin/swiftgate, which locates the viewer page")
    }
    if ensure {
      try await ensureServer(common: commonURL, root: root, blocked: blocked)
      return
    }
    let reader = RunViewReader(
      commonDirectory: commonURL, stateRoot: StateRootResolver.resolve(worktree: root),
      profile: BuildPresetCatalog.profile(root: root))
    let page: Data
    do {
      page = Data(
        try ViewerTemplate.load(
          pluginRoot: URL(filePath: pluginRoot, directoryHint: .isDirectory)
        )
        .render(viewJSON: Data()).utf8)
    } catch {
      throw blocked("\(error)")
    }
    if detached {
      try await serveDetached(
        ViewRun(newestOf: reader, page: page),
        registry: ViewServerRegistry(commonDirectory: commonURL),
        blocked: blocked)
      return
    }
    guard let id = buildRun ?? reader.newestBuildRun() else {
      throw blocked("no plan holds a build run to view")
    }
    guard RunID.isValid(id) else { throw blocked("`\(id)` is not a build run id") }
    let view = ViewRun(buildRun: id, reader: reader, page: page)
    // The first answer fails here, not in the browser, when the run can't be shown.
    let first = view.respond(to: LocalHTTPRequest(method: "GET", path: ViewRun.viewPath))
    guard first.status == 200 else {
      throw blocked(String(decoding: first.body, as: UTF8.self).trimmingCharacters(in: .newlines))
    }
    let server = LocalHTTPServer()
    let bound: UInt16
    do {
      bound = try await server.start(port: UInt16(port ?? 0), handler: view.respond)
    } catch {
      throw blocked("\(error)")
    }
    // Unbuffered: a caller reading a pipe needs the URL now, and the command never exits.
    FileHandle.standardOutput.write(
      Data("view: build run \(id) at http://127.0.0.1:\(bound)/ until interrupted\n".utf8))
    while true { try await Task.sleep(for: .seconds(3_600)) }
  }

  /// Prints the URL of the repository's viewer server, started detached when none answers. The
  /// server runs from the main checkout, so every worktree's call finds the same 1.
  private func ensureServer(
    common: URL, root: URL, blocked: (String) -> ExitCode
  ) async throws {
    let directory = (try? TaskWorktree.mainCheckout(commonDirectory: common.path)) ?? root.path
    guard let executable = Bundle.main.executablePath else {
      throw blocked("this swiftgate can't name its own executable to start a server from")
    }
    let ensurer = ViewServerEnsurer(
      registry: ViewServerRegistry(commonDirectory: common), probe: LiveViewServerProbe(),
      launcher: DetachedLauncher())
    let outcome: ViewServerEnsurer.Outcome
    do {
      outcome = try await ensurer.ensure(
        switchValue: ProcessInfo.processInfo.environment[ViewServerSwitch.environmentKey],
        executable: executable, serve: ["view", "--detached"], directory: directory)
    } catch {
      throw blocked("\(error)")
    }
    switch outcome {
    case .off: return
    case .reused(let record), .started(let record):
      FileHandle.standardOutput.write(Data("\(record.url)\n".utf8))
    }
  }

  /// Serves `view` on the saved port when it's free, else any, saves the record, and returns once
  /// the lifetime watch says the server is done.
  private func serveDetached(
    _ view: ViewRun, registry: ViewServerRegistry, blocked: (String) -> ExitCode
  ) async throws {
    let server = LocalHTTPServer()
    let bound: UInt16
    do {
      if let port, let held = try? await server.start(port: UInt16(port), handler: view.respond) {
        bound = held
      } else {
        bound = try await server.start(port: 0, handler: view.respond)
      }
    } catch {
      throw blocked("\(error)")
    }
    let record = ViewServerRecord(pid: getpid(), port: Int(bound), startedAt: Date())
    do {
      try registry.write(record)
    } catch {
      server.stop()
      throw blocked("\(ViewServerRecord.fileName) can't be written: \(error.localizedDescription)")
    }
    FileHandle.standardOutput.write(Data("view: serving \(record.url)\n".utf8))
    let reason = try await ViewServerWatch().run(
      now: { Date() }, wait: { try await Task.sleep(for: $0) }, observe: { view.observe() })
    server.stop()
    FileHandle.standardOutput.write(Data("view: stopped, \(reason.rawValue)\n".utf8))
  }
}

/// What `view` answers: the page with no data embedded, the whole run view, nothing when a poll
/// names the view it already holds, the final report once it exists, the serving pid, and each
/// video and contact sheet the view's flows link. Every answer that carries view data passes
/// ``RunViewGuard`` first.
final class ViewRun: Sendable {
  /// The run served: 1 named run, or the newest build run of any plan at each request.
  enum Target: Sendable, Equatable {
    case fixed(String)
    case newest
  }

  let target: Target
  let reader: RunViewReader
  /// The page, its stylesheet and scripts inlined, its data block empty so it fetches.
  let page: Data
  private let watched = Mutex(Watched())

  /// What the lifetime watch compares between ticks.
  private struct Watched {
    var requested = false
    var token: String?
  }

  init(buildRun: String, reader: RunViewReader, page: Data) {
    self.target = .fixed(buildRun)
    self.reader = reader
    self.page = page
  }

  /// A server that follows the newest build run of any plan, as `view --ensure` starts.
  init(newestOf reader: RunViewReader, page: Data) {
    self.target = .newest
    self.reader = reader
    self.page = page
  }

  static let viewPath = "/view.json"
  static let finalPath = "/final"
  /// Answers the serving process's pid, so `view --ensure` knows a saved server is still itself.
  static let serverPath = "/server"
  static let runsPrefix = "/runs/"

  /// Why a view couldn't be answered; the message names a rejected field, never its value.
  struct Failure: Error, CustomStringConvertible {
    let description: String
  }

  /// The run this answer is about; `nil` while no plan has a build run.
  private var buildRun: String? {
    switch target {
    case .fixed(let id): id
    case .newest: reader.newestBuildRunName()
    }
  }

  func respond(to request: LocalHTTPRequest) -> LocalHTTPResponse {
    watched.withLock { $0.requested = true }
    let path = request.path
    let known =
      [
        "/", Self.viewPath, Self.finalPath, Self.serverPath,
      ].contains(path) || path.hasPrefix(Self.runsPrefix)
    guard known else { return .text(404, "view: no such page") }
    guard request.method == "GET" else { return .text(405, "view: only GET is served") }
    switch path {
    case "/":
      return LocalHTTPResponse(status: 200, contentType: "text/html; charset=utf-8", body: page)
    case Self.serverPath:
      return LocalHTTPResponse(
        status: 200, contentType: "application/json; charset=utf-8",
        body: Data("{\"pid\":\(getpid())}".utf8))
    case Self.viewPath:
      return view(after: request.query["after"])
    case Self.finalPath:
      return final()
    default:
      return runFile(path.dropFirst(Self.runsPrefix.count))
    }
  }

  /// The run's token now: its files' stamps, and the run's id, so a server that moves on to a
  /// newer run never answers a poll of the old one with nothing.
  private func token(of buildRun: String) -> String {
    var snapshot = reader.snapshot(buildRun: buildRun)
    snapshot.files["build run \(buildRun)"] = RunViewSnapshot.Stamp(bytes: 0)
    return snapshot.cursor
  }

  /// 204 when `after` is the run's token now, so an unchanged run is neither read nor sent;
  /// otherwise the whole view under the new token.
  private func view(after: String?) -> LocalHTTPResponse {
    guard let buildRun else {
      return .text(503, "view: no build run yet; the page shows one once a build starts")
    }
    // Taken before the read, so a change during it moves the next poll's token too.
    let now = token(of: buildRun)
    if let after, after == now {
      return LocalHTTPResponse(status: 204, contentType: "text/plain; charset=utf-8", body: Data())
    }
    do {
      var view = try build(buildRun)
      view.cursor = now
      if reader.finalReport(buildRun: buildRun) != nil { view.finalReport = Self.finalPath }
      return LocalHTTPResponse(
        status: 200, contentType: "application/json; charset=utf-8",
        body: try RunViewJSON.encode(view))
    } catch {
      return .text(500, "view: \(Verdict.blocked.rawValue) \(error)")
    }
  }

  /// The run's final report page, once `report --html` wrote it for the done run.
  private func final() -> LocalHTTPResponse {
    guard let buildRun else { return .text(404, "view: no final report yet") }
    guard let folder = reader.finalReport(buildRun: buildRun),
      let body = try? Data(contentsOf: folder.directory.appending(path: RunReportFolder.pageName))
    else { return .text(404, "view: no final report yet") }
    return LocalHTTPResponse(status: 200, contentType: "text/html; charset=utf-8", body: body)
  }

  /// What the lifetime watch sees on 1 tick: a request or a run change since the last tick, and
  /// whether the run's final report exists.
  func observe() -> ViewServerWatch.Observation {
    let run = buildRun
    let now = run.map(token(of:))
    let finalExists = run.map { reader.finalReport(buildRun: $0) != nil } ?? false
    return watched.withLock { watched in
      defer {
        watched.requested = false
        watched.token = now
      }
      let moved = watched.token != nil && watched.token != now
      return ViewServerWatch.Observation(
        active: watched.requested || moved, finalExists: finalExists)
    }
  }

  /// A video or contact sheet the view's flows link, from the reader's run directories; any
  /// other path is 404, so the page can't reach a file no flow names.
  private func runFile(_ encoded: Substring) -> LocalHTTPResponse {
    let missing = LocalHTTPResponse.text(404, "view: no such file")
    guard let relative = String(encoded).removingPercentEncoding, let buildRun,
      let view = try? build(buildRun), view.validation?.linkedFiles.contains(relative) == true,
      let file = RunReportFolder.source(
        relative, in: reader.runRoots.map { $0.url(RunLayout.runsDirectory) }),
      let body = try? Data(contentsOf: file)
    else { return missing }
    let type =
      switch (relative as NSString).pathExtension {
      case "mp4": "video/mp4"
      case "png": "image/png"
      default: "application/octet-stream"
      }
    return LocalHTTPResponse(status: 200, contentType: type, body: body)
  }

  /// Reads and folds the run, then guards every string in it.
  private func build(_ buildRun: String) throws(Failure) -> RunView {
    let input: RunViewInput
    do {
      input = try reader.read(buildRun: buildRun)
    } catch {
      throw Failure(description: "\(error)")
    }
    guard input.join != nil else {
      throw Failure(description: "no plan holds build run `\(buildRun)`")
    }
    let view = RunViewBuilder.build(input)
    let rejection: RunViewGuard.Rejection?
    do {
      rejection = try RunViewGuard.rejection(of: view)
    } catch {
      throw Failure(description: "the run view doesn't encode: \(error)")
    }
    if let rejection { throw Failure(description: "\(rejection)") }
    return view
  }
}
