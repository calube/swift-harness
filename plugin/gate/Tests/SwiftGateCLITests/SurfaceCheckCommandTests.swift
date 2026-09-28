import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

/// Serves 1 captured commit under `Fixtures/surface/cases/<name>` as ``SurfaceCommitReading``
/// would read it from git; `surface/capture.sh` records each one from a real repository.
struct CapturedSurfaceReader: SurfaceCommitReading {
  let name: String

  private var directory: URL { Fixture.directory.appending(path: "surface/cases/\(name)") }

  func read(_ commit: String) async throws(SurfaceReadError) -> SurfaceCommit {
    let changed: [String]
    do {
      changed = try String(contentsOf: directory.appending(path: "changed.txt"), encoding: .utf8)
        .split(separator: "\n").map(String.init)
    } catch {
      throw .unknownCommit(commit)
    }
    var changes: [SurfaceFileChange] = []
    for path in changed where path.hasSuffix(".swift") {
      let parent = try side("parent", path)
      let commitText = try side("commit", path)
      if parent == nil, commitText == nil { throw .missingPath(path) }
      changes.append(SurfaceFileChange(path: path, parentText: parent, commitText: commitText))
    }
    return SurfaceCommit(
      commit: "captured-\(name)", parent: "captured-base", changes: changes,
      otherPaths: changed.filter { !$0.hasSuffix(".swift") })
  }

  func parentSwiftSources(of surface: SurfaceCommit) async throws(SurfaceReadError) -> [String:
    String]
  {
    let tree = Fixture.directory.appending(path: "surface/parent-tree")
    var sources: [String: String] = [:]
    let files = FileManager.default.enumerator(at: tree, includingPropertiesForKeys: nil)
    while let url = files?.nextObject() as? URL {
      guard url.pathExtension == "txt" else { continue }
      let relative = String(url.path.dropFirst(tree.path.count + 1).dropLast(".txt".count))
      do {
        sources[relative] = try String(contentsOf: url, encoding: .utf8)
      } catch {
        throw .missingPath(relative)
      }
    }
    return sources
  }

  private func side(_ side: String, _ path: String) throws(SurfaceReadError) -> String? {
    let url = directory.appending(path: "\(side)/\(path).txt")
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    do {
      return try String(contentsOf: url, encoding: .utf8)
    } catch {
      throw .missingPath(path)
    }
  }
}

struct SurfaceJudged: Sendable, Equatable, CustomTestStringConvertible {
  let declaration: String
  let outcome: SurfaceJudgement.Outcome

  init(_ declaration: String, _ form: SurfaceStubForm) {
    self.declaration = declaration
    outcome = .stub(form)
  }

  var testDescription: String { "\(declaration): \(outcome)" }
}

struct SurfaceRejected: Sendable, CustomTestStringConvertible {
  let file: String
  let line: Int?
  let declaration: String
  let behaviour: SurfaceBehaviour

  init(
    _ declaration: String, _ behaviour: SurfaceBehaviour, line: Int?,
    file: String = "Sources/App/Surface.swift"
  ) {
    self.file = file
    self.line = line
    self.declaration = declaration
    self.behaviour = behaviour
  }

  var testDescription: String { "\(declaration) at \(file):\(line ?? 0)" }
}

@Suite("surface-check over captured commits")
struct SurfaceCheckCommandTests {
  /// Every allowed stub form, each a real commit that must pass: the false-negative list.
  static let allowed: [(name: String, judged: [SurfaceJudged])] = [
    (
      "allowed-empty-body",
      [SurfaceJudged("ItemClient.reset()", .empty), SurfaceJudged("ItemClient.stop()", .empty)]
    ),
    (
      "allowed-empty-defaults",
      [
        SurfaceJudged("ItemClient.find(id:)", .emptyDefault),
        SurfaceJudged("ItemClient.all()", .emptyDefault),
        SurfaceJudged("ItemClient.byName()", .emptyDefault),
        SurfaceJudged("ItemClient.total()", .emptyDefault),
        SurfaceJudged("ItemClient.hasMore()", .emptyDefault),
        SurfaceJudged("ItemClient.title()", .emptyDefault),
        SurfaceJudged("ItemClient.blank()", .emptyDefault),
      ]
    ),
    ("allowed-payload-free-case", [SurfaceJudged("initialTab()", .payloadFreeCase)]),
    (
      "allowed-accessors",
      [
        SurfaceJudged("Settings.isEmpty", .emptyDefault),
        SurfaceJudged("Settings.title.get", .emptyDefault),
        SurfaceJudged("Settings.title.set", .empty), SurfaceJudged("Settings.limit.didSet", .empty),
        SurfaceJudged("Settings.subscript(index:)", .emptyDefault),
      ]
    ),
    (
      "allowed-initializers",
      [
        SurfaceJudged("Draft.init()", .empty), SurfaceJudged("Draft.init(name:)", .empty),
        SurfaceJudged("Item.init(title:)", .forward),
      ]
    ),
    (
      "allowed-throws-async",
      [
        SurfaceJudged("ItemClient.load()", .emptyDefault),
        SurfaceJudged("ItemClient.save(_:)", .empty),
        SurfaceJudged("ItemClient.refresh()", .forward),
      ]
    ),
    (
      "allowed-forward",
      [
        SurfaceJudged("reload(client:)", .forward), SurfaceJudged("sum(values:)", .forward),
        SurfaceJudged("makeItem(name:)", .forward),
      ]
    ),
    (
      "allowed-reducer-none",
      [SurfaceJudged("Detail.body", .reducerNone), SurfaceJudged("Placeholder.body", .reducerNone)]
    ),
    ("allowed-reducer-new-action", [SurfaceJudged("Feature.body case .decrement", .reducerNone)]),
    (
      "allowed-empty-view",
      [SurfaceJudged("DetailView.body", .emptyView), SurfaceJudged("ListScreen.body", .emptyView)]
    ),
    (
      "allowed-preview",
      [
        SurfaceJudged("DetailView.body", .emptyView),
        SurfaceJudged("#Preview", .previewWithoutData),
        SurfaceJudged("#Preview(\"Empty list\")", .previewWithoutData),
        SurfaceJudged("Item.preview", .previewWithoutData),
      ]
    ),
    (
      "allowed-closure-property",
      [SurfaceJudged("Callbacks.onTap", .empty), SurfaceJudged("Callbacks.loader", .emptyDefault)]
    ),
    ("allowed-new-enum-case", [SurfaceJudged("describe(_:short:) case .profile", .emptyDefault)]),
    (
      "allowed-init-assigns-parameters",
      [SurfaceJudged("Draft.init(name:)", .assignsParameters)]
    ),
    (
      "allowed-empty-value",
      [
        SurfaceJudged("Page.empty", .emptyValue), SurfaceJudged("firstPage(title:)", .emptyValue),
        SurfaceJudged("Pager.makePage", .emptyValue),
      ]
    ),
    (
      "allowed-registration",
      [SurfaceJudged("Root.commands", .registersType), SurfaceJudged("Root.names", .registersType)]
    ),
    ("allowed-manifest-local-package", [SurfaceJudged("package", .extendsManifest)]),
    ("allowed-manifest-products-and-targets", [SurfaceJudged("package", .extendsManifest)]),
  ]

  /// Bodies that look like stubs but carry behaviour, each a real commit that must fail naming
  /// its declaration: the false-positive list.
  static let rejected: [(name: String, findings: [SurfaceRejected])] = [
    (
      "rejected-array-of-init", [SurfaceRejected("all()", .notAStub(excerpt: "[.init()]"), line: 1)]
    ),
    ("rejected-return-one", [SurfaceRejected("total()", .notAStub(excerpt: "return 1"), line: 1)]),
    ("rejected-return-true", [SurfaceRejected("hasMore()", .notAStub(excerpt: "true"), line: 1)]),
    (
      "rejected-sample-data",
      [SurfaceRejected("all()", .notAStub(excerpt: "[Item(name: \"Milk\")]"), line: 1)]
    ),
    (
      "rejected-string-content",
      [SurfaceRejected("title()", .notAStub(excerpt: "\"TODO\""), line: 1)]
    ),
    (
      "rejected-payload-case",
      [SurfaceRejected("state()", .notAStub(excerpt: ".success([])"), line: 1)]
    ),
    (
      "rejected-computed-logic",
      [SurfaceRejected("ItemClient.isIdle", .notAStub(excerpt: "timeout == 0"), line: 2)]
    ),
    (
      "rejected-two-statements",
      [SurfaceRejected("total()", .notAStub(excerpt: "let base = 0"), line: 1)]
    ),
    ("rejected-fatal-error", [SurfaceRejected("load()", .traps(callee: "fatalError"), line: 1)]),
    (
      "rejected-precondition-failure",
      [SurfaceRejected("save(_:)", .traps(callee: "preconditionFailure"), line: 1)]
    ),
    (
      "rejected-setter-stores",
      [SurfaceRejected("Settings.title.set", .notAStub(excerpt: "storage = newValue"), line: 6)]
    ),
    (
      "rejected-init-assigns-computed",
      [
        SurfaceRejected(
          "Counter.init(count:)", .notAStub(excerpt: "self.count = count + 1"), line: 5),
        SurfaceRejected(
          "Counter.init(label:)", .notAStub(excerpt: "self.label = \"Count\""), line: 10),
      ]
    ),
    (
      "rejected-empty-value-near-miss",
      [
        SurfaceRejected(
          "firstPage(title:)", .notAStub(excerpt: "Page(items: [1], title: title)"), line: 6),
        SurfaceRejected(
          "namedPage(title:)",
          .notAStub(excerpt: "Page(items: [], title: title.uppercased())"), line: 10),
        SurfaceRejected(
          "markedPage(title:)", .notAStub(excerpt: "Page(items: [], title: title + \"!\")"),
          line: 14),
      ]
    ),
    (
      "rejected-registration-call",
      [
        SurfaceRejected(
          "Root.commands", .changesStoredValue, line: 2, file: "Sources/App/Commands.swift"),
        SurfaceRejected(
          "Root.names",
          .notAStub(excerpt: "[ListCommand.self, Registry.lookup(\"add\")]"), line: 8,
          file: "Sources/App/Commands.swift"),
      ]
    ),
    (
      "rejected-forward-new-code",
      [SurfaceRejected("sum()", .forwardsToNewCode(callee: "helper"), line: 1)]
    ),
    (
      "rejected-forward-computed-argument",
      [SurfaceRejected("sum(values:)", .notAStub(excerpt: "existingTotal(values + [1])"), line: 1)]
    ),
    (
      "rejected-changed-existing-body",
      [
        SurfaceRejected(
          "ItemClient.count()", .notAStub(excerpt: "return 4"), line: 19,
          file: "Sources/App/Existing.swift")
      ]
    ),
    (
      "rejected-changed-existing-case",
      [
        SurfaceRejected(
          "describe(_:)",
          .notAStub(
            excerpt:
              "switch tab { case .home: return \"Start\" case .settings: return \"Settings\" }"),
          line: 34, file: "Sources/App/Feature.swift")
      ]
    ),
    (
      "rejected-changed-stored-value",
      [
        SurfaceRejected(
          "ItemClient.timeout", .changesStoredValue, line: 13, file: "Sources/App/Existing.swift")
      ]
    ),
    (
      "rejected-reducer-mutates",
      [
        SurfaceRejected(
          "Feature.body case .decrement", .reducerWork(excerpt: "state.count -= 1"), line: 22,
          file: "Sources/App/Feature.swift")
      ]
    ),
    (
      "rejected-reducer-effect",
      [
        SurfaceRejected(
          "Feature.body case .refresh", .reducerWork(excerpt: "return .run { _ in }"), line: 22,
          file: "Sources/App/Feature.swift")
      ]
    ),
    (
      "rejected-view-content",
      [
        SurfaceRejected(
          "DetailView.body", .viewContent(excerpt: "Text(\"Hello\")"), line: 4,
          file: "Sources/App/Views.swift")
      ]
    ),
    (
      "rejected-view-shapes",
      [
        SurfaceRejected(
          "PaddedView.body", .viewContent(excerpt: "EmptyView().padding()"), line: 4,
          file: "Sources/App/Views.swift"),
        SurfaceRejected(
          "SpacedView.body", .viewContent(excerpt: "VStack(spacing: 8) { EmptyView() }"), line: 10,
          file: "Sources/App/Views.swift"),
      ]
    ),
    (
      "rejected-preview-sample",
      [
        SurfaceRejected(
          "#Preview", .sampleData(literal: "3"), line: 4, file: "Sources/App/Views.swift")
      ]
    ),
    (
      "rejected-preview-fixture",
      [SurfaceRejected("Item.preview", .sampleData(literal: "\"Milk\""), line: 2)]
    ),
    (
      "rejected-closure-property",
      [SurfaceRejected("Formatters.format", .notAStub(excerpt: "\"\\($0)\""), line: 2)]
    ),
    (
      "rejected-test-file",
      [
        SurfaceRejected(
          "DetailTests.swift", .addsTest, line: nil, file: "Tests/AppTests/DetailTests.swift")
      ]
    ),
    (
      "rejected-test-in-existing-file",
      [
        SurfaceRejected(
          "FeatureTests.describesSettings()", .addsTest, line: 10,
          file: "Tests/AppTests/FeatureTests.swift")
      ]
    ),
    (
      "rejected-manifest-removed-dependency",
      [
        SurfaceRejected(
          "package", .changesManifest(excerpt: ".package(path: \"../APIClient\")"), line: 11,
          file: manifest)
      ]
    ),
    (
      "rejected-manifest-changed-element",
      [
        SurfaceRejected(
          "package", .changesManifest(excerpt: "exact: \"1.27.0\""), line: 16, file: manifest)
      ]
    ),
    (
      "rejected-manifest-swift-settings",
      [
        SurfaceRejected(
          "package", .changesManifest(excerpt: ".unsafeFlags([\"-Onone\"])"), line: 27,
          file: manifest)
      ]
    ),
    (
      "rejected-manifest-platform",
      [SurfaceRejected("package", .changesManifest(excerpt: ".iOS(.v17)"), line: 6, file: manifest)]
    ),
    (
      "rejected-manifest-tools-version",
      [
        SurfaceRejected(
          "package", .changesManifest(excerpt: "// swift-tools-version: 6.1"), line: 1,
          file: manifest)
      ]
    ),
    (
      "rejected-manifest-new-statement",
      [
        SurfaceRejected(
          "package",
          .changesManifest(excerpt: "package.targets.append(.target(name: \"Extra\"))"), line: 41,
          file: manifest)
      ]
    ),
  ]

  static let manifest = "Packages/AppFeature/Package.swift"

  private static func run(_ name: String) async throws -> (
    judgements: [SurfaceJudgement], report: RunReport
  ) {
    let reader = CapturedSurfaceReader(name: name)
    let (_, judgements) = try await SurfaceCheckRun.judgements(commit: name, reader: reader)
    let outcome = await SurfaceCheckRun.outcome(commit: name, reader: reader)
    let report = try StaticCheckReport.make(
      runID: "surface", durationMilliseconds: 0, outcome: outcome)
    return (judgements, report)
  }

  @Test(
    "an allowed stub passes, judged as its own stub form — catches a legit surface failing, or a body skipped instead of judged",
    arguments: allowed)
  func allowedStubPasses(_ fixture: (name: String, judged: [SurfaceJudged])) async throws {
    let (judgements, report) = try await Self.run(fixture.name)

    #expect(
      judgements.map { SurfaceJudged(declaration: $0.declaration, outcome: $0.outcome) }
        == fixture.judged)
    #expect(report.verdict == .green, "\(report.findings.map(\.message))")
    #expect(report.verdict.exitCode == 0)
    let summary = report.findings.filter { $0.ruleID == SurfaceCheck.summaryRuleID }
    #expect(summary.count == 1)
    #expect(summary.first?.severity == .nit)
  }

  @Test(
    "a body that looks like a stub but carries behaviour fails naming its file, line and declaration — catches a surface holding real behaviour",
    arguments: rejected)
  func rejectedShapeFails(_ fixture: (name: String, findings: [SurfaceRejected])) async throws {
    let (judgements, report) = try await Self.run(fixture.name)

    let behaviours = judgements.compactMap { judgement -> SurfaceRejected? in
      guard case .behaviour(let behaviour) = judgement.outcome else { return nil }
      return SurfaceRejected(
        judgement.declaration, behaviour, line: judgement.line, file: judgement.file)
    }
    #expect(behaviours.map(\.testDescription) == fixture.findings.map(\.testDescription))
    #expect(behaviours.map(\.behaviour) == fixture.findings.map(\.behaviour))

    #expect(report.verdict == .red)
    #expect(report.verdict.exitCode == 1)
    let findings = report.findings.filter { $0.ruleID == SurfaceCheck.behaviourRuleID }
    #expect(findings.count == fixture.findings.count)
    for (finding, expected) in zip(findings, fixture.findings) {
      #expect(finding.severity == .major)
      #expect(finding.file == expected.file)
      #expect(finding.line == expected.line)
      #expect(finding.message.contains("`\(expected.declaration)`"), "\(finding.message)")
    }
  }

  @Test(
    "a surface that links a new local package into an existing manifest and adds a target passes, and the new package's own manifest is judged nothing — catches the whole `Package(…)` value refused as a changed stored value"
  )
  func manifestGainingALocalPackagePasses() async throws {
    let (judgements, report) = try await Self.run("allowed-manifest-local-package")

    #expect(
      judgements == [
        SurfaceJudgement(
          file: Self.manifest, line: 14, declaration: "package", outcome: .stub(.extendsManifest))
      ])
    #expect(report.verdict == .green, "\(report.findings.map(\.message))")
    let summary = try #require(
      report.findings.first { $0.ruleID == SurfaceCheck.summaryRuleID })
    #expect(
      summary.message
        == "1 added or changed bodies judged across 2 changed Swift files: 1 allowed stubs, "
        + "0 behaviour; 0 non-Swift paths not judged")
  }

  @Test(
    "a manifest change past added list elements says what changed and that a surface only adds dependencies, products and targets — catches a finding that leaves the session guessing which line to undo"
  )
  func manifestFindingNamesTheChange() async throws {
    let (_, report) = try await Self.run("rejected-manifest-changed-element")

    let finding = try #require(
      report.findings.first { $0.ruleID == SurfaceCheck.behaviourRuleID })
    #expect(
      finding.message
        == "`package` changes the package manifest (`exact: \"1.27.0\"`): a surface only adds "
        + "dependencies, products and targets to an existing manifest's lists, and removes or "
        + "changes nothing")
  }

  @Test(
    "a commit that deletes a file, edits a doc and only reformats a body judges nothing and passes, counting what it skipped — catches an unchanged body judged as new"
  )
  func unchangedBodiesAreNotJudged() async throws {
    let (judgements, report) = try await Self.run("allowed-no-new-bodies")

    #expect(judgements == [])
    #expect(report.verdict == .green)
    let summary = try #require(
      report.findings.first { $0.ruleID == SurfaceCheck.summaryRuleID })
    #expect(
      summary.message
        == "0 added or changed bodies judged across 2 changed Swift files: 0 allowed stubs, "
        + "0 behaviour; 1 non-Swift path not judged")
  }

  @Test(
    "the parent's declarations are read only when a body could forward — catches every run parsing the parent's whole tree"
  )
  func parentReadOnlyForForwards() async throws {
    struct CountingReader: SurfaceCommitReading {
      let inner: CapturedSurfaceReader
      let reads: Counter

      func read(_ commit: String) async throws(SurfaceReadError) -> SurfaceCommit {
        try await inner.read(commit)
      }

      func parentSwiftSources(of surface: SurfaceCommit) async throws(SurfaceReadError)
        -> [String: String]
      {
        await reads.increment()
        return try await inner.parentSwiftSources(of: surface)
      }
    }
    actor Counter {
      var value = 0
      func increment() { value += 1 }
    }

    let noForward = Counter()
    _ = try await SurfaceCheckRun.judgements(
      commit: "x",
      reader: CountingReader(
        inner: CapturedSurfaceReader(name: "allowed-empty-defaults"), reads: noForward))
    let forward = Counter()
    let (_, judgements) = try await SurfaceCheckRun.judgements(
      commit: "x",
      reader: CountingReader(inner: CapturedSurfaceReader(name: "allowed-forward"), reads: forward))

    #expect(await noForward.value == 0)
    #expect(await forward.value == 1)
    #expect(judgements.map(\.outcome) == [.stub(.forward), .stub(.forward), .stub(.forward)])
  }
}

@Suite("surface-check read failures")
struct SurfaceCheckReadFailureTests {
  private static func git(_ runner: LiveProcessRunner, _ root: URL, _ arguments: String...)
    async throws -> String
  {
    let output = try await runner.run(
      ProcessInvocation(
        executable: "git", arguments: arguments, workingDirectory: root.path,
        timeout: .seconds(30)))
    try #require(output.status.isSuccess, "git \(arguments): \(output.stderr.text)")
    return output.stdout.text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  @Test(
    "a commit whose first parent can't be loaded exits 2 naming it, never GREEN — catches a read failure passing as a clean surface"
  )
  func unloadableParentExitsBlocked() async throws {
    let runner = LiveProcessRunner(baseEnvironment: [
      "PATH": "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin",
      "HOME": FileManager.default.temporaryDirectory.path,
      "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
      "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.com",
      "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.com",
    ])
    let root = FileManager.default.temporaryDirectory
      .appending(path: "swiftgate-surface-cli-\(UUID().uuidString)", directoryHint: .isDirectory)
      .resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try await Self.git(runner, root, "init", "-q", "-b", "main")
    try Data("func stub() {}\n".utf8).write(to: root.appending(path: "Stub.swift"))
    _ = try await Self.git(runner, root, "add", "-A")
    _ = try await Self.git(
      runner, root, "-c", "commit.gpgsign=false", "commit", "-q", "-m", "only commit")
    let sha = try await Self.git(runner, root, "rev-parse", "HEAD")

    let outcome = await SurfaceCheckRun.outcome(
      commit: "HEAD",
      reader: LiveSurfaceCommitReader(runner: runner, repositoryRoot: root.path))
    let report = try StaticCheckReport.make(
      runID: "surface", durationMilliseconds: 0, outcome: outcome)

    #expect(report.verdict == .blocked)
    #expect(report.verdict.exitCode == 2)
    #expect(report.findings.map(\.ruleID) == [StaticCheckReport.environmentRuleID])
    #expect(report.findings.first?.message.contains(sha) == true, "\(report.findings)")
  }
}

extension SurfaceJudged {
  init(declaration: String, outcome: SurfaceJudgement.Outcome) {
    self.declaration = declaration
    self.outcome = outcome
  }
}
