import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Synchronization
import Testing

@testable import SwiftGateCLI

/// Answers with facts read from recorded tool output; git hooks count as installed once
/// `installGitHooks` has run, as they do after a real `lefthook install`.
private final class FakeBootstrapProbe: BootstrapProbe {
  let isRepository: Bool
  private let version: String?
  private let listing: SchemeListing
  private let recordedDevices: [SimulatorDevice]
  private let installs = Mutex(0)

  private init(
    isRepository: Bool, version: String?, listing: SchemeListing, devices: [SimulatorDevice]
  ) {
    self.isRepository = isRepository
    self.version = version
    self.listing = listing
    recordedDevices = devices
  }

  static func make(isRepository: Bool = true) async throws -> FakeBootstrapProbe {
    let devices = try Fixture.text("Simctl/list-devices.stdout")
    let runner = FakeProcessRunner { _ throws(ProcessRunnerError) in
      ProcessOutput(status: .exited(0), stdout: devices)
    }
    return FakeBootstrapProbe(
      isRepository: isRepository,
      version: Doctor.xcodeVersion(from: try Fixture.text("Doctor/xcodebuild-version.txt")),
      listing: try SchemeListing.decode(Fixture.data("Bootstrap/xcodebuild-list-project.json")),
      devices: try await LiveSimctl(runner: runner).devices())
  }

  var installCount: Int { installs.withLock { $0 } }

  func xcodeVersion() async -> String? { version }

  func devices() async -> [SimulatorDevice] { recordedDevices }

  func schemes(root: URL, container: String) async -> SchemeListing? {
    container == "SampleApp.xcodeproj" ? listing : nil
  }

  func git(root: URL) async -> GitState {
    isRepository ? .repository(prefix: "", hooksInstalled: installCount > 0) : .notRepository
  }

  func installGitHooks(root: URL) async throws(BootstrapError) {
    installs.withLock { $0 += 1 }
  }
}

@Suite("swiftgate bootstrap")
struct BootstrapCommandTests {
  private struct Sandbox {
    let repository: URL
    let home: URL
    let probe: FakeBootstrapProbe

    init(copyingSampleApp: Bool, probe: FakeBootstrapProbe) throws {
      let base = FileManager.default.temporaryDirectory
        .appending(path: "swiftgate-bootstrap-\(UUID().uuidString)", directoryHint: .isDirectory)
        .resolvingSymlinksInPath()
      repository = base.appending(path: "repo", directoryHint: .isDirectory)
      home = base.appending(path: "home", directoryHint: .isDirectory)
      self.probe = probe
      try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
      if copyingSampleApp {
        try Self.copySources(
          from: Fixture.harnessCheckout.appending(path: "examples/SampleApp"), to: repository)
      } else {
        let package = repository.appending(path: "Packages/Core")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try Data("// swift-tools-version: 6.2\n".utf8).write(
          to: package.appending(path: "Package.swift"))
      }
    }

    /// The sample app's sources only: build output and run artifacts stay behind.
    private static func copySources(from source: URL, to destination: URL) throws {
      let manager = FileManager.default
      let skipped: Set<String> = [".harness", "DerivedData", ".build", ".swiftpm", "xcuserdata"]
      guard
        let walker = manager.enumerator(
          at: source, includingPropertiesForKeys: [.isDirectoryKey])
      else { throw CocoaError(.fileReadUnknown) }
      try manager.createDirectory(at: destination, withIntermediateDirectories: true)
      for case let url as URL in walker {
        if skipped.contains(url.lastPathComponent) {
          walker.skipDescendants()
          continue
        }
        let relative = String(url.path.dropFirst(source.path.count + 1))
        let target = destination.appending(path: relative)
        if (try url.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true {
          try manager.createDirectory(at: target, withIntermediateDirectories: true)
        } else {
          try manager.copyItem(at: url, to: target)
        }
      }
    }

    var environment: BootstrapRun.Environment {
      BootstrapRun.Environment(
        home: home, harnessRoot: Fixture.checkoutRoot, probe: probe, swiftLintInstalled: false,
        lefthookInstalled: true)
    }

    func remove() {
      try? FileManager.default.removeItem(at: repository.deletingLastPathComponent())
    }

    /// Every path under the repository and the home directory, with file contents or link
    /// destinations, to prove what a run did or did not touch.
    func state() throws -> [String: String] {
      var state: [String: String] = [:]
      for base in [repository, home] {
        let manager = FileManager.default
        for relative in try manager.subpathsOfDirectory(atPath: base.path) {
          let path = base.appending(path: relative).path
          let key = "\(base.lastPathComponent)/\(relative)"
          if let destination = try? manager.destinationOfSymbolicLink(atPath: path) {
            state[key] = "-> \(destination)"
          } else if let data = manager.contents(atPath: path) {
            state[key] = String(decoding: data, as: UTF8.self)
          } else {
            state[key] = "dir"
          }
        }
      }
      return state
    }
  }

  @Test(
    "a dry run writes nothing, in the repository or the home directory, and shows the diff — catches a preview that already changed the repository"
  )
  func dryRunWritesNothing() async throws {
    let sandbox = try Sandbox(copyingSampleApp: true, probe: try await FakeBootstrapProbe.make())
    defer { sandbox.remove() }
    let before = try sandbox.state()

    let outcome = await BootstrapRun.run(
      root: sandbox.repository, apply: false, environment: sandbox.environment)

    #expect(try sandbox.state() == before)
    #expect(sandbox.probe.installCount == 0)
    #expect(!outcome.failed)
    #expect(outcome.text.contains("+++ b/lefthook.yml"))
    #expect(outcome.text.contains("CLAUDE.md -> AGENTS.md (new symlink)"))
    #expect(outcome.text.hasSuffix("Re-run with --apply to write it."))
  }

  @Test(
    "bootstrapping a copy of the sample app twice changes nothing the second time — catches a non-idempotent bootstrap that churns files, registry or hooks"
  )
  func applyTwiceIsNoOp() async throws {
    let sandbox = try Sandbox(copyingSampleApp: true, probe: try await FakeBootstrapProbe.make())
    defer { sandbox.remove() }
    let config = try String(
      contentsOf: sandbox.repository.appending(path: Config.fileName), encoding: .utf8)

    let first = await BootstrapRun.run(
      root: sandbox.repository, apply: true, environment: sandbox.environment)
    let afterFirst = try sandbox.state()
    let second = await BootstrapRun.run(
      root: sandbox.repository, apply: true, environment: sandbox.environment)

    #expect(!first.failed && !second.failed)
    #expect(second.plan?.isNoOp == true)
    #expect(try sandbox.state() == afterFirst)
    #expect(sandbox.probe.installCount == 1)
    #expect(afterFirst["repo/\(Config.fileName)"] == config)
    #expect(afterFirst["repo/CLAUDE.md"] == "-> AGENTS.md")
    #expect(
      afterFirst["home/.local/bin/swiftgate"]
        == "-> \(Fixture.checkoutRoot.appending(path: "bin/swiftgate").path)")
    let registry = try ProjectRegistry.decode(
      Data((afterFirst["home/\(ProjectRegistry.path)"] ?? "").utf8))
    #expect(registry.projects == [sandbox.repository.path])
    #expect(afterFirst["repo/.gitignore"]?.contains("**/.harness/runs/") == true)
  }

  @Test(
    "the stamped .gitignore ignores SwiftPM build directories — catches `git add -A` staging the gigabytes every gated `swift test` leaves in each package"
  )
  func gitignoreCoversBuildDirectories() async throws {
    let sandbox = try Sandbox(
      copyingSampleApp: false, probe: try await FakeBootstrapProbe.make(isRepository: false))
    defer { sandbox.remove() }

    let outcome = await BootstrapRun.run(
      root: sandbox.repository, apply: true, environment: sandbox.environment)

    #expect(!outcome.failed)
    let lines = try sandbox.state()["repo/.gitignore"]?.split(separator: "\n") ?? []
    #expect(lines.contains(".build/"))
  }

  @Test(
    "the stamped .gitignore ignores the rendered design pages — catches a design commit that stages the page design-render writes for publishing"
  )
  func gitignoreCoversDesignRender() async throws {
    let sandbox = try Sandbox(
      copyingSampleApp: false, probe: try await FakeBootstrapProbe.make(isRepository: false))
    defer { sandbox.remove() }

    let outcome = await BootstrapRun.run(
      root: sandbox.repository, apply: true, environment: sandbox.environment)

    #expect(!outcome.failed)
    let lines = try sandbox.state()["repo/.gitignore"]?.split(separator: "\n") ?? []
    #expect(lines.contains("**/.harness/design-render/"))
  }

  @Test(
    "a fresh repository gets a config inferred from it that the gate can load — catches a first bootstrap that leaves every check RED on its own config"
  )
  func freshRepositoryConfigLoads() async throws {
    let sandbox = try Sandbox(
      copyingSampleApp: false, probe: try await FakeBootstrapProbe.make(isRepository: false))
    defer { sandbox.remove() }

    let outcome = await BootstrapRun.run(
      root: sandbox.repository, apply: true, environment: sandbox.environment)

    #expect(!outcome.failed)
    let config = try #require(try ConfigLoader().load(repositoryRoot: sandbox.repository))
    #expect(config.packages == ["Packages/Core"])
    #expect(config.xcode == "26.2")
    #expect(config.simulator == SimulatorConfig(device: "iPhone 17", os: "26.2"))
    #expect(config.appScheme == InferredConfig.placeholder)
    #expect(outcome.text.contains("not a git repository"))
    #expect(sandbox.probe.installCount == 0)
  }

  @Test(
    "bootstrap --profile interview stamps profile = \"interview\" into a config the gate loads, and no flag stamps default — catches the flag dropped between the command and the stamped file"
  )
  func profileIsStamped() async throws {
    for (profile, expected) in [("interview", "interview"), (nil, "default")] as [(String?, String)]
    {
      let sandbox = try Sandbox(
        copyingSampleApp: false, probe: try await FakeBootstrapProbe.make(isRepository: false))
      defer { sandbox.remove() }

      let outcome = await BootstrapRun.run(
        root: sandbox.repository, apply: true, profile: profile, environment: sandbox.environment)

      #expect(!outcome.failed)
      let text = try sandbox.state()["repo/\(Config.fileName)"] ?? ""
      #expect(text.contains("[harness]\nprofile = \"\(expected)\"\n"))
      let config = try? ConfigLoader().load(repositoryRoot: sandbox.repository)
      #expect(config?.profile == expected)
      #expect(config?.buildPresets[expected] != nil)
    }
  }

  @Test(
    "missing templates stop bootstrap before anything is written — catches a half-stamped repository from a broken plugin install"
  )
  func missingTemplates() async throws {
    let sandbox = try Sandbox(copyingSampleApp: false, probe: try await FakeBootstrapProbe.make())
    defer { sandbox.remove() }
    let before = try sandbox.state()
    var environment = sandbox.environment
    environment.harnessRoot = sandbox.home

    let outcome = await BootstrapRun.run(
      root: sandbox.repository, apply: true, environment: environment)

    #expect(outcome.failed)
    #expect(outcome.text.contains("template templates/AGENTS.md is missing"))
    #expect(try sandbox.state() == before)
  }

  @Test(
    "the docs a fresh bootstrap stamps pass its own docs-lint and prose — catches a new repository whose first push fails on the harness's words"
  )
  func stampedDocsPassDocsGates() async throws {
    let sandbox = try Sandbox(
      copyingSampleApp: false, probe: try await FakeBootstrapProbe.make(isRepository: false))
    defer { sandbox.remove() }
    let outcome = await BootstrapRun.run(
      root: sandbox.repository, apply: true, environment: sandbox.environment)
    #expect(!outcome.failed)
    let runner = LiveProcessRunner(baseEnvironment: [
      "PATH": "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin",
      "HOME": sandbox.home.path, "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
    ])
    for arguments in [["init", "-q", "-b", "main"], ["add", "-A"]] {
      let git = try await runner.run(
        ProcessInvocation(
          executable: "git", arguments: arguments, workingDirectory: sandbox.repository.path,
          timeout: .seconds(30)))
      #expect(git.status.isSuccess, "git \(arguments): \(git.stderr.text)")
    }

    let outcomes = [
      await DocsLintCheck.run(root: sandbox.repository, runner: runner),
      ProseCheck.run(root: sandbox.repository, files: ["AGENTS.md", "docs/index.md"]),
    ]

    for checked in outcomes {
      guard case .checked(let result) = checked else {
        Issue.record("not checked: \(checked)")
        continue
      }
      let gating = result.findings.filter { $0.severity.lintLevel == .error }
      #expect(gating.isEmpty, "\(gating.map { "\($0.file) \($0.ruleID): \($0.message)" })")
    }
  }
}
