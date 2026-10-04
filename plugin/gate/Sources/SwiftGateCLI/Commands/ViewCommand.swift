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

  func run() async throws {
    try StubCommand.notImplemented("view", json: false)
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

  func respond(to request: LocalHTTPRequest) -> LocalHTTPResponse {
    .text(404, "view: no such page")
  }
}
