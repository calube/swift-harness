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
    "a RED gate landing after the first fetch reaches /changes with its tier, rule, file:line, failing test and report, and no machine path — catches a live page with no failure context"
  )
  func changesCarryTheFailure() throws {
    let redGate = "20261004T050310Z-ed998508"
    let repository = try Repository()
    defer { repository.remove() }
    let events = repository.root.appending(path: ".harness/events", directoryHint: .isDirectory)
    var held: [URL: [Substring]] = [:]
    for stream in ["gate", "test"] {
      let url = events.appending(path: "\(stream).jsonl")
      let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
      let red = lines.filter { $0.contains("\"runID\":\"\(redGate)\"") }
      #expect(!red.isEmpty, "the captured \(stream) stream holds no line of \(redGate)")
      held[url] = red
      try Data(lines.filter { !red.contains($0) }.map { $0 + "\n" }.joined().utf8).write(to: url)
    }
    let view = try Self.serve(repository)
    let first = try Self.object(view.respond(to: Self.get("/view.json")))
    let cursor = try #require(first["cursor"] as? String)
    let before = (first["gates"] as? [[String: Any]]) ?? []
    #expect(!before.contains { $0["runId"] as? String == redGate })

    for (url, lines) in held {
      let handle = try FileHandle(forWritingTo: url)
      try handle.seekToEnd()
      try handle.write(contentsOf: Data(lines.map { $0 + "\n" }.joined().utf8))
      try handle.close()
    }
    let response = view.respond(to: Self.get("/changes", ["after": cursor]))
    #expect(response.status == 200)
    let text = String(decoding: response.body, as: UTF8.self)
    for leak in ["/var/folders", "/Users/", "file://", repository.root.path] {
      #expect(!text.contains(leak), "\(leak)")
    }
    let changes = try Self.object(response)
    let gates = try #require(changes["gates"] as? [[String: Any]])
    let gate = try #require(gates.first { $0["runId"] as? String == redGate })
    let failure = try #require(gate["failure"] as? [String: Any])
    #expect(failure["tiers"] as? [String] == ["T2"])
    #expect(failure["stage"] as? String == "merge")
    #expect(failure["report"] as? String == ".harness/runs/\(redGate)/report.json")
    let finding = try #require((failure["findings"] as? [[String: Any]])?.first)
    #expect(finding["rule"] as? String == "t2.test-failed")
    #expect(
      finding["file"] as? String
        == "Packages/CounterFeature/Tests/CounterUISnapshotTests/CounterViewSnapshotTests.swift")
    #expect(finding["line"] as? Int == 21)
    let test = try #require((failure["failedTests"] as? [[String: Any]])?.first)
    #expect(
      test["test"] as? String == "CounterUISnapshotTests.CounterViewSnapshotTests/counterWithFact")
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

  /// A checkout holding the captured final `qa run`'s stream and run folder, with a video and a
  /// contact sheet written where its flow row 1 names them, and a file no flow links beside them.
  static func flowRepository() throws -> (repository: Repository, qaRun: String, flow: String) {
    let repository = try Repository()
    let qaRun = "20261004T220955Z-1614d1ea"
    let captured = Fixture.gateDirectory.appending(
      path: "Tests/Fixtures/RunView/qa-flows", directoryHint: .isDirectory)
    let harness = repository.root.appending(path: ".harness", directoryHint: .isDirectory)
    try FileManager.default.copyItem(
      at: captured.appending(path: "events/qa.jsonl"),
      to: harness.appending(path: "events/qa.jsonl"))
    try FileManager.default.copyItem(
      at: captured.appending(path: "runs/\(qaRun)"), to: harness.appending(path: "runs/\(qaRun)"))
    let flow = "qa/01-slice-1-reset-after-increments-shows-zero.flow"
    let folder = harness.appending(path: "runs/\(qaRun)/\(flow)", directoryHint: .isDirectory)
    try Data("mp4 bytes".utf8).write(to: folder.appending(path: "video.mp4"))
    try Data("png bytes".utf8).write(to: folder.appending(path: "sheet.png"))
    try Data("not linked".utf8).write(to: folder.appending(path: "notes.txt"))
    return (repository, qaRun, flow)
  }

  @Test(
    "GET /runs/<run>/<path> serves a video and a contact sheet a flow of the view links, with their types — catches a live page whose step links 404"
  )
  func servesLinkedFlowFiles() throws {
    let (repository, qaRun, flow) = try Self.flowRepository()
    defer { repository.remove() }
    let view = try Self.serve(repository)
    let video = view.respond(to: Self.get("/runs/\(qaRun)/\(flow)/video.mp4"))
    #expect(video.status == 200)
    #expect(video.contentType == "video/mp4")
    #expect(video.body == Data("mp4 bytes".utf8))
    let sheet = view.respond(to: Self.get("/runs/\(qaRun)/\(flow)/sheet%2Epng"))
    #expect(sheet.status == 200)
    #expect(sheet.contentType == "image/png")
    #expect(sheet.body == Data("png bytes".utf8))
  }

  @Test(
    "GET /runs/ for a file no flow of the view links, or a path that climbs out, answers 404 and reads nothing — catches the live server handing out any file under the checkout"
  )
  func refusesUnlinkedRunFiles() throws {
    let (repository, qaRun, flow) = try Self.flowRepository()
    defer { repository.remove() }
    let view = try Self.serve(repository)
    for path in [
      "/runs/\(qaRun)/\(flow)/notes.txt", "/runs/\(qaRun)/qa/report.json",
      "/runs/\(qaRun)/\(flow)/../../../../.swiftgate.toml",
      "/runs/\(qaRun)/\(flow)/%2E%2E/video.mp4",
    ] {
      let response = view.respond(to: Self.get(path))
      #expect(response.status == 404, "\(path)")
      #expect(!String(decoding: response.body, as: UTF8.self).contains("bytes"), "\(path)")
    }
  }

  @Test(
    "the live server on a run with no ledger log yet answers it as not written yet, and once the log is written its next /changes carries the task spans and an empty unwritten list — catches a live page stuck on a file the run wrote since"
  )
  func liveServerFollowsTheLedgerLog() async throws {
    let repository = try Repository()
    defer { repository.remove() }
    let log = repository.planDirectory.appending(
      path: "build/\(ReportCommandTests.buildRun)/events.jsonl")
    let captured = try Data(contentsOf: log)
    try FileManager.default.removeItem(at: log)
    let server = LocalHTTPServer()
    defer { server.stop() }
    let port = try await server.start(port: 0, handler: try Self.serve(repository).respond)
    func fetch(_ target: String) async throws -> [String: Any] {
      let url = try #require(URL(string: "http://127.0.0.1:\(port)\(target)"))
      let (body, response) = try await URLSession.shared.data(from: url)
      #expect((response as? HTTPURLResponse)?.statusCode == 200, "\(target)")
      return try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    let first = try await fetch("/view.json")
    let unwritten = (first["unwritten"] as? [[String: Any]]) ?? []
    #expect(unwritten.contains { ($0["source"] as? String)?.hasSuffix("events.jsonl") == true })
    #expect(
      !((first["spans"] as? [[String: Any]]) ?? []).contains { $0["phase"] as? String == "task" })
    let cursor = try #require(first["cursor"] as? String)

    try captured.write(to: log)
    let changes = try await fetch("/changes?after=\(cursor)")

    #expect((changes["unwritten"] as? [Any])?.isEmpty == true, "\(changes.keys.sorted())")
    let spans = (changes["spans"] as? [[String: Any]]) ?? []
    #expect(spans.contains { $0["phase"] as? String == "task" })
    #expect((changes["run"] as? [String: Any])?["state"] as? String == "done")
  }
}
