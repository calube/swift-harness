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
    "a pnpm area passes the report flags without npm's separator, as the captured pnpm runs did — catches a separator the script receives as a test name",
    arguments: [
      ("vitest", packageJSON(script: "vitest run")),
      ("jest", packageJSON(script: "jest", jestJUnit: true)),
    ])
  func pnpmCommandsMatchCapturedRuns(runner: String, manifest: String) throws {
    let area = try #require(propose(["package.json": manifest, "pnpm-lock.yaml": ""]).first)
    #expect(area.commands[.test]?.value == (try capturedCommand("\(runner)/pnpm-head")))
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
    "a runner that can't write a report without a package the repository lacks keeps its command — catches a jest or RSpec run broken by a reporter that isn't installed",
    arguments: [
      ["package.json": packageJSON(script: "jest"), "package-lock.json": "{}"],
      ["package.json": packageJSON(script: "vitest run"), "yarn.lock": ""],
      ["Gemfile": "gem \"rspec\"\n", "spec/alpha_spec.rb": ""],
    ])
  func unprovenRunnersKeepTheirCommand(files: [String: String]) throws {
    let area = try #require(propose(files).first)
    let command = try #require(area.commands[.test]?.value)
    #expect(!command.contains(AreaCommandExpansion.junitPlaceholder))
    #expect(["npm run test", "yarn run test", "bundle exec rspec"].contains(command))
  }

  @Test(
    "a command already naming its report, or chaining several, is left as the repository wrote it — catches a second report flag or a report collected from the wrong command",
    arguments: [
      "pytest --junitxml=out.xml", "swift test --xunit-output out.xml",
      "make build && pytest", "cd core && mvn test",
    ])
  func ownCommandsStay(command: String) throws {
    let reader = OneArea(command: command)
    let area = try #require(
      Discover.propose(
        tree: TrackedTreeSnapshot(files: [:]), head: "abc", dirty: [], readers: [reader]
      )
      .areas.first)
    #expect(area.commands[.test]?.value == command)
  }
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
