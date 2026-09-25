import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@Suite("bootstrap adapters")
struct BootstrapAdaptersTests {
  private func scratch() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appending(path: "swiftgate-bootstrap-\(UUID().uuidString)", directoryHint: .isDirectory)
      .resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func git(_ arguments: [String], in directory: URL) async throws {
    let output = try await LiveProcessRunner().run(
      ProcessInvocation(
        executable: "git", arguments: arguments, workingDirectory: directory.path,
        timeout: .seconds(30)))
    #expect(output.status.isSuccess, "git \(arguments) failed: \(output.stderr.text)")
  }

  @Test(
    "schemes, the Xcode version and devices are read from real tool output — catches bootstrap inferring a config from misparsed xcodebuild or simctl output"
  )
  func probeParsesRealOutput() async throws {
    let listingOutput = try Fixture.text("Bootstrap/xcodebuild-list-project.json")
    let missingOutput = try Fixture.text("Bootstrap/xcodebuild-list-missing.stderr")
    let versionOutput = try Fixture.text("Doctor/xcodebuild-version.txt")
    let devicesOutput = try Fixture.text("Simctl/list-devices.stdout")
    let runner = FakeProcessRunner { invocation throws(ProcessRunnerError) in
      let arguments = invocation.arguments
      if arguments.starts(with: ["xcodebuild", "-list"]) {
        return arguments.last == "SampleApp.xcodeproj"
          ? ProcessOutput(status: .exited(0), stdout: listingOutput)
          : ProcessOutput(status: .exited(66), stderr: missingOutput)
      }
      if arguments == ["xcodebuild", "-version"] {
        return ProcessOutput(status: .exited(0), stdout: versionOutput)
      }
      return ProcessOutput(status: .exited(0), stdout: devicesOutput)
    }
    let probe = LiveBootstrapProbe(runner: runner)
    let root = URL(filePath: "/w")

    let listing = await probe.schemes(root: root, container: "SampleApp.xcodeproj")
    #expect(listing?.schemes.contains("SampleApp") == true)
    #expect(listing?.targets == ["SampleApp", "SampleAppUITests"])
    #expect(await probe.schemes(root: root, container: "Missing.xcodeproj") == nil)
    #expect(
      runner.invocations.first?.arguments == [
        "xcodebuild", "-list", "-json", "-project", "SampleApp.xcodeproj",
      ])
    #expect(runner.invocations.first?.workingDirectory == "/w")
    #expect(await probe.xcodeVersion() == "26.2")
    let inferred = ConfigInference.infer(
      RepositorySurvey(
        packageDirectories: [], schemes: nil, xcodeVersion: nil, devices: await probe.devices()))
    #expect(inferred.simulator == InferredSimulator(device: "iPhone 17", os: "26.4"))
  }

  @Test(
    "package discovery finds the sample app's packages and skips build output and hidden directories — catches a config globbing DerivedData checkouts as project packages"
  )
  func packageDiscovery() throws {
    let sample = Fixture.checkoutRoot.appending(path: "examples/SampleApp")
    #expect(
      BootstrapFiles.packageDirectories(root: sample)
        == Fixture.samplePackages.map { "Packages/\($0)" })

    let root = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    for directory in ["DerivedData/SourcePackages/checkouts/Dep", ".build/Dep", "App/Core"] {
      let url = root.appending(path: directory)
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
      try Data().write(to: url.appending(path: "Package.swift"))
    }
    #expect(BootstrapFiles.packageDirectories(root: root) == ["App/Core"])
  }

  @Test(
    "the plugin's templates load and the rendered config passes the real config loader — catches a template edit that makes every fresh bootstrap RED"
  )
  func templatesRenderLoadableConfig() throws {
    let templates = try BootstrapFiles.templates(harnessRoot: Fixture.checkoutRoot)
    let root = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let inferred = ConfigInference.infer(
      RepositorySurvey(
        packageDirectories: ["Packages/A", "Packages/B"], schemes: nil, xcodeVersion: "26.2",
        devices: []))
    try Data(inferred.render(template: templates.config).utf8).write(
      to: root.appending(path: Config.fileName))

    let config = try #require(try ConfigLoader().load(repositoryRoot: root))
    #expect(config.packages == ["Packages/*"])
    #expect(config.appScheme == InferredConfig.placeholder)
    #expect(throws: BootstrapError.missingTemplate(path: "templates/AGENTS.md")) {
      try BootstrapFiles.templates(harnessRoot: root)
    }
  }

  @Test(
    "git state tells a toplevel, a nested project and a non-repository apart — catches lefthook installed from a subdirectory or outside git"
  )
  func gitState() async throws {
    let root = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let probe = LiveBootstrapProbe(runner: LiveProcessRunner())
    #expect(await probe.git(root: root) == .notRepository)

    try await git(["init", "-q"], in: root)
    let nested = root.appending(path: "apps/ios")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    #expect(await probe.git(root: root) == .repository(prefix: "", hooksInstalled: false))
    #expect(
      await probe.git(root: nested) == .repository(prefix: "apps/ios/", hooksInstalled: false))
  }

  @Test(
    "lefthook install with the shipped template installs both hooks the planner checks for — catches bootstrap reinstalling hooks forever or never",
    .enabled(
      if: HarnessFiles.isOnPath("lefthook", path: ProcessInfo.processInfo.environment["PATH"] ?? "")
    )
  )
  func lefthookInstall() async throws {
    let root = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    try await git(["init", "-q"], in: root)
    let templates = try BootstrapFiles.templates(harnessRoot: Fixture.checkoutRoot)
    try Data(templates.lefthook.utf8).write(to: root.appending(path: "lefthook.yml"))
    let probe = LiveBootstrapProbe(runner: LiveProcessRunner())

    try await probe.installGitHooks(root: root)

    #expect(await probe.git(root: root) == .repository(prefix: "", hooksInstalled: true))
  }

  @Test(
    "applying stamps writes files and a relative CLAUDE.md link, and the shim link replaces only a symlink — catches bootstrap deleting a user's own swiftgate binary"
  )
  func applyWrites() throws {
    let root = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    try BootstrapFiles.apply(
      [
        Stamp(path: ".harness/plans/index.json", change: .create("{}\n")),
        Stamp(path: "CLAUDE.md", change: .link(destination: "AGENTS.md")),
        Stamp(path: "left.txt", change: .untouched(advice: "x")),
      ], root: root)
    #expect(BootstrapFiles.entry(root: root, path: ".harness/plans/index.json") == .file("{}\n"))
    #expect(
      BootstrapFiles.entry(root: root, path: "CLAUDE.md") == .symlink(destination: "AGENTS.md"))
    #expect(BootstrapFiles.entry(root: root, path: "left.txt") == .absent)

    let shim = root.appending(path: "home/.local/bin/swiftgate").path
    try BootstrapFiles.apply(.linkShim(path: shim, target: "/old"))
    try BootstrapFiles.apply(.linkShim(path: shim, target: "/new"))
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: shim) == "/new")

    let regular = root.appending(path: "regular").path
    try Data("binary".utf8).write(to: URL(filePath: regular))
    #expect(throws: BootstrapError.self) {
      try BootstrapFiles.apply(.linkShim(path: regular, target: "/new"))
    }
    #expect(FileManager.default.contents(atPath: regular) == Data("binary".utf8))
  }
}
