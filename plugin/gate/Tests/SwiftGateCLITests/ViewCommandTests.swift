import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

/// Answers requests against a temp repository seeded from the captured build run, the way
/// `view` answers them once its server hands them over.
@Suite("swiftgate view")
struct ViewCommandTests {
  typealias Repository = ReportCommandTests.Repository

  static func serve(_ repository: Repository) throws -> ViewRun {
    let page = try ViewerTemplate.load(pluginRoot: Fixture.checkoutRoot).render(viewJSON: Data())
    return ViewRun(
      buildRun: ReportCommandTests.buildRun,
      reader: RunViewReader(
        commonDirectory: repository.common,
        stateRoot: StateRootResolver.resolve(worktree: repository.root)),
      page: Data(page.utf8))
  }

  static func get(_ path: String, _ query: [String: String] = [:]) -> LocalHTTPRequest {
    LocalHTTPRequest(method: "GET", path: path, query: query)
  }

  static func object(_ response: LocalHTTPResponse) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
  }

  @Test(
    "GET / serves the page with its scripts inlined and no data embedded, so it fetches — catches a live page that renders a stale embedded run"
  )
  func servesThePage() throws {
    let repository = try Repository()
    defer { repository.remove() }
    let response = try Self.serve(repository).respond(to: Self.get("/"))
    #expect(response.status == 200)
    #expect(response.contentType.hasPrefix("text/html"))
    let html = String(decoding: response.body, as: UTF8.self)
    #expect(html.contains("window.runViewer"))
    #expect(!html.contains("<script src"))
    #expect(try ReportCommandTests.dataBlock(html).isEmpty)
  }

  @Test(
    "GET /view.json answers the whole run view with a cursor and the run's stall minutes — catches a first fetch the page can't poll after"
  )
  func servesTheWholeView() throws {
    let repository = try Repository()
    defer { repository.remove() }
    let response = try Self.serve(repository).respond(to: Self.get("/view.json"))
    #expect(response.status == 200)
    #expect(response.contentType.hasPrefix("application/json"))
    let view = try Self.object(response)
    #expect((view["cursor"] as? String)?.isEmpty == false)
    let run = try #require(view["run"] as? [String: Any])
    #expect(run["id"] as? String == ReportCommandTests.buildRun)
    #expect(run.keys.contains("stallMin"))
    #expect((view["tasks"] as? [Any])?.count == 3)
  }

  @Test(
    "after 1 appended event, /changes answers only the rows it changed and a new cursor — catches a poll that resends the whole view"
  )
  func changesAfterOneEvent() throws {
    let repository = try Repository()
    defer { repository.remove() }
    let view = try Self.serve(repository)
    let first = try Self.object(view.respond(to: Self.get("/view.json")))
    let cursor = try #require(first["cursor"] as? String)

    let idle = try Self.object(view.respond(to: Self.get("/changes", ["after": cursor])))
    #expect(idle.keys.sorted() == ["cursor"])
    #expect(idle["cursor"] as? String == cursor)

    try HarnessEventFiles(root: repository.root).append(
      HarnessEvent(
        eventID: "live-halt-1", time: Date(timeIntervalSince1970: 1_791_000_000),
        source: HarnessEventSource(route: nil),
        payload: .buildHalt(
          BuildHaltEvent(
            buildRun: ReportCommandTests.buildRun, task: "counter-ui-reset-button",
            reason: .stall))))
    let response = view.respond(to: Self.get("/changes", ["after": cursor]))

    #expect(response.status == 200)
    let changes = try Self.object(response)
    let next = try #require(changes["cursor"] as? String)
    #expect(next != cursor)
    #expect(changes["tasks"] == nil)
    #expect(changes["gates"] == nil)
    #expect(changes["spec"] == nil)
    let halts = try #require(changes["halts"] as? [[String: Any]])
    #expect(halts.map { $0["reason"] as? String } == ["stall"])
    #expect((changes["run"] as? [String: Any])?["state"] as? String == "halted")
    let spans = (changes["spans"] as? [[String: Any]]) ?? []
    #expect(spans.count < ((first["spans"] as? [Any])?.count ?? 0))
  }

  @Test(
    "a malformed or stale cursor gets the whole view and a fresh cursor, never a 500 — catches a page stuck after the server restarts"
  )
  func malformedCursorGetsTheWholeView() throws {
    let repository = try Repository()
    defer { repository.remove() }
    let view = try Self.serve(repository)
    for query in [["after": "not-a-cursor"], ["after": ""], [:]] {
      let response = view.respond(to: Self.get("/changes", query))
      #expect(response.status == 200, "\(query)")
      let answer = try Self.object(response)
      #expect((answer["cursor"] as? String)?.isEmpty == false)
      #expect((answer["tasks"] as? [Any])?.count == 3, "\(query)")
    }
  }

  @Test(
    "any other path answers 404 and serves no file — catches a static file server over the repository"
  )
  func otherPathsAre404() throws {
    let repository = try Repository()
    defer { repository.remove() }
    let view = try Self.serve(repository)
    let ledger = try String(
      contentsOf: repository.planDirectory.appending(path: "ledger.json"), encoding: .utf8)
    for path in [
      "/ledger.json", "/../ledger.json", "/run-viewer.js", "/view.json/x", "/.harness/events",
      "/index.html",
    ] {
      let response = view.respond(to: Self.get(path))
      #expect(response.status == 404, "\(path)")
      #expect(!String(decoding: response.body, as: UTF8.self).contains("counter"), "\(path)")
      #expect(response.body.count < ledger.utf8.count)
    }
    #expect(
      view.respond(to: LocalHTTPRequest(method: "POST", path: "/view.json")).status == 405)
  }

  @Test(
    "a run view string the payload guard rejects fails the answer naming the field — catches the guard skipped on a live answer"
  )
  func guardFailsTheAnswer() throws {
    let repository = try Repository()
    defer { repository.remove() }
    let ledgerURL = repository.planDirectory.appending(path: "ledger.json")
    let ledger = try String(contentsOf: ledgerURL, encoding: .utf8)
    let poisoned = ledger.replacingOccurrences(
      of: "\"Packages/CounterFeature/Sources/CounterUI/\"", with: "\"~/secrets/CounterUI/\"")
    #expect(poisoned != ledger, "the captured ledger no longer names Sources/CounterUI/")
    try Data(poisoned.utf8).write(to: ledgerURL)

    let view = try Self.serve(repository)
    for request in [Self.get("/view.json"), Self.get("/changes", ["after": "x"])] {
      let response = view.respond(to: request)
      let text = String(decoding: response.body, as: UTF8.self)
      #expect(response.status == 500, "\(request.path)")
      #expect(text.contains("writes"), "\(text)")
      #expect(!text.contains("secrets"), "\(text)")
    }
  }
}
