import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

private let ecosystems = ["cargo", "go", "gradle", "maven", "node", "python", "ruby", "swift"]

/// The capture's scrub wrote placeholders such as `<repo>` into attribute values and text, which
/// no XML parser accepts; the real run held plain paths and names there.
private func junitAsRun(_ relativePath: String) throws -> Data {
  var text = try Fixture.text(relativePath)
  for placeholder in ["repo", "scratch", "home", "tmp", "host", "user"] {
    text = text.replacingOccurrences(of: "<\(placeholder)>", with: "/\(placeholder)")
  }
  return Data(text.utf8)
}

/// 1 captured area run, as the live runner hands it to the reader: stdout then stderr.
private struct CapturedRun {
  let end: AreaProcessEnd
  let output: String
  let junit: Data?

  init(_ ecosystem: String, _ caseName: String) throws {
    let directory = "AreaRuns/\(ecosystem)/\(caseName)"
    let exit = try #require(
      Int32(try Fixture.text("\(directory)/exit").trimmingCharacters(in: .whitespacesAndNewlines)))
    end = .exited(exit)
    output = try Fixture.text("\(directory)/stdout") + Fixture.text("\(directory)/stderr")
    junit = try? junitAsRun("\(directory)/junit.xml")
  }
}

private func area(
  name: String = "api", root: String = "packages/api", kind: AreaKind = .node,
  test: String? = "pnpm exec jest", testFiles: String? = nil
) -> BrownfieldArea {
  BrownfieldArea(
    name: name, root: root, language: .typescript, kind: kind, test: test, testFiles: testFiles,
    lint: "pnpm exec eslint {files}", build: nil, e2e: nil, testGlobs: [], packs: [], xcode: nil)
}

private let layout = BrownfieldStateLayout(
  commonDir: URL(filePath: "/clone/.git", directoryHint: .isDirectory),
  gitDir: URL(filePath: "/clone/.git/worktrees/w1", directoryHint: .isDirectory))

@Suite("Area command expansion")
struct AreaCommandExpansionTests {
  @Test("a path holding a space and a quote expands to 1 argument — catches unquoted expansion")
  func quotesEachValue() {
    let expanded = AreaCommandExpansion.expand(
      "pytest {tests}", files: [], tests: ["tests/it's a test.py", "b.py"], junitPath: "/j.xml")
    #expect(expanded.command == #"pytest 'tests/it'\''s a test.py' 'b.py'"#)
    #expect(!expanded.runsWhole)
    #expect(expanded.junitPath == nil)
  }

  @Test("files and junit fill their placeholders — catches a placeholder left for the shell")
  func fillsFilesAndJUnit() {
    let expanded = AreaCommandExpansion.expand(
      "eslint {files} --out {junit}", files: ["src/a b.ts", "src/c.ts"], tests: [],
      junitPath: "/git/swift-harness/junit/api.lint.xml")
    #expect(
      expanded.command
        == "eslint 'src/a b.ts' 'src/c.ts' --out '/git/swift-harness/junit/api.lint.xml'"
    )
    #expect(expanded.junitPath == "/git/swift-harness/junit/api.lint.xml")
  }

  @Test("a test command without {tests} runs whole and says so — catches a silent full run")
  func withoutTestsRunsWhole() {
    let expanded = AreaCommandExpansion.expand(
      "cargo test", files: [], tests: ["sum"], junitPath: "/j.xml")
    #expect(expanded.command == "cargo test")
    #expect(expanded.runsWhole)
  }

  @Test("test_files falls back to test and generate has no key — catches a missing selection run")
  func templateFallsBack() {
    let narrowing = area(testFiles: "pnpm exec jest {tests}")
    #expect(
      AreaCommandExpansion.template(for: .testFiles, in: narrowing) == "pnpm exec jest {tests}")
    #expect(AreaCommandExpansion.template(for: .testFiles, in: area()) == "pnpm exec jest")
    #expect(AreaCommandExpansion.template(for: .lint, in: area()) == "pnpm exec eslint {files}")
    #expect(AreaCommandExpansion.template(for: .build, in: area()) == nil)
    #expect(AreaCommandExpansion.template(for: .generate, in: area()) == nil)
  }

  @Test("prepare runs in the area root with files relative to it — catches repo-relative paths")
  func prepareRelativisesFiles() throws {
    let prepared = try #require(
      AreaCommandExpansion.prepare(
        area: area(), step: .lint, repositoryRoot: "/repo",
        files: ["packages/api/src/dpi.ts", "packages/shared/x.ts"], tests: [],
        junitPath: "/j.xml", deadline: .seconds(30), environment: ["A": "1"]))
    #expect(prepared.request.workingDirectory == "/repo/packages/api")
    #expect(prepared.request.command == "pnpm exec eslint 'src/dpi.ts' '../shared/x.ts'")
    #expect(prepared.request.area == "api")
    #expect(prepared.request.step == .lint)
    #expect(prepared.request.environment == ["A": "1"])
    #expect(prepared.request.deadline == .seconds(30))
    #expect(prepared.request.junitPath == nil)
    let whole = try #require(
      AreaCommandExpansion.prepare(
        area: area(root: "."), step: .testFiles, repositoryRoot: "/repo", files: [],
        tests: ["t"], junitPath: "/j.xml", deadline: .seconds(1), environment: [:]))
    #expect(whole.request.workingDirectory == "/repo")
    #expect(whole.runsWhole)
    #expect(
      AreaCommandExpansion.prepare(
        area: area(), step: .build, repositoryRoot: "/repo", files: [], tests: [],
        junitPath: "/j.xml", deadline: .seconds(1), environment: [:]) == nil)
  }

  @Test("junit reports sit under the worktree's git dir — catches a report written into the tree")
  func junitPathUnderGitDir() {
    #expect(
      AreaCommandExpansion.junitPath(layout: layout, area: "api", step: .testFiles)
        == "/clone/.git/worktrees/w1/swift-harness/junit/api.test_files.xml")
  }
}

@Suite("Area outcome reading")
struct AreaOutcomeReadingTests {
  @Test(
    "each captured JUnit file decodes to its pass and fail counts — catches counts read from 1 runner's summary attributes",
    arguments: [
      ("gradle", "test-crash", JUnitCounts(tests: 12, failures: 0, skipped: 1)),
      ("gradle", "test-fail", JUnitCounts(tests: 1, failures: 1, skipped: 0)),
      ("gradle", "test-pass", JUnitCounts(tests: 1, failures: 0, skipped: 0)),
      ("maven", "test-fail", JUnitCounts(tests: 1, failures: 1, skipped: 0)),
      ("maven", "test-pass", JUnitCounts(tests: 1, failures: 0, skipped: 0)),
      ("node", "test-fail", JUnitCounts(tests: 4, failures: 1, skipped: 0)),
      ("node", "test-pass", JUnitCounts(tests: 4, failures: 0, skipped: 0)),
      ("python", "test-fail", JUnitCounts(tests: 1, failures: 1, skipped: 0)),
      ("python", "test-pass", JUnitCounts(tests: 1, failures: 0, skipped: 0)),
      ("swift", "test-crash", JUnitCounts(tests: 5, failures: 1, skipped: 0)),
      ("swift", "test-fail", JUnitCounts(tests: 1, failures: 1, skipped: 0)),
      ("swift", "test-pass", JUnitCounts(tests: 1, failures: 0, skipped: 0)),
    ])
  func junitCounts(ecosystem: String, caseName: String, expected: JUnitCounts) throws {
    let data = try junitAsRun("AreaRuns/\(ecosystem)/\(caseName)/junit.xml")
    #expect(AreaOutcomeReading.junitCounts(data) == expected)
  }

  @Test("a truncated JUnit file is no report — catches a half-written report read as a pass")
  func truncatedJUnit() throws {
    let data = try junitAsRun("AreaRuns/python/test-fail/junit.xml")
    #expect(AreaOutcomeReading.junitCounts(data) != nil)
    #expect(AreaOutcomeReading.junitCounts(data.prefix(data.count / 2)) == nil)
  }

  @Test(
    "each captured crash reads as crashed — catches a signal read as a plain failure",
    arguments: [
      ("cargo", Int32?.some(6)), ("go", nil), ("gradle", nil), ("maven", nil), ("node", nil),
      ("python", 6), ("ruby", 6), ("swift", 6),
    ])
  func crashes(ecosystem: String, signal: Int32?) throws {
    let run = try CapturedRun(ecosystem, "test-crash")
    #expect(
      AreaOutcomeReading.outcome(end: run.end, output: run.output, junit: run.junit)
        == .crashed(signal: signal, tail: AreaOutcomeReading.tail(run.output)))
  }

  @Test(
    "each captured failure and lint run reads as failed, Go's failing tests with a report — catches a crash marker matching ordinary output, or Go's events left unread",
    // Clippy's warnings leave its status 0, so the cargo lint run is a pass.
    arguments: ecosystems.flatMap { [($0, "test-fail"), ($0, "lint")] }.filter {
      $0 != ("cargo", "lint")
    })
  func failures(ecosystem: String, caseName: String) throws {
    let run = try CapturedRun(ecosystem, caseName)
    guard case .exited(let exit) = run.end else {
      Issue.record("a captured run ends with an exit status")
      return
    }
    let outcome = AreaOutcomeReading.outcome(end: run.end, output: run.output, junit: run.junit)
    guard case .failed(let status, let tail, let junit) = outcome else {
      Issue.record("\(ecosystem) \(caseName) read as \(outcome)")
      return
    }
    #expect(status == exit)
    #expect(tail == AreaOutcomeReading.tail(run.output))
    // Go writes no JUnit; its failing run's `-json` events stand in for one.
    let goEvents = ecosystem == "go" && caseName == "test-fail"
    #expect(goEvents ? junit != nil : junit == run.junit)
  }

  @Test(
    "each captured pass reads as passed — catches a passing run read from its output",
    arguments: ecosystems)
  func passes(ecosystem: String) throws {
    let run = try CapturedRun(ecosystem, "test-pass")
    #expect(
      AreaOutcomeReading.outcome(end: run.end, output: run.output, junit: run.junit) == .passed)
  }

  @Test("a process killed by a signal is crashed — catches a signal end read as exit 0")
  func signaledEnd() {
    #expect(
      AreaOutcomeReading.outcome(end: .signaled(9), output: "x\n", junit: nil)
        == .crashed(signal: 9, tail: "x"))
  }

  @Test("the tail is the last 40 lines — catches the head or the whole output kept")
  func tailKeepsLastLines() {
    let output = (1...100).map { "line \($0)" }.joined(separator: "\n") + "\n"
    let tail = AreaOutcomeReading.tail(output)
    #expect(tail == (61...100).map { "line \($0)" }.joined(separator: "\n"))
    #expect(AreaOutcomeReading.timedOut(output: output) == .timedOut(tail: tail))
  }
}

@Suite("Area cache environment")
struct AreaCacheEnvironmentTests {
  private let caches = "/clone/.git/swift-harness/caches"

  @Test("a node area shares the clone's caches — catches each worktree filling its own")
  func nodeSharesCaches() {
    let environment = AreaCacheEnvironment.make(
      area: area(), layout: layout, tree: TrackedTreeSnapshot(files: [:]))
    #expect(AreaCacheEnvironment.cachesDirectory(layout: layout) == caches)
    #expect(
      environment.variables == [
        "npm_config_cache": "\(caches)/npm", "npm_config_store_dir": "\(caches)/pnpm-store",
        "YARN_CACHE_FOLDER": "\(caches)/yarn",
      ])
    #expect(environment.derivedDataSeed == "\(caches)/derived-data/api")
  }

  @Test(
    "a repository with its own .npmrc cache setting keeps it — catches an override of the repository's pin",
    arguments: [".npmrc", "packages/api/.npmrc"])
  func npmrcPinKept(path: String) {
    let tree = TrackedTreeSnapshot(files: [
      path: Data("registry=https://r\ncache = .npm-cache\n".utf8)
    ])
    let environment = AreaCacheEnvironment.make(area: area(), layout: layout, tree: tree)
    #expect(environment.variables["npm_config_cache"] == nil)
    #expect(environment.variables["npm_config_store_dir"] == "\(caches)/pnpm-store")
  }

  @Test("a commented-out cache line is no pin — catches a substring match on the key")
  func commentedPinIgnored() {
    let tree = TrackedTreeSnapshot(files: [".npmrc": Data("; cache=.npm-cache\n".utf8)])
    let environment = AreaCacheEnvironment.make(area: area(), layout: layout, tree: tree)
    #expect(environment.variables["npm_config_cache"] == "\(caches)/npm")
  }

  @Test("go and python areas share their module caches unless pinned — catches a missing ecosystem")
  func goAndPython() {
    let go = AreaCacheEnvironment.make(
      area: area(name: "server", root: ".", kind: .go), layout: layout,
      tree: TrackedTreeSnapshot(files: [:]))
    #expect(go.variables == ["GOMODCACHE": "\(caches)/go-mod", "GOCACHE": "\(caches)/go-build"])
    let pinned = TrackedTreeSnapshot(files: ["uv.toml": Data("cache-dir = \"./.uv\"\n".utf8)])
    let python = AreaCacheEnvironment.make(
      area: area(name: "py", root: ".", kind: .python), layout: layout, tree: pinned)
    #expect(python.variables == ["PIP_CACHE_DIR": "\(caches)/pip"])
  }
}
