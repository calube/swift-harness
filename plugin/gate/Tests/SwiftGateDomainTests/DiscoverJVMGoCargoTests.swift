import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

/// A captured `F/Discover/<owner>-<repo>/` repository: its listing, and each signal file's bytes.
private func capturedTree(_ name: String) throws -> TrackedTreeSnapshot {
  let directory = Fixture.directory.appending(path: "Discover/\(name)", directoryHint: .isDirectory)
  let listing = try String(contentsOf: directory.appending(path: "ls-files.txt"), encoding: .utf8)
  let tree = directory.appending(path: "tree", directoryHint: .isDirectory)
  return TrackedTreeSnapshot(
    paths: listing.split(separator: "\n").map(String.init),
    read: { try? Data(contentsOf: tree.appending(path: $0)) })
}

private func area(_ name: String, in areas: [ProposedArea]) throws -> ProposedArea {
  try #require(areas.first { $0.name == name }, "no area \(name) in \(areas.map(\.name))")
}

private func sourced(_ value: String, _ source: String, _ confidence: Confidence)
  -> Sourced<String>
{
  Sourced(value: value, source: source, confidence: confidence)
}

@Suite("discover reads JVM, Go, Cargo and command build files")
struct DiscoverJVMGoCargoTests {
  @Test(
    "every Cargo workspace member is 1 area run from its workspace by package name — catches a reader that sees only the root manifest"
  )
  func cargoWorkspaceMembers() throws {
    let tree = try capturedTree("tauri-apps-tauri")
    let areas = CargoReader().areas(in: tree)

    #expect(areas.count == 25)
    let tauri = try area("tauri", in: areas)
    #expect(tauri.root == "crates/tauri")
    #expect(tauri.kind == .cargo)
    #expect(tauri.language == .rust)
    #expect(tauri.source == "crates/tauri/Cargo.toml")
    #expect(
      tauri.commands[.test] == sourced("cargo test -p tauri", "crates/tauri/Cargo.toml", .found))
    #expect(
      tauri.commands[.testFiles]
        == sourced("cargo test -p tauri -- {tests}", "crates/tauri/Cargo.toml", .found))
    #expect(tauri.commands[.lint]?.value == "cargo clippy -p tauri")
    #expect(tauri.commands[.lint]?.confidence == .guessed)
    #expect(tauri.testGlobs == ["crates/tauri/tests/**/*.rs"])
    let sample = try area("tauri-plugin-sample", in: areas)
    #expect(sample.root == "examples/api/src-tauri/tauri-plugin-sample")
  }

  @Test(
    "a member glob and a clippy.toml above the crate are read — catches a literal-only members list and an unconfigured Clippy"
  )
  func cargoGlobMembersAndClippyConfig() throws {
    let tree = try capturedTree("pola-rs-polars")
    let areas = CargoReader().areas(in: tree)

    let core = try area("polars-core", in: areas)
    #expect(core.root == "crates/polars-core")
    #expect(core.commands[.test]?.value == "cargo test -p polars-core")
    #expect(
      core.commands[.lint] == sourced("cargo clippy -p polars-core", "crates/clippy.toml", .found))
    let packageManifests = tree.paths.filter {
      $0.hasSuffix("Cargo.toml")
        && String(decoding: tree.read($0) ?? Data(), as: UTF8.self).contains("[package]")
    }
    #expect(areas.count == packageManifests.count)
    #expect(Set(areas.map(\.name)).count == areas.count)
  }

  @Test(
    "a crate outside any workspace runs from its own directory — catches a standalone crate given a workspace's -p"
  )
  func cargoStandaloneCrate() {
    let tree = TrackedTreeSnapshot(files: [
      "tools/gen/Cargo.toml": Data("[package]\nname = \"gen\"\n".utf8)
    ])
    let gen = CargoReader().areas(in: tree)

    #expect(gen.map(\.name) == ["gen"])
    #expect(gen.first?.commands[.test]?.value == "cd tools/gen && cargo test")
    #expect(gen.first?.commands[.testFiles]?.value == "cd tools/gen && cargo test -- {tests}")
  }

  @Test(
    "a go.mod is 1 area named for its module, with golangci-lint pointed at the repository's config — catches a missing -run filter and a dropped linter config"
  )
  func goModule() throws {
    let tree = try capturedTree("pocketbase-pocketbase")
    let areas = GoReader().areas(in: tree)

    let module = try #require(areas.first)
    #expect(areas.count == 1)
    #expect(module.name == "pocketbase")
    #expect(module.root == ".")
    #expect(module.kind == .go)
    #expect(module.language == .go)
    #expect(module.commands[.test] == sourced("go test ./...", "go.mod", .found))
    #expect(module.commands[.testFiles] == sourced("go test ./... -run {tests}", "go.mod", .found))
    #expect(
      module.commands[.lint]
        == sourced("golangci-lint run -c golangci.yml ./...", "golangci.yml", .found))
    #expect(module.testGlobs == ["**/*_test.go"])
  }

  @Test(
    "a Go module with no linter config says lint is missing — catches a guessed golangci-lint"
  )
  func goWithoutLinter() {
    let tree = TrackedTreeSnapshot(files: [
      "svc/go.mod": Data("module example.com/org/svc/v2\n\ngo 1.22\n".utf8)
    ])
    let svc = GoReader().areas(in: tree)

    #expect(svc.map(\.name) == ["svc"])
    #expect(svc.first?.commands[.test]?.value == "cd svc && go test ./...")
    #expect(svc.first?.commands[.lint] == nil)
    #expect(svc.first?.missing[.lint] != nil)
  }

  @Test(
    "each included Gradle module is 1 area with the wrapper and its configured ktlint — catches the root project read as the only module"
  )
  func gradleModules() throws {
    let tree = try capturedTree("touchlab-KaMPKit")
    let areas = JVMReader().areas(in: tree)

    #expect(areas.map(\.name).sorted() == ["app", "shared"])
    let app = try area("app", in: areas)
    #expect(app.kind == .jvm)
    #expect(app.language == .kotlin)
    #expect(app.source == "app/build.gradle.kts")
    #expect(app.commands[.test]?.value == "./gradlew :app:testDebugUnitTest")
    #expect(app.commands[.testFiles]?.value == "./gradlew :app:testDebugUnitTest --tests {tests}")
    #expect(
      app.commands[.lint] == sourced("./gradlew :app:ktlintCheck", "build.gradle.kts", .found))
    let shared = try area("shared", in: areas)
    #expect(shared.commands[.test]?.value == "./gradlew :shared:allTests")
    #expect(shared.commands[.testFiles] == nil)
    #expect(shared.missing[.testFiles] != nil)
  }

  @Test(
    "a Gradle build without a wrapper runs gradle and says so in the source column — catches ./gradlew proposed where none is tracked"
  )
  func gradleWithoutWrapper() throws {
    let tree = try capturedTree("tauri-apps-tauri")
    let areas = JVMReader().areas(in: tree)

    let android = try #require(areas.first { $0.root == "crates/tauri/mobile/android" })
    let test = try #require(android.commands[.test])
    #expect(test.value.hasPrefix("cd crates/tauri/mobile/android && gradle "))
    #expect(test.source == "crates/tauri/mobile/android/build.gradle.kts (no Gradle wrapper)")
    #expect(test.confidence == .guessed)
    #expect(!areas.contains { $0.root.split(separator: "/").contains("templates") })
  }

  @Test(
    "a Maven project uses its wrapper, a test filter and its configured formatter — catches mvn proposed over a tracked mvnw"
  )
  func mavenProject() throws {
    let tree = try capturedTree("jhipster-jhipster-sample-app")
    let areas = JVMReader().areas(in: tree)

    #expect(areas.count == 1)
    let app = try area("jhipster-sample-application", in: areas)
    #expect(app.root == ".")
    #expect(app.language == .java)
    #expect(app.commands[.test] == sourced("./mvnw test", "pom.xml", .found))
    #expect(app.commands[.testFiles] == sourced("./mvnw test -Dtest={tests}", "pom.xml", .found))
    #expect(app.commands[.lint] == sourced("./mvnw spotless:check", "pom.xml", .found))
  }

  @Test(
    "each mix project is an area whose commands come from CI — catches a guessed command for a build file discover can't run"
  )
  func mixProjectsTakeCICommands() throws {
    let tree = try capturedTree("phoenixframework-phoenix")
    let raw = CommandReader().areas(in: tree)
    #expect(raw.allSatisfy { $0.commands.isEmpty && $0.missing[.test] != nil })

    let proposal = Discover.propose(tree: tree, head: "abc", dirty: [], readers: [CommandReader()])
    #expect(
      proposal.areas.map(\.name).sorted() == ["phoenix", "phoenix_integration", "phx_new"])
    let phoenix = try area("phoenix", in: proposal.areas)
    #expect(phoenix.kind == .command)
    #expect(phoenix.source == "mix.exs")
    #expect(phoenix.commands[.test] == sourced("mix test", ".github/workflows/ci.yml", .found))
    let installer = try area("phx_new", in: proposal.areas)
    #expect(installer.root == "installer")
    #expect(installer.commands[.test]?.value == "cd installer && mix test")
  }

  @Test(
    "nested CMakeLists.txt files join the topmost one's area — catches 1 area per add_subdirectory"
  )
  func cmakeTopmostOnly() throws {
    let tree = try capturedTree("ggml-org-llama.cpp")
    let areas = CommandReader().areas(in: tree)

    #expect(areas.count == 1)
    let llama = try #require(areas.first)
    #expect(llama.name == "llama.cpp")
    #expect(llama.root == ".")
    #expect(llama.source == "CMakeLists.txt")
    #expect(llama.language == .other)
  }
}
