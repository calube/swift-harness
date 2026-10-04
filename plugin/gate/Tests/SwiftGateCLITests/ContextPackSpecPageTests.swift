import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

/// `context-pack --role decomposer|worker --spec-page <path>`: a plan whose source is a spec page
/// gets packs cut from the page, byte for byte. Every file lives under a fresh temp directory.
@Suite("swiftgate context-pack with a spec page")
struct ContextPackSpecPageTests {
  private let pageText: String

  init() throws {
    pageText = try String(
      contentsOf: Fixture.directory.appending(path: "spec-page/task-status.page.txt"),
      encoding: .utf8)
  }

  private static let pagePath = "plans/task-status/spec-page.md"

  private struct Repository {
    let root: URL

    init() throws {
      root = TestTemporaryDirectory.root
        .appending(
          path: "swiftgate-context-pack-spec-page-\(UUID().uuidString)",
          directoryHint: .isDirectory
        )
        .resolvingSymlinksInPath()
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func remove() { TestTemporaryDirectory.remove(root) }

    @discardableResult
    func write(_ contents: String, at relativePath: String) throws -> String {
      let url = root.appending(path: relativePath)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(contents.utf8).write(to: url)
      return relativePath
    }

    func text(_ relativePath: String) throws -> String {
      try String(contentsOf: root.appending(path: relativePath), encoding: .utf8)
    }

    /// A `.swiftgate.toml` and 1 package whose graph has none of the page's modules, so a write
    /// set entry under `Sources/AppCore/` resolves only through the page's Modules table.
    func seedModuleGraph() throws -> FakeSwiftPM {
      let package = root.appending(path: "Sample", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
      try Data("// swift-tools-version: 6.2\n".utf8).write(
        to: package.appending(path: "Package.swift"))
      try write(
        """
        schema = 1
        xcode = "26.2"
        app_scheme = "Sample"
        packages = ["Sample"]

        [simulator]
        device = "iPhone 17"
        os = "26.2"
        """, at: ConfigLoader.fileName)
      return FakeSwiftPM(serving: [
        PackageManifest(
          name: "Sample", path: "Sample",
          targets: [
            PackageTarget(
              name: "LogClient", type: .library, path: "Sample/Sources/LogClient")
          ])
      ])
    }
  }

  private static let standards = """
    ## 2. Architecture

    ARCHITECTURE-SECTION

    ## 8. Engine modules

    ENGINE-SECTION
    """

  private static func writeLedger(
    covers: [String], writeSet: [String], in repository: Repository
  ) throws -> String {
    let task = LedgerTask(
      id: "task-history", deps: [], writeSet: writeSet, gate: .push, tests: [], covers: covers,
      estLines: 120, status: .pending, worktree: "../app-task-history")
    let data = try LedgerJSON.encode(
      Ledger(schemaVersion: 1, resume: "resume", maxParallel: 3, tasks: [task], waves: [[task.id]]))
    return try repository.write(String(decoding: data, as: UTF8.self), at: "ledger.json")
  }

  private func workerOptions(
    covers: [String], writeSet: [String] = ["Sample/Sources/AppCore/"], in repository: Repository
  ) throws -> ContextPackGatherInputs {
    var options = ContextPackGatherInputs()
    options.specPage = try repository.write(pageText, at: Self.pagePath)
    options.ledger = try Self.writeLedger(covers: covers, writeSet: writeSet, in: repository)
    options.taskID = "task-history"
    options.standards = try repository.write(Self.standards, at: "docs/standards.md")
    return options
  }

  /// The page's lines from the one starting with `prefix` up to the next slice or section.
  private func sliceLines(startingWith prefix: String) throws -> [String] {
    let lines = pageText.components(separatedBy: "\n")
    let start = try #require(lines.firstIndex { $0.hasPrefix(prefix) })
    var end = start + 1
    while end < lines.count, lines[end].hasPrefix("  ") { end += 1 }
    return Array(lines[start..<end])
  }

  private static let slice2ID =
    "slice-2-test-block-from-in-progress-moves-to-blocked-and-records-history"

  @Test(
    "a worker pack for a task covering slice 2 holds slice 2's text byte for byte, the surface and its module's row, and no other slice — catches a pack that summarises or leaks slices"
  )
  func workerPackCarriesOnlyItsSlices() async throws {
    let repository = try Repository()
    defer { repository.remove() }
    let swiftPM = try repository.seedModuleGraph()
    let options = try workerOptions(
      covers: [Self.slice2ID], writeSet: ["Sample/Sources/AppCore/", "Sample/Tests/AppCoreTests/"],
      in: repository)

    let outcome = await ContextPackRun.run(
      role: "worker", options: options, root: repository.root, swiftPM: swiftPM)
    guard case .written(let written) = outcome else {
      Issue.record("expected .written, got \(outcome)")
      return
    }
    #expect(written.relativePath == ".harness/context-pack/worker-task-history.md")
    let text = try repository.text(written.relativePath)

    let slice2 = try sliceLines(startingWith: "2. ").joined(separator: "\n")
    #expect(text.contains(slice2))
    #expect(text.contains(Self.slice2ID))
    for other in ["1. ", "3. ", "4. "] {
      let line = try #require(try sliceLines(startingWith: other).first)
      #expect(!text.contains(line))
    }
    let pageLines = pageText.components(separatedBy: "\n")
    for line in pageLines where line.hasPrefix("- `") {
      #expect(text.contains(line), "surface bullet missing: \(line)")
    }
    let appCore = try #require(pageLines.first { $0.hasPrefix("| AppCore |") })
    let appUI = try #require(pageLines.first { $0.hasPrefix("| AppUI |") })
    #expect(text.contains(appCore))
    #expect(!text.contains(appUI))
    #expect(!text.contains("## Goal"))
    #expect(text.contains("ARCHITECTURE-SECTION"))
    #expect(!text.contains("ENGINE-SECTION"))
    #expect(text.contains("\"id\" : \"task-history\""))
  }

  @Test(
    "a worker task covering a slice id the page doesn't have exits 1 naming the id — catches an unknown id read as covering nothing"
  )
  func unknownSliceIDIsAViolation() async throws {
    let repository = try Repository()
    defer { repository.remove() }
    let swiftPM = try repository.seedModuleGraph()
    let options = try workerOptions(
      covers: [Self.slice2ID, "slice-9-test-nothing"], in: repository)

    let outcome = await ContextPackRun.run(
      role: "worker", options: options, root: repository.root, swiftPM: swiftPM)
    guard case .violation(let message) = outcome else {
      Issue.record("expected .violation, got \(outcome)")
      return
    }
    #expect(message.contains("slice-9-test-nothing"))
    #expect(message.contains(Self.pagePath))
  }

  @Test(
    "a worker write-set entry in a module neither the graph nor the page's Modules table has exits 1 naming the page's table — catches a task packed without its standards"
  )
  func unresolvedWriteSetEntryNamesThePage() async throws {
    let repository = try Repository()
    defer { repository.remove() }
    let swiftPM = try repository.seedModuleGraph()
    let options = try workerOptions(
      covers: [Self.slice2ID], writeSet: ["Sample/Sources/AppCroe/"], in: repository)

    let outcome = await ContextPackRun.run(
      role: "worker", options: options, root: repository.root, swiftPM: swiftPM)
    guard case .violation(let message) = outcome else {
      Issue.record("expected .violation, got \(outcome)")
      return
    }
    #expect(message.contains("Sample/Sources/AppCroe/"))
    #expect(message.contains("spec page's Modules table"))
  }

  @Test(
    "--design and --spec-page together exit 2 for the decomposer and the worker, and neither exits 2 naming both — catches a pack built from 1 source while the other is ignored",
    arguments: ["decomposer", "worker"])
  func exactlyOneSource(role: String) async throws {
    let repository = try Repository()
    defer { repository.remove() }
    let swiftPM = try repository.seedModuleGraph()
    var options = try workerOptions(covers: [Self.slice2ID], in: repository)
    options.moduleGraph = try repository.write("Sample: LogClient\n", at: "graph.txt")
    options.taskSizingBounds = try repository.write("est_lines_max = 400\n", at: "bounds.txt")
    options.design = try repository.write(
      try String(
        contentsOf: Fixture.directory.deletingLastPathComponent().deletingLastPathComponent()
          .appending(path: "Fixtures/design/valid.md"), encoding: .utf8),
      at: "design.md")

    let both = await ContextPackRun.run(
      role: role, options: options, root: repository.root, swiftPM: swiftPM)
    guard case .invalid(let message) = both else {
      Issue.record("expected .invalid, got \(both)")
      return
    }
    #expect(message.contains("--design"))
    #expect(message.contains("--spec-page"))

    options.design = nil
    options.specPage = nil
    let neither = await ContextPackRun.run(
      role: role, options: options, root: repository.root, swiftPM: swiftPM)
    guard case .invalid(let missing) = neither else {
      Issue.record("expected .invalid, got \(neither)")
      return
    }
    #expect(missing.contains("--design"))
    #expect(missing.contains("--spec-page"))
  }

  @Test(
    "--spec-page on a role that reads no plan source exits 2 — catches a flag ignored without a word"
  )
  func specPageOnAnotherRoleIsInvalid() async throws {
    let repository = try Repository()
    defer { repository.remove() }
    var options = ContextPackGatherInputs()
    options.specPage = try repository.write(pageText, at: Self.pagePath)
    options.design = try repository.write("# D\n\n## Decision\n\nx\n", at: "design.md")
    options.questionSet = try repository.write("- why?\n", at: "questions.md")

    let outcome = await ContextPackRun.run(
      role: "challenger", options: options, root: repository.root,
      swiftPM: FakeSwiftPM(serving: []))
    guard case .invalid(let message) = outcome else {
      Issue.record("expected .invalid, got \(outcome)")
      return
    }
    #expect(message.contains("--spec-page"))
  }

  @Test(
    "a spec page that breaks the format exits 1 naming the page and its problem — catches a pack cut from a page the parser rejected"
  )
  func malformedPageIsAViolation() async throws {
    let repository = try Repository()
    defer { repository.remove() }
    let swiftPM = try repository.seedModuleGraph()
    var options = try workerOptions(covers: [Self.slice2ID], in: repository)
    let broken = pageText.replacingOccurrences(of: "## Surface\n", with: "## Types\n")
    #expect(broken != pageText)
    options.specPage = try repository.write(broken, at: Self.pagePath)

    let outcome = await ContextPackRun.run(
      role: "worker", options: options, root: repository.root, swiftPM: swiftPM)
    guard case .violation(let message) = outcome else {
      Issue.record("expected .violation, got \(outcome)")
      return
    }
    #expect(message.contains(Self.pagePath))
    #expect(message.contains("## Surface"))
  }

  @Test(
    "the decomposer pack for a design stays byte-identical to the captured one, and for a spec page it carries the Modules, Surface and Slices sections verbatim with each slice's id and tier — catches a design pack that moved or a page pack that summarises"
  )
  func decomposerPacks() async throws {
    let repository = try Repository()
    defer { repository.remove() }
    let fixtures = Fixture.directory
    var options = ContextPackGatherInputs()
    options.design = try repository.write(
      try String(
        contentsOf: fixtures.deletingLastPathComponent().deletingLastPathComponent()
          .appending(path: "Fixtures/design/valid.md"), encoding: .utf8),
      at: "design.md")
    options.moduleGraph = try repository.write(
      "Sample: OrderQueueCore, OrderQueueFeature\n", at: "graph.txt")
    options.taskSizingBounds = try repository.write("est_lines_max = 400\n", at: "bounds.txt")

    let design = await ContextPackRun.run(
      role: "decomposer", options: options, root: repository.root,
      swiftPM: FakeSwiftPM(serving: []))
    guard case .written(let designPack) = design else {
      Issue.record("expected .written, got \(design)")
      return
    }
    let captured = try String(
      contentsOf: fixtures.appending(path: "context-pack/design-decomposer.pack.txt"),
      encoding: .utf8)
    #expect(try repository.text(designPack.relativePath) == captured)

    options.design = nil
    options.specPage = try repository.write(pageText, at: Self.pagePath)
    let page = await ContextPackRun.run(
      role: "decomposer", options: options, root: repository.root,
      swiftPM: FakeSwiftPM(serving: []))
    guard case .written(let pagePack) = page else {
      Issue.record("expected .written, got \(page)")
      return
    }
    let text = try repository.text(pagePack.relativePath)
    let pageLines = pageText.components(separatedBy: "\n")
    let modules = try #require(pageLines.firstIndex(of: "## Modules"))
    let outOfScope = try #require(pageLines.firstIndex(of: "## Out of scope"))
    var body = Array(pageLines[modules..<outOfScope])
    while body.last == "" { body.removeLast() }
    for section in ["## Modules", "## Surface", "## Slices"] {
      let start = try #require(body.firstIndex(of: section))
      var end = start + 1
      while end < body.count, !body[end].hasPrefix("## ") { end += 1 }
      #expect(text.contains(body[start..<end].joined(separator: "\n")), "\(section) not verbatim")
    }
    #expect(!text.contains("## Goal"))
    #expect(!text.contains("## Out of scope"))
    #expect(text.contains("slice-1-test-new-task-is-to-do-with-only-start-and-empty-history: T1"))
    #expect(text.contains("\(Self.slice2ID): T1"))
    #expect(text.contains("Sample: OrderQueueCore, OrderQueueFeature"))
    #expect(text.contains("est_lines_max = 400"))
  }

  @Test(
    "an absolute --spec-page inside the repository packs byte for byte as its repository-relative path, for the decomposer and the worker — catches a page refused because the plan skill names it absolutely, or a pack citing the machine's path",
    arguments: ["decomposer", "worker"])
  func absolutePageInsideTheRepository(role: String) async throws {
    let repository = try Repository()
    defer { repository.remove() }
    let swiftPM = try repository.seedModuleGraph()
    var options = try workerOptions(covers: [Self.slice2ID], in: repository)
    options.moduleGraph = try repository.write("Sample: LogClient\n", at: "graph.txt")
    options.taskSizingBounds = try repository.write("est_lines_max = 400\n", at: "bounds.txt")

    let relative = await ContextPackRun.run(
      role: role, options: options, root: repository.root, swiftPM: swiftPM)
    guard case .written(let relativePack) = relative else {
      Issue.record("expected .written, got \(relative)")
      return
    }
    let expected = try repository.text(relativePack.relativePath)
    try FileManager.default.removeItem(
      at: repository.root.appending(path: relativePack.relativePath))

    options.specPage = repository.root.appending(path: Self.pagePath).path(percentEncoded: false)
    let absolute = await ContextPackRun.run(
      role: role, options: options, root: repository.root, swiftPM: swiftPM)
    guard case .written(let absolutePack) = absolute else {
      Issue.record("expected .written, got \(absolute)")
      return
    }
    let text = try repository.text(absolutePack.relativePath)
    #expect(text == expected)
    #expect(!text.contains(repository.root.path(percentEncoded: false)))
  }

  @Test(
    "an absolute --spec-page outside the repository exits 2 naming the page — catches a pack that cites a path on the operator's machine"
  )
  func absolutePageOutsideTheRepositoryIsInvalid() async throws {
    let repository = try Repository()
    defer { repository.remove() }
    let elsewhere = try Repository()
    defer { elsewhere.remove() }
    let swiftPM = try repository.seedModuleGraph()
    var options = try workerOptions(covers: [Self.slice2ID], in: repository)
    try elsewhere.write(pageText, at: Self.pagePath)
    let outside = elsewhere.root.appending(path: Self.pagePath).path(percentEncoded: false)
    options.specPage = outside

    let outcome = await ContextPackRun.run(
      role: "worker", options: options, root: repository.root, swiftPM: swiftPM)
    guard case .invalid(let message) = outcome else {
      Issue.record("expected .invalid, got \(outcome)")
      return
    }
    #expect(message.contains(outside))
    #expect(message.contains("outside the repository"))
  }
}
