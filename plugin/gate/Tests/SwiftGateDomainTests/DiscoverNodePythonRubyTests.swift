import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

/// A captured `F/Discover/<owner>-<repo>/` repository as discover sees it: its listing, and the
/// bytes of each signal file read on demand.
private func fixtureTree(_ name: String, listing: String = "ls-files.txt") throws
  -> TrackedTreeSnapshot
{
  let directory = Fixture.directory.appending(path: "Discover/\(name)", directoryHint: .isDirectory)
  let text = try String(contentsOf: directory.appending(path: listing), encoding: .utf8)
  let tree = directory.appending(path: "tree", directoryHint: .isDirectory)
  return TrackedTreeSnapshot(
    paths: text.split(separator: "\n").map(String.init),
    read: { try? Data(contentsOf: tree.appending(path: $0)) })
}

/// 1 command as a test states it: its value and confidence, and the file it must name when the
/// source matters to the case.
private struct Expected: Sendable, Equatable, CustomStringConvertible {
  let value: String
  let confidence: Confidence
  let source: String?

  var description: String { "\(value) (\(confidence.rawValue)\(source.map { ", \($0)" } ?? ""))" }
}

private func found(_ value: String, from source: String? = nil) -> Expected {
  Expected(value: value, confidence: .found, source: source)
}

private func guessed(_ value: String, from source: String? = nil) -> Expected {
  Expected(value: value, confidence: .guessed, source: source)
}

/// What 1 area of a fixture must propose: every command exactly, and which steps are missing.
private struct ExpectedArea: Sendable {
  let root: String
  let name: String
  let language: AreaLanguage
  let kind: AreaKind
  let commands: [AreaStep: Expected]
  let missing: Set<AreaStep>
}

private struct FixtureCase: Sendable, CustomTestStringConvertible {
  let fixture: String
  let reader: @Sendable () -> any EcosystemReader
  let areas: [ExpectedArea]

  var testDescription: String { fixture }
}

private func node(
  _ root: String, _ name: String, _ language: AreaLanguage,
  _ commands: [AreaStep: Expected], missing: Set<AreaStep> = []
) -> ExpectedArea {
  ExpectedArea(
    root: root, name: name, language: language, kind: .node, commands: commands, missing: missing)
}

private func python(
  _ root: String, _ name: String, _ commands: [AreaStep: Expected], missing: Set<AreaStep> = []
) -> ExpectedArea {
  ExpectedArea(
    root: root, name: name, language: .python, kind: .python, commands: commands,
    missing: missing)
}

private func ruby(
  _ root: String, _ name: String, _ commands: [AreaStep: Expected], missing: Set<AreaStep> = []
) -> ExpectedArea {
  ExpectedArea(
    root: root, name: name, language: .ruby, kind: .command, commands: commands, missing: missing)
}

private let ruffInPolars = found(
  "python -m ruff check {files}", from: "py-polars/pyproject.toml")

private let cases: [FixtureCase] = [
  FixtureCase(
    fixture: "tauri-apps-tauri", reader: { NodeReader() },
    areas: [
      node(
        "crates/tauri-schema-worker", "tauri-schema-worker", .javascript, [:],
        missing: [.test, .lint]),
      node(
        "examples/api", "api", .typescript, [.build: found("pnpm run build")],
        missing: [
          .test, .lint,
        ]),
      node(
        "examples/file-associations", "file-associations", .javascript, [:],
        missing: [.test, .lint]),
      node("examples/resources", "resources", .javascript, [:], missing: [.test, .lint]),
      node(
        "packages/api", "api", .typescript,
        [
          .lint: guessed("pnpm exec eslint {files}", from: "packages/api/eslint.config.js"),
          .build: found("pnpm run build", from: "packages/api/package.json"),
        ], missing: [.test]),
      node("packages/api-e2e", "api-e2e", .typescript, [:], missing: [.test, .lint]),
      node(
        "packages/cli", "cli", .javascript,
        [
          .test: found("pnpm run test", from: "packages/cli/package.json"),
          .testFiles: guessed("pnpm run test {files}"),
          .build: found("pnpm run build"),
        ], missing: [.lint]),
    ]),
  FixtureCase(
    fixture: "pocketbase-pocketbase", reader: { NodeReader() },
    areas: [
      node("ui", "ui", .javascript, [.build: found("npm run build")], missing: [.test, .lint])
    ]),
  FixtureCase(
    fixture: "jhipster-jhipster-sample-app", reader: { NodeReader() },
    areas: [
      node(
        ".", "node", .typescript,
        [
          .test: guessed("npm run test", from: "package.json"),
          .lint: guessed("npm run lint"), .build: guessed("npm run build"),
        ])
    ]),
  FixtureCase(
    fixture: "mitmproxy-mitmproxy", reader: { NodeReader() },
    areas: [
      node(
        "web", "web", .typescript,
        [
          .test: found("npm run test", from: "web/package.json"),
          .lint: guessed("npx eslint {files}", from: "web/eslint.config.mjs"),
        ])
    ]),
  FixtureCase(
    fixture: "phoenixframework-phoenix", reader: { NodeReader() },
    areas: [
      node(
        ".", "node", .javascript,
        [
          .test: found("npm run test"), .testFiles: guessed("npm run test -- {files}"),
          .lint: guessed("npx eslint {files}", from: "eslint.config.mjs"),
        ])
    ]),
  FixtureCase(
    fixture: "ggml-org-llama.cpp", reader: { NodeReader() },
    areas: [
      node(
        "tools/ui", "ui", .typescript,
        [
          .test: found("npm run test"), .lint: found("npm run lint", from: "tools/ui/package.json"),
          .build: found("npm run build"),
        ])
    ]),
  FixtureCase(
    fixture: "hotwired-turbo-rails", reader: { NodeReader() },
    areas: [
      node(".", "node", .javascript, [.build: found("yarn run build")], missing: [.test, .lint])
    ]),
  FixtureCase(
    fixture: "mitmproxy-mitmproxy", reader: { PythonReader() },
    areas: [
      python(
        ".", "python",
        [
          .test: found("uv run pytest", from: "pyproject.toml"),
          .testFiles: found("uv run pytest {files}"),
          .lint: found("uv run ruff check {files}", from: "pyproject.toml"),
        ])
    ]),
  FixtureCase(
    fixture: "pola-rs-polars", reader: { PythonReader() },
    areas: [
      python(
        "py-polars", "py-polars",
        [
          .test: found("python -m pytest", from: "py-polars/pyproject.toml"),
          .testFiles: found("python -m pytest {files}"), .lint: ruffInPolars,
        ]),
      python(
        "py-polars/runtime/polars-runtime-32", "polars-runtime-32", [.lint: ruffInPolars],
        missing: [.test]),
      python(
        "py-polars/runtime/polars-runtime-64", "polars-runtime-64", [.lint: ruffInPolars],
        missing: [.test]),
      python(
        "py-polars/runtime/polars-runtime-compat", "polars-runtime-compat",
        [.lint: ruffInPolars], missing: [.test]),
    ]),
  FixtureCase(
    fixture: "ggml-org-llama.cpp", reader: { PythonReader() },
    areas: [
      python(
        ".", "python",
        [
          .test: found("python -m pytest", from: "pyproject.toml"),
          .testFiles: found("python -m pytest {files}"),
          .lint: found("python -m flake8 {files}", from: ".flake8"),
        ]),
      python(
        "gguf-py", "gguf-py",
        [
          .test: found("python -m pytest", from: "gguf-py/pyproject.toml"),
          .testFiles: found("python -m pytest {files}"),
          .lint: found("python -m flake8 {files}", from: ".flake8"),
        ]),
    ]),
  FixtureCase(
    fixture: "hotwired-turbo-rails", reader: { RubyReader() },
    areas: [
      ruby(
        ".", "ruby",
        [
          .test: found("bundle exec rake test", from: "Rakefile"),
          .testFiles: guessed("bin/rails test {files}", from: "bin/rails"),
        ], missing: [.lint])
    ]),
  FixtureCase(
    fixture: "Alamofire-Alamofire", reader: { RubyReader() },
    areas: [ruby(".", "ruby", [:], missing: [.test, .lint])]),
  FixtureCase(
    fixture: "Shopify-mobile-buy-sdk-ios", reader: { RubyReader() },
    areas: [
      ruby(".", "ruby", [:], missing: [.test, .lint]),
      ruby(
        "Dependencies/Swift Gen", "Swift Gen",
        [.test: found("bundle exec rake test", from: "Dependencies/Swift Gen/Rakefile")],
        missing: [.lint]),
    ]),
]

@Suite("discover reads node, python and ruby")
struct DiscoverNodePythonRubyTests {
  @Test(
    "each captured fixture yields exactly its areas, commands and confidences — catches a reader tuned to 1 repository",
    arguments: cases)
  fileprivate func fixtureAreas(_ testCase: FixtureCase) throws {
    let tree = try fixtureTree(testCase.fixture)

    let areas = testCase.reader().areas(in: tree)

    #expect(areas.map(\.root) == testCase.areas.map(\.root))
    for expected in testCase.areas {
      let area = try #require(areas.first { $0.root == expected.root }, "\(expected.root)")
      #expect(area.name == expected.name, "\(expected.root)")
      #expect(area.language == expected.language, "\(expected.root)")
      #expect(area.kind == expected.kind, "\(expected.root)")
      #expect(Set(area.commands.keys) == Set(expected.commands.keys), "\(expected.root)")
      for (step, command) in expected.commands {
        let actual = area.commands[step]
        #expect(actual?.value == command.value, "\(expected.root) \(step)")
        #expect(actual?.confidence == command.confidence, "\(expected.root) \(step)")
        if let source = command.source {
          #expect(actual?.source == source, "\(expected.root) \(step)")
        }
      }
      #expect(Set(area.missing.keys) == expected.missing, "\(expected.root)")
    }
  }

  @Test(
    "a package.json with no test script yields missing test and no guessed npm test — catches a convention guess standing in for a script"
  )
  func noTestScriptIsMissing() throws {
    let tree = try fixtureTree("pocketbase-pocketbase")

    let ui = try #require(NodeReader().areas(in: tree).first { $0.root == "ui" })

    #expect(ui.commands[.test] == nil)
    #expect(ui.commands[.testFiles] == nil)
    #expect(ui.missing[.test] == "no test script in ui/package.json")
  }

  @Test(
    "after npm ci the node area is the same and nothing under node_modules becomes one — catches a reader that walks the disk or reads untracked files"
  )
  func afterBuildMatchesTracked() throws {
    let before = try fixtureTree("phoenixframework-phoenix")
    let after = try fixtureTree("phoenixframework-phoenix", listing: "after-build/ls-files.txt")
    let status = try Fixture.text(
      "Discover/phoenixframework-phoenix/after-build/status-ignored.txt")
    #expect(status.contains("!! node_modules/"))

    let areas = NodeReader().areas(in: after)

    #expect(areas == NodeReader().areas(in: before))
    #expect(areas.map(\.root) == ["."])
    #expect(!areas.contains { $0.root.split(separator: "/").contains("node_modules") })
  }

  @Test(
    "a tracked package under node_modules, a fixture or a template is never an area, and a nested package.json with no name or scripts belongs to its parent — catches vendored and sample packages read as the repository's own"
  )
  func vendoredAndSamplePackagesAreSkipped() {
    let manifest = Data(#"{"name":"x","scripts":{"test":"jest"}}"#.utf8)
    let tree = TrackedTreeSnapshot(files: [
      "package.json": manifest,
      "package-lock.json": Data(),
      "src/package.json": Data(#"{"type":"module"}"#.utf8),
      "node_modules/left-pad/package.json": manifest,
      "test/fixtures/app/package.json": manifest,
      "templates/plugin/package.json": manifest,
    ])

    let areas = NodeReader().areas(in: tree)

    #expect(areas.map(\.root) == ["."])
    #expect(areas.first?.commands[.testFiles]?.value == "npm run test -- {files}")
  }

  @Test(
    "a test script that is npm init's placeholder is missing, not found — catches a test step that always fails"
  )
  func placeholderTestScriptIsMissing() {
    let tree = TrackedTreeSnapshot(files: [
      "package.json": Data(
        #"{"name":"x","scripts":{"test":"echo \"Error: no test specified\" && exit 1"}}"#.utf8)
    ])

    let area = NodeReader().areas(in: tree).first

    #expect(area?.commands[.test] == nil)
    #expect(area?.missing[.test] == "the test script in package.json is npm's placeholder")
  }

  @Test(
    "an npm or yarn workspaces field makes each matched package an area and the root none — catches a monorepo read as 1 package"
  )
  func workspacesFieldMembers() {
    let tree = TrackedTreeSnapshot(files: [
      "package.json": Data(
        #"{"name":"root","workspaces":{"packages":["apps/*","libs/core"]},"scripts":{"test":"turbo test"}}"#
          .utf8),
      "yarn.lock": Data(),
      "apps/web/package.json": Data(#"{"name":"web","scripts":{"test":"vitest"}}"#.utf8),
      "apps/web/tsconfig.json": Data(),
      "libs/core/package.json": Data(#"{"name":"core","scripts":{"lint":"eslint ."}}"#.utf8),
      "libs/extra/package.json": Data(#"{"name":"extra","scripts":{"test":"jest"}}"#.utf8),
    ])

    let areas = NodeReader().areas(in: tree)

    #expect(areas.map(\.root) == ["apps/web", "libs/core"])
    #expect(areas.first?.language == .typescript)
    #expect(areas.first?.commands[.test]?.value == "yarn run test")
    #expect(areas.first?.commands[.testFiles]?.value == "yarn run test {files}")
    #expect(areas.last?.commands[.lint]?.value == "yarn run lint")
    #expect(areas.first?.testGlobs.allSatisfy { $0.hasPrefix("apps/web/") } == true)
  }

  @Test(
    "a pyproject.toml holding only tool settings is not an area, and setup.cfg metadata is — catches a lint config read as a project"
  )
  func pythonProjectsNeedMetadata() throws {
    let polars = try fixtureTree("pola-rs-polars")
    #expect(!PythonReader().areas(in: polars).contains { $0.root == "docs/source" })

    let tree = TrackedTreeSnapshot(files: [
      "lib/setup.cfg": Data("[metadata]\nname = lib\n\n[tool:pytest]\ntestpaths = tests\n".utf8),
      "lib/tests/test_core.py": Data(),
      "tools/pyproject.toml": Data("[tool.black]\nline-length = 100\n".utf8),
    ])

    let areas = PythonReader().areas(in: tree)

    #expect(areas.map(\.root) == ["lib"])
    #expect(
      areas.first?.commands[.test]
        == Sourced(value: "python -m pytest", source: "lib/setup.cfg", confidence: .found))
    #expect(areas.first?.testGlobs.contains("lib/**/test_*.py") == true)
  }

  @Test(
    "a Python project with tests but no pytest configuration guesses pytest — catches a project with tests left untested"
  )
  func pythonTestsWithoutConfigAreGuessed() {
    let tree = TrackedTreeSnapshot(files: [
      "pyproject.toml": Data("[project]\nname = \"x\"\n".utf8),
      "poetry.lock": Data(),
      "tests/test_x.py": Data(),
    ])

    let area = PythonReader().areas(in: tree).first

    #expect(
      area?.commands[.test]
        == Sourced(value: "poetry run pytest", source: "pyproject.toml", confidence: .guessed))
  }

  @Test(
    "a Gemfile root with specs runs RSpec and a .rubocop.yml adds RuboCop — catches a reader that only knows Minitest"
  )
  func rspecAndRubocop() {
    let tree = TrackedTreeSnapshot(files: [
      "Gemfile": Data("source 'https://rubygems.org'\ngem 'rails'\n".utf8),
      ".rspec": Data("--require spec_helper\n".utf8),
      ".rubocop.yml": Data("AllCops:\n  NewCops: enable\n".utf8),
      "spec/models/user_spec.rb": Data(),
      "vendor/bundle/gems/x/Gemfile": Data(),
    ])

    let areas = RubyReader().areas(in: tree)

    #expect(areas.map(\.root) == ["."])
    let area = areas.first
    #expect(
      area?.commands[.test]
        == Sourced(value: "bundle exec rspec", source: ".rspec", confidence: .found))
    #expect(area?.commands[.testFiles]?.value == "bundle exec rspec {files}")
    #expect(
      area?.commands[.lint]
        == Sourced(
          value: "bundle exec rubocop {files}", source: ".rubocop.yml", confidence: .found))
    #expect(area?.testGlobs == ["spec/**/*_spec.rb"])
  }
}
