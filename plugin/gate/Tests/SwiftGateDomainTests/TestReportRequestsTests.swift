import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

/// The command a captured `F/AreaRuns/<runner>/<case>/` run ran, `{junit}` unexpanded.
private func capturedCommand(_ path: String) throws -> String {
  try Fixture.text("AreaRuns/\(path)/command").trimmingCharacters(in: .whitespacesAndNewlines)
}

private func propose(_ files: [String: String]) -> [ProposedArea] {
  Discover.propose(
    tree: TrackedTreeSnapshot(files: files.mapValues { Data($0.utf8) }), head: "abc", dirty: []
  )
  .areas
}

private let pyproject = """
  [project]
  name = "pybase"

  [tool.pytest.ini_options]
  testpaths = ["tests"]
  """

private func packageJSON(script: String, jestJUnit: Bool = false) -> String {
  let junit = jestJUnit ? #", "jest-junit": "^17.0.0""# : ""
  return """
    {"name": "base", "scripts": {"test": "\(script)"}, "devDependencies": {"jest": "^30.5.2"\(junit)}}
    """
}

private let gemfile = """
  source "https://rubygems.org"

  gem "rspec", "~> 3.13"
  gem "rspec_junit_formatter", "~> 0.6"
  """

@Suite("discover asks each test runner for a per-test report")
struct TestReportRequestsTests {
  @Test(
    "each runner's test command is exactly the 1 a captured run proved writes its report — catches a request no run proved, or none at all",
    arguments: [
      ("python", ["pyproject.toml": pyproject, "tests/test_alpha.py": ""]),
      (
        "vitest",
        ["package.json": packageJSON(script: "vitest run"), "package-lock.json": "{}"]
      ),
      (
        "jest",
        ["package.json": packageJSON(script: "jest", jestJUnit: true), "package-lock.json": "{}"]
      ),
      ("gradle", ["settings.gradle": "rootProject.name = 'gradlebase'\n", "build.gradle": ""]),
      ("maven", ["pom.xml": "<project><artifactId>mavenbase</artifactId></project>\n"]),
      ("ruby", ["Gemfile": gemfile, "spec/alpha_spec.rb": ""]),
      (
        "swift",
        [
          "Package.swift":
            "let package = Package(targets: [.testTarget(name: \"SwiftBaseTests\")])\n"
        ]
      ),
      ("cargo", ["Cargo.toml": "[package]\nname = \"cargobase\"\n"]),
    ])
  func commandsMatchCapturedRuns(runner: String, files: [String: String]) throws {
    let area = try #require(propose(files).first)
    #expect(area.commands[.test]?.value == (try capturedCommand("\(runner)/baseline-head")))
  }

  @Test(
    "a pnpm area passes the report flags without npm's separator, and the captured pnpm run's report names both failing tests — catches a separator the script receives as a test name, or a report never written",
    arguments: [
      (
        "vitest", packageJSON(script: "vitest run"), "test/alpha.test.js.alpha > flaky",
        "test/beta.test.js.new"
      ),
      ("jest", packageJSON(script: "jest", jestJUnit: true), "alpha flaky", " new"),
    ])
  func pnpmCommandsMatchCapturedRuns(runner: String, manifest: String, flaky: String, fresh: String)
    throws
  {
    let area = try #require(propose(["package.json": manifest, "pnpm-lock.yaml": ""]).first)
    #expect(area.commands[.test]?.value == (try capturedCommand("\(runner)/pnpm-head")))
    #expect(
      BaselineStepResult.of(try capturedRun(runner, "pnpm-head")) == .failedTests([flaky, fresh]))
  }

  @Test(
    "the command discover proposes for vitest and jest reports a suite that didn't load, and vitest an error after a test ended, each under its own id — catches either failure absorbed with the base's failing test",
    arguments: [
      (
        "vitest", packageJSON(script: "vitest run"), "build-fail",
        ["test/alpha.test.js.alpha > flaky", "test/beta.test.js.new", "test/broken.test.js"]
      ),
      (
        "vitest", packageJSON(script: "vitest run"), "unhandled",
        [
          "test/alpha.test.js.alpha > flaky",
          "vitest unhandled errors.Uncaught Exception: thrown after the test ended",
        ]
      ),
      (
        "jest", packageJSON(script: "jest", jestJUnit: true), "build-fail",
        ["alpha flaky", " new", "Test suite failed to run.test/broken.test.js"]
      ),
    ])
  func failuresOutsideTestsGetIDs(
    runner: String, manifest: String, caseName: String, failing: [String]
  ) throws {
    let area = try #require(propose(["package.json": manifest, "package-lock.json": "{}"]).first)
    #expect(area.commands[.test]?.value == (try capturedCommand("\(runner)/\(caseName)")))
    #expect(BaselineStepResult.of(try capturedRun(runner, caseName)) == .failedTests(Set(failing)))
  }

  @Test(
    "a test_files command keeps its selection after the report request — catches files passed where a flag's value goes"
  )
  func testFilesKeepTheirSelection() throws {
    let python = try #require(propose(["pyproject.toml": pyproject]).first)
    #expect(python.commands[.testFiles]?.value == "python -m pytest --junitxml={junit} {files}")
    let vitest = try #require(
      propose(["package.json": packageJSON(script: "vitest run"), "package-lock.json": "{}"])
        .first)
    #expect(
      vitest.commands[.testFiles]?.value
        == "npm run test -- --reporter=default --reporter=junit --outputFile.junit={junit} {files}")
    let cargo = try #require(propose(["Cargo.toml": "[package]\nname = \"cargobase\"\n"]).first)
    #expect(cargo.commands[.testFiles]?.value == "cargo test --no-fail-fast -- {tests}")
    let swift = try #require(
      propose(["Package.swift": "let package = Package(targets: [.testTarget(name: \"T\")])\n"])
        .first)
    #expect(
      swift.commands[.testFiles]?.value
        == "swift test --parallel --xunit-output {junit} --filter {tests}")
  }

  @Test(
    "a runner asks for a report only when the repository has the reporter and a manager a run proved — catches a jest or RSpec run broken by a reporter that isn't installed, or a yarn script handed npm's flags",
    arguments: [
      (
        ["package.json": packageJSON(script: "jest"), "package-lock.json": "{}"],
        ["package.json": packageJSON(script: "jest", jestJUnit: true), "package-lock.json": "{}"],
        "jest"
      ),
      (
        ["package.json": packageJSON(script: "vitest run"), "yarn.lock": ""],
        ["package.json": packageJSON(script: "vitest run"), "package-lock.json": "{}"], "vitest"
      ),
      (
        ["Gemfile": "gem \"rspec\"\n", "spec/alpha_spec.rb": ""],
        ["Gemfile": gemfile, "spec/alpha_spec.rb": ""], "ruby"
      ),
    ])
  func asksOnlyWithAProvenReporter(
    without: [String: String], with: [String: String], runner: String
  ) throws {
    let plain = try #require(propose(without).first?.commands[.test]?.value)
    #expect(["npm run test", "yarn run test", "bundle exec rspec"].contains(plain))
    #expect(
      propose(with).first?.commands[.test]?.value
        == (try capturedCommand("\(runner)/baseline-head")))
  }

  @Test(
    "a command already naming its report, or chaining several, is left as the repository wrote it, while its plain form asks — catches a second report flag or a report collected from the wrong command",
    arguments: [
      ("pytest --junitxml=out.xml", "pytest", "pytest --junitxml={junit}"),
      (
        "swift test --xunit-output out.xml", "swift test",
        "swift test --parallel --xunit-output {junit}"
      ),
      ("make build && pytest", "pytest", "pytest --junitxml={junit}"),
      (
        "cd core && mvn test", "mvn test",
        "mkdir -p {junit} && mvn test; status=$?; find . -path '*/target/surefire-reports/*'"
          + " -name 'TEST-*.xml' -newer {junit} -exec cp {} {junit} ';'; exit $status"
      ),
    ])
  func ownCommandsStay(own: String, plain: String, asking: String) throws {
    #expect(proposeOne(own) == own)
    #expect(proposeOne(plain) == asking)
  }
}

/// The test command discover proposes for 1 area whose reader found `command`.
private func proposeOne(_ command: String) -> String? {
  Discover.propose(
    tree: TrackedTreeSnapshot(files: [:]), head: "abc", dirty: [],
    readers: [OneArea(command: command)]
  ).areas.first?.commands[.test]?.value
}

/// 1 area whose test step runs `command`.
private struct OneArea: EcosystemReader {
  let command: String

  func areas(in tree: TrackedTreeSnapshot) -> [ProposedArea] {
    [
      ProposedArea(
        name: "core", root: ".", language: .python, kind: .python, source: "pyproject.toml",
        commands: [.test: Sourced(value: command, source: "pyproject.toml", confidence: .found)],
        missing: [:], testGlobs: [], xcode: nil, generatedProjectTracked: nil)
    ]
  }
}
