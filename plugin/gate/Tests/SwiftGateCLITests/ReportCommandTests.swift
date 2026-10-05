import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

/// Seeds a temp repository from the captured build run, so nothing here reads or writes this
/// checkout's own stores or plan state.
@Suite("swiftgate report")
struct ReportCommandTests {
  static let captured = Fixture.gateDirectory.appending(
    path: "Tests/Fixtures/RunView/build-run-1", directoryHint: .isDirectory)
  static let buildRun = "20261004T045528Z-58d28c78"
  static let plan = "2026-10-03-counter-reset-and-floor"

  struct Repository {
    let root: URL
    var common: URL { root.appending(path: ".git", directoryHint: .isDirectory) }
    var planDirectory: URL {
      common.appending(
        path: "swift-harness/plans/\(ReportCommandTests.plan)", directoryHint: .isDirectory)
    }

    init() throws {
      root = TestTemporaryDirectory.root
        .appending(path: "swiftgate-report-\(UUID().uuidString)", directoryHint: .isDirectory)
        .resolvingSymlinksInPath()
      let files = FileManager.default
      let run = planDirectory.appending(
        path: "build/\(ReportCommandTests.buildRun)", directoryHint: .isDirectory)
      try files.createDirectory(at: run, withIntermediateDirectories: true)
      try files.createDirectory(
        at: root.appending(path: ".harness"), withIntermediateDirectories: true)
      try Data().write(to: root.appending(path: ".swiftgate.toml"))
      let copies: [(String, URL)] = [
        ("ledger.json", planDirectory.appending(path: "ledger.json")),
        ("plan.json", planDirectory.appending(path: "plan.json")),
        ("plan.md", planDirectory.appending(path: "spec-page.md")),
        ("run.json", run.appending(path: "run.json")),
        ("ledger-events.jsonl", run.appending(path: "events.jsonl")),
        ("returns", run.appending(path: "returns")),
        ("events", root.appending(path: ".harness/events")),
        ("runs", root.appending(path: ".harness/runs")),
      ]
      for (name, target) in copies {
        try files.copyItem(at: ReportCommandTests.captured.appending(path: name), to: target)
      }
    }

    func run(
      _ format: ReportRun.Format, out: String? = nil, pluginRoot: URL? = Fixture.checkoutRoot
    )
      -> ReportRun.Outcome
    {
      ReportRun.run(
        buildRun: ReportCommandTests.buildRun, format: format, out: out, root: root,
        commonDirectory: common, pluginRoot: pluginRoot)
    }

    func remove() { TestTemporaryDirectory.remove(root) }
  }

  /// The text of the `run-view` data block, up to the first `</script` after it.
  static func dataBlock(_ html: String) throws -> String {
    let open = "<script type=\"application/json\" id=\"run-view\">"
    let start = try #require(html.range(of: open)).upperBound
    let end = try #require(html.range(of: "</script", range: start..<html.endIndex)).lowerBound
    return String(html[start..<end])
  }

  @Test(
    "report --html writes 1 self-contained page in the run's folder under the state root with the run's view embedded — catches a page that needs the network or a sibling file"
  )
  func writesSelfContainedPage() throws {
    let repository = try Repository()
    defer { repository.remove() }
    let path = ".harness/reports/\(Self.buildRun)/index.html"
    #expect(repository.run(.html) == .wrote(path: path))
    let html = try String(contentsOf: repository.root.appending(path: path), encoding: .utf8)
    #expect(!html.contains("<script src"))
    #expect(!html.contains("<link"))
    #expect(!html.contains("http"))
    #expect(html.contains("window.RunViewModel"))
    #expect(html.contains("window.runViewer"))
    #expect(html.contains("--bar-gate"))
    let data = try JSONSerialization.jsonObject(with: Data(try Self.dataBlock(html).utf8))
    let run = (data as? [String: Any])?["run"] as? [String: Any]
    #expect(run?["id"] as? String == Self.buildRun)
    #expect(((data as? [String: Any])?["gates"] as? [Any])?.isEmpty == false)
  }

  @Test(
    "report --html --out writes the report folder there instead — catches an --out the command ignores"
  )
  func writesToOut() throws {
    let repository = try Repository()
    defer { repository.remove() }
    #expect(repository.run(.html, out: "shared/run") == .wrote(path: "shared/run/index.html"))
    #expect(
      FileManager.default.fileExists(
        atPath: repository.root.appending(path: "shared/run/index.html").path)
    )
    #expect(
      !FileManager.default.fileExists(
        atPath: repository.root.appending(path: ".harness/reports").path))
  }

  @Test(
    "report --json prints the run view the page embeds — catches a JSON dump that drifts from the page's data"
  )
  func printsJSON() throws {
    let repository = try Repository()
    defer { repository.remove() }
    guard case .printed(let text) = repository.run(.json) else {
      Issue.record("report --json printed nothing")
      return
    }
    let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
    #expect((object?["run"] as? [String: Any])?["id"] as? String == Self.buildRun)
    #expect((object?["tasks"] as? [Any])?.count == 3)
  }

  @Test(
    "a run view string holding a home path fails the report naming the field and writes nothing — catches the guard skipped"
  )
  func guardFailsTheReport() throws {
    let repository = try Repository()
    defer { repository.remove() }
    let ledgerURL = repository.planDirectory.appending(path: "ledger.json")
    let ledger = try String(contentsOf: ledgerURL, encoding: .utf8)
    let poisoned = ledger.replacingOccurrences(
      of: "\"Packages/CounterFeature/Sources/CounterUI/\"", with: "\"~/secrets/CounterUI/\"")
    #expect(poisoned != ledger, "the captured ledger no longer names Sources/CounterUI/")
    try Data(poisoned.utf8).write(to: ledgerURL)

    for format in [ReportRun.Format.html, .json] {
      guard case .blocked(let message) = repository.run(format) else {
        Issue.record("report \(format) passed a home path")
        continue
      }
      #expect(message.contains(".writes["), "\(message)")
      #expect(message.contains("home-path"), "\(message)")
    }
    #expect(
      !FileManager.default.fileExists(
        atPath: repository.root.appending(path: ".harness/reports").path))
  }

  @Test(
    "a build run no plan holds blocks the report — catches an empty page written for a typo"
  )
  func unknownRunBlocks() throws {
    let repository = try Repository()
    defer { repository.remove() }
    let outcome = ReportRun.run(
      buildRun: "20261004T000000Z-00000000", format: .html, out: nil, root: repository.root,
      commonDirectory: repository.common, pluginRoot: Fixture.checkoutRoot)
    guard case .blocked(let message) = outcome else {
      Issue.record("report of an unknown run gave \(outcome)")
      return
    }
    #expect(message.contains("20261004T000000Z-00000000"))
  }

  @Test(
    "a module file dropped into the viewer directory is inlined after the core script, in name order — catches a hard-coded file list"
  )
  func inlinesModules() throws {
    let plugin = FileManager.default.temporaryDirectory.appending(
      path: "swiftgate-viewer-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: plugin) }
    let viewer = plugin.appending(path: ViewerTemplate.directory, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: plugin, withIntermediateDirectories: true)
    try FileManager.default.copyItem(
      at: Fixture.checkoutRoot.appending(path: ViewerTemplate.directory), to: viewer)
    let modules = [
      ("run-viewer-zeta.js", "window.zetaModule = 1;"),
      ("run-viewer-alpha.js", "window.alphaModule = 1;"),
      ("run-viewer-alpha.css", ".alpha-module { color: red; }"),
    ]
    for (name, text) in modules {
      try Data(text.utf8).write(to: viewer.appending(path: name))
    }

    let template = try ViewerTemplate.load(pluginRoot: plugin)
    let html = try template.render(viewJSON: Data("{}".utf8))
    let core = try #require(html.range(of: "window.runViewer = {"))
    let alpha = try #require(html.range(of: "window.alphaModule = 1;"))
    let zeta = try #require(html.range(of: "window.zetaModule = 1;"))
    #expect(core.upperBound < alpha.lowerBound)
    #expect(alpha.upperBound < zeta.lowerBound)
    let style = try #require(html.range(of: ".alpha-module { color: red; }"))
    let styleEnd = try #require(html.range(of: "</style>", range: style.upperBound..<html.endIndex))
    #expect(styleEnd.lowerBound < core.lowerBound)
    #expect(!html.contains("<script src"))
  }

  @Test(
    "a view string holding </script> stays inside the data block — catches an embedding that lets data close the script"
  )
  func escapesTheData() throws {
    let template = try ViewerTemplate.load(pluginRoot: Fixture.checkoutRoot)
    let hostile = "{\"title\":\"</script><script>alert(1)</script> & <!--\"}"
    let html = try template.render(viewJSON: Data(hostile.utf8))
    let block = try Self.dataBlock(html)
    let object = try JSONSerialization.jsonObject(with: Data(block.utf8)) as? [String: String]
    #expect(object?["title"] == "</script><script>alert(1)</script> & <!--")
  }

  @Test(
    "a viewer directory missing a core file fails naming it — catches a page written without its script"
  )
  func missingFileFails() throws {
    let plugin = FileManager.default.temporaryDirectory.appending(
      path: "swiftgate-viewer-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: plugin) }
    let viewer = plugin.appending(path: ViewerTemplate.directory, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: plugin, withIntermediateDirectories: true)
    try FileManager.default.copyItem(
      at: Fixture.checkoutRoot.appending(path: ViewerTemplate.directory), to: viewer)
    try FileManager.default.removeItem(at: viewer.appending(path: "run-view-model.js"))
    do {
      _ = try ViewerTemplate.load(pluginRoot: plugin)
      Issue.record("a viewer with no run-view-model.js loaded")
    } catch {
      #expect(error.description.contains("run-view-model.js"), "\(error)")
    }
  }
}
