import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import Synchronization

/// `swiftgate view [--build-run <id>] [--port <n>]`: serves the run viewer on 127.0.0.1 and its
/// changes as the run goes.
struct ViewCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "view",
    abstract: "Serve a live run viewer on 127.0.0.1.")

  @Option(help: "The build run id; the newest run when absent.")
  var buildRun: String?

  @Option(help: "The port to listen on; any free port when absent.")
  var port: Int?

  func validate() throws {
    if let port, !(1...65_535).contains(port) {
      throw ValidationError("--port takes 1 to 65535, not \(port)")
    }
  }

  func run() async throws {
    func blocked(_ message: String) -> ExitCode {
      FileHandle.standardError.write(Data("view: \(Verdict.blocked.rawValue) \(message)\n".utf8))
      return ExitCode(Verdict.blocked.exitCode)
    }
    let root = URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
    let common: String
    do {
      common = try await LiveGit(runner: LiveProcessRunner(), repositoryRoot: root.path)
        .commonDirectory()
    } catch {
      throw blocked("\(error)")
    }
    guard let pluginRoot = ProcessInfo.processInfo.environment["SWIFTGATE_HARNESS_ROOT"] else {
      throw blocked("run through the plugin's bin/swiftgate, which locates the viewer page")
    }
    let reader = RunViewReader(
      commonDirectory: URL(filePath: common, directoryHint: .isDirectory),
      stateRoot: StateRootResolver.resolve(worktree: root))
    guard let id = buildRun ?? reader.newestBuildRun() else {
      throw blocked("no plan holds a build run to view")
    }
    guard RunID.isValid(id) else { throw blocked("`\(id)` is not a build run id") }
    let page: String
    do {
      page = try ViewerTemplate.load(
        pluginRoot: URL(filePath: pluginRoot, directoryHint: .isDirectory)
      )
      .render(viewJSON: Data())
    } catch {
      throw blocked("\(error)")
    }
    let view = ViewRun(buildRun: id, reader: reader, page: Data(page.utf8))
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
}

/// What `view` answers: the page with no data embedded, the whole run view, and what changed
/// after a cursor. Every answer that carries view data passes ``RunViewGuard`` first.
final class ViewRun: Sendable {
  let buildRun: String
  let reader: RunViewReader
  /// The page, its stylesheet and scripts inlined, its data block empty so it fetches.
  let page: Data
  private let book = Mutex(RunViewCursorBook())

  init(buildRun: String, reader: RunViewReader, page: Data) {
    self.buildRun = buildRun
    self.reader = reader
    self.page = page
  }

  static let viewPath = "/view.json"
  static let changesPath = "/changes"

  /// Why a view couldn't be answered; the message names a rejected field, never its value.
  struct Failure: Error, CustomStringConvertible {
    let description: String
  }

  func respond(to request: LocalHTTPRequest) -> LocalHTTPResponse {
    let after: String?
    switch request.path {
    case "/", Self.viewPath, Self.changesPath:
      guard request.method == "GET" else { return .text(405, "view: only GET is served") }
      if request.path == "/" {
        return LocalHTTPResponse(status: 200, contentType: "text/html; charset=utf-8", body: page)
      }
      after = request.path == Self.changesPath ? request.query["after"] : nil
    default:
      return .text(404, "view: no such page")
    }
    let answer = book.withLock { book in
      let snapshot = reader.snapshot(buildRun: buildRun)
      return Result { try book.answer(after: after, snapshot: snapshot, build: build) }
    }
    do {
      let body: Data
      switch try answer.get() {
      case .full(let view): body = try RunViewJSON.encode(view)
      case .changes(let changes): body = try RunViewJSON.encode(changes)
      }
      return LocalHTTPResponse(
        status: 200, contentType: "application/json; charset=utf-8", body: body)
    } catch {
      return .text(500, "view: \(Verdict.blocked.rawValue) \(error)")
    }
  }

  /// Reads and folds the run, then guards every string in it.
  private func build() throws(Failure) -> RunView {
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
