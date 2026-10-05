import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

/// A report of the captured build run at the moments a run passes through: before its first
/// ledger event, mid-run, at its end, and after its plan state is gone.
@Suite("swiftgate report stays whole live and after")
struct ReportWholeTests {
  typealias Repository = ReportCommandTests.Repository
  static let buildRun = ReportCommandTests.buildRun
  static let now = Date(timeIntervalSince1970: 1_791_000_000)
  /// How the view spells a time.
  static let timeFormat = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

  static func run(
    _ repository: Repository, _ format: ReportRun.Format = .json, buildRun: String? = buildRun,
    from: String? = nil, out: String? = nil
  ) -> ReportRun.Outcome {
    ReportRun.run(
      buildRun: buildRun, from: from, format: format, out: out, root: repository.root,
      commonDirectory: repository.common, pluginRoot: Fixture.checkoutRoot, now: now)
  }

  static func view(_ repository: Repository) throws -> [String: Any] {
    guard case .printed(let text) = run(repository) else {
      throw ReportWholeFailure("report --json printed nothing")
    }
    return try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
  }

  static func object(_ text: String) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
  }

  static func ledgerLog(_ repository: Repository) -> URL {
    repository.planDirectory.appending(path: "build/\(buildRun)/events.jsonl")
  }

  /// The captured ledger log without its last line, the final gate: the log as it stood before
  /// the run ended.
  static func dropFinalGate(_ repository: Repository) throws {
    let url = ledgerLog(repository)
    let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
    #expect(lines.last?.contains("\"gate\":\"final\"") == true, "the capture no longer ends final")
    try Data((lines.dropLast().joined(separator: "\n") + "\n").utf8).write(to: url)
  }

  static func append(_ event: BuildEvent, to repository: Repository) throws {
    let handle = try FileHandle(forWritingTo: ledgerLog(repository))
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: try BuildEventJSON.encodeLine(event))
  }

  static func sources(_ rows: Any?) -> [String] {
    ((rows as? [[String: Any]]) ?? []).compactMap { $0["source"] as? String }
  }

  @Test(
    "a report of a run whose ledger log stops before its end reads running and carries when it was taken — catches a mid-run snapshot mistaken for the final report"
  )
  func midRunReportIsASnapshot() throws {
    let repository = try Repository()
    defer { repository.remove() }
    try Self.dropFinalGate(repository)

    let run = try #require(try Self.view(repository)["run"] as? [String: Any])
    #expect(run["state"] as? String == "running")
    #expect(run["snapshotAt"] as? String == Self.now.formatted(Self.timeFormat))

    guard case .wrote(let path) = Self.run(repository, .html) else {
      Issue.record("report --html wrote nothing")
      return
    }
    let html = try String(contentsOf: repository.root.appending(path: path), encoding: .utf8)
    let embedded = try Self.object(try ReportCommandTests.dataBlock(html))
    #expect((embedded["run"] as? [String: Any])?["snapshotAt"] as? String != nil)
  }

  @Test(
    "a ledger event after the final gate reads running until build finish's event is the newest, which reads done at its time with no snapshot — catches a fix loop after a red final shown as done"
  )
  func finishEventEndsTheRun() throws {
    let repository = try Repository()
    defer { repository.remove() }
    let done = try #require(try Self.view(repository)["run"] as? [String: Any])
    #expect(done["state"] as? String == "done")
    #expect(done["snapshotAt"] is NSNull)

    let fixAt = Date(timeIntervalSince1970: 1_790_000_000 + 30_000_000)
    try Self.append(
      .transition(
        .init(
          task: "counter-core-reset-and-decrement-floor", from: .done, to: .inProgress, at: fixAt)),
      to: repository)
    let resumed = try #require(try Self.view(repository)["run"] as? [String: Any])
    #expect(resumed["state"] as? String == "running")
    #expect(resumed["snapshotAt"] as? String != nil)

    let finishedAt = fixAt.addingTimeInterval(600)
    try Self.append(.finish(.init(at: finishedAt)), to: repository)
    let finished = try #require(try Self.view(repository)["run"] as? [String: Any])
    #expect(finished["state"] as? String == "done")
    #expect(finished["snapshotAt"] is NSNull)
    #expect(finished["endedAt"] as? String == finishedAt.formatted(Self.timeFormat))
  }

  @Test(
    "before a run's first ledger event its missing ledger log and spec page read not written yet, never damage — catches a live report whose footer calls a run in progress damaged"
  )
  func missingFilesOfALiveRunAreUnwritten() throws {
    let repository = try Repository()
    defer { repository.remove() }
    try FileManager.default.removeItem(at: Self.ledgerLog(repository))
    try FileManager.default.removeItem(at: repository.planDirectory.appending(path: "spec-page.md"))

    let view = try Self.view(repository)
    let damage = Self.sources(view["damage"])
    #expect(!damage.contains { $0.hasSuffix("events.jsonl") }, "\(damage)")
    #expect(!damage.contains { $0.hasSuffix("spec-page.md") }, "\(damage)")
    let unwritten = try #require(view["unwritten"] as? [[String: Any]])
    let sources = Self.sources(unwritten)
    #expect(sources.contains { $0.hasSuffix("build/\(Self.buildRun)/events.jsonl") }, "\(sources)")
    #expect(sources.contains { $0.hasSuffix("spec-page.md") }, "\(sources)")
    #expect(unwritten.allSatisfy { $0["reason"] as? String == "not written yet" })
  }

  @Test(
    "a spec page still missing once the run has ended is a damage row and nothing reads not written yet — catches a lost file excused forever"
  )
  func missingSpecPageAfterTheEndIsDamage() throws {
    let repository = try Repository()
    defer { repository.remove() }
    try FileManager.default.removeItem(at: repository.planDirectory.appending(path: "spec-page.md"))

    let view = try Self.view(repository)
    #expect(Self.sources(view["damage"]).contains { $0.hasSuffix("spec-page.md") })
    #expect((view["unwritten"] as? [Any])?.isEmpty == true)
  }

  @Test(
    "a plan with no plan.json has no spec rows and no damage row for it — catches a plan without a spec page reported as damaged"
  )
  func noPlanFileIsNotDamage() throws {
    let repository = try Repository()
    defer { repository.remove() }
    try FileManager.default.removeItem(at: repository.planDirectory.appending(path: "plan.json"))

    let view = try Self.view(repository)
    #expect(!Self.sources(view["damage"]).contains { $0.hasSuffix("plan.json") })
    #expect((view["spec"] as? [Any])?.isEmpty == true)
  }

  @Test(
    "a run whose preset names no stall_min reads the stall watch's 15 minutes — catches a live page with its stall badge off"
  )
  func stallMinDefaults() throws {
    let repository = try Repository()
    defer { repository.remove() }
    let run = try #require(try Self.view(repository)["run"] as? [String: Any])
    #expect(run["stallMin"] as? Int == BuildPreset.defaultStallMin)
    #expect(BuildPreset.defaultStallMin == 15)
  }

  /// Every regular file under `folder`, relative to it.
  static func files(under folder: URL) -> Set<String> {
    let base = folder.resolvingSymlinksInPath().path + "/"
    var found = Set<String>()
    let walk = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)
    while let url = walk?.nextObject() as? URL {
      guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
        continue
      }
      found.insert(String(url.resolvingSymlinksInPath().path.dropFirst(base.count)))
    }
    return found
  }

  @Test(
    "an ended run's report is a folder of its page, its guarded view and copies of the flow and evidence files it links, and nothing else, that still opens and renders again after the plan state and run stores are removed — catches a report that dies with plan cleanup"
  )
  func finalReportSurvivesCleanup() throws {
    let (repository, qaRun, _) = try ViewCommandTests.flowRepository()
    defer { repository.remove() }
    let printed = try Self.view(repository)
    let linked = try #require(
      ((printed["validation"] as? [String: Any])?["rows"] as? [[String: Any]])?
        .compactMap { $0["flow"] as? [String: Any] })
    var expected: Set<String> = ["index.html", "view.json"]
    for flow in linked {
      for key in ["video", "sheet"] {
        guard let path = flow[key] as? String else { continue }
        let file = repository.root.appending(path: ".harness/runs/\(qaRun)/\(path)")
        if !FileManager.default.fileExists(atPath: file.path) {
          try Data("\(key) bytes".utf8).write(to: file)
        }
        expected.insert("runs/\(qaRun)/\(path)")
      }
    }
    #expect(expected.count > 2, "the captured flows link no file")
    let rows = try #require(
      (printed["validation"] as? [String: Any])?["rows"] as? [[String: Any]])
    for row in rows {
      let run = try #require(row["qaRun"] as? String)
      for path in (row["evidence"] as? [String]) ?? [] {
        let file = repository.root.appending(path: ".harness/runs/\(run)/\(path)")
        if FileManager.default.fileExists(atPath: file.path) {
          expected.insert("runs/\(run)/\(path)")
        }
      }
    }

    let folderPath = ".harness/reports/\(Self.buildRun)"
    #expect(Self.run(repository, .html) == .wrote(path: "\(folderPath)/index.html"))
    let folder = repository.root.appending(path: folderPath, directoryHint: .isDirectory)
    #expect(Self.files(under: folder) == expected)

    let html = try String(contentsOf: folder.appending(path: "index.html"), encoding: .utf8)
    let block = try ReportCommandTests.dataBlock(html)
    let stored = try String(contentsOf: folder.appending(path: "view.json"), encoding: .utf8)
    // The page escapes `<` and friends inside its data block, so the 2 compare as JSON.
    #expect(NSDictionary(dictionary: try Self.object(block)).isEqual(to: try Self.object(stored)))
    var embedded = try Self.object(block)
    #expect(embedded["evidenceBase"] as? String == "runs/")
    embedded["evidenceBase"] = NSNull()
    #expect(
      Set(try #require(embedded["evidenceFiles"] as? [String]).map { "runs/\($0)" })
        == expected.subtracting(["index.html", "view.json"]))
    embedded["evidenceFiles"] = NSNull()
    // Only the report names the linked files it couldn't copy.
    embedded["damage"] = try #require(embedded["damage"] as? [[String: Any]]).filter {
      ($0["source"] as? String)?.hasPrefix(RunReportFolder.evidenceBase) != true
    }
    #expect(NSDictionary(dictionary: embedded).isEqual(to: printed))
    for name in expected where name.hasSuffix(".html") || name.hasSuffix(".json") {
      let text = try String(contentsOf: folder.appending(path: name), encoding: .utf8)
      #expect(!text.contains("/Users/"), "\(name)")
      #expect(!text.contains(repository.root.path), "\(name)")
    }

    for gone in [".git/swift-harness/plans", ".harness/events", ".harness/runs"] {
      try FileManager.default.removeItem(at: repository.root.appending(path: gone))
    }
    try FileManager.default.removeItem(at: folder.appending(path: "index.html"))
    #expect(
      Self.run(repository, .html, buildRun: nil, from: folderPath)
        == .wrote(path: "\(folderPath)/index.html"))
    let again = try String(contentsOf: folder.appending(path: "index.html"), encoding: .utf8)
    #expect(
      NSDictionary(dictionary: try Self.object(try ReportCommandTests.dataBlock(again)))
        .isEqual(to: try Self.object(stored)))
    #expect(Self.files(under: folder) == expected)
  }

  @Test(
    "a flow file the view links that no run directory holds is a damage row of the report, not a silent broken link — catches a final report whose step link 404s unseen"
  )
  func missingLinkedFileIsDamage() throws {
    let (repository, qaRun, flow) = try ViewCommandTests.flowRepository()
    defer { repository.remove() }
    try FileManager.default.removeItem(
      at: repository.root.appending(path: ".harness/runs/\(qaRun)/\(flow)/video.mp4"))

    guard case .wrote(let path) = Self.run(repository, .html) else {
      Issue.record("report --html wrote nothing")
      return
    }
    let html = try String(contentsOf: repository.root.appending(path: path), encoding: .utf8)
    let embedded = try Self.object(try ReportCommandTests.dataBlock(html))
    let damage = Self.sources(embedded["damage"])
    #expect(damage.contains("runs/\(qaRun)/\(flow)/video.mp4"), "\(damage)")
  }
}

struct ReportWholeFailure: Error, CustomStringConvertible {
  let description: String
  init(_ description: String) { self.description = description }
}
