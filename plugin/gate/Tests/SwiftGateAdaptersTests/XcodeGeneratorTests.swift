import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Synchronization
import Testing

@Suite("XcodeGenerator")
struct XcodeGeneratorTests {
  private static let xcodegenRoot = "Tests/Fixtures/SPM"
  private static let tuistRoot = "examples/xcode/generated_app_with_framework_and_tests"

  /// Runs `git` for real, so scratch worktrees are real, and replays a generator's captured run.
  /// A replayed generate writes the captured project into its working directory, as the tool does.
  private final class ReplayRunner: ProcessRunner {
    struct Replay: Sendable {
      var status: Int32
      var stdout: String
      var stderr: String
      var writes: [String: Data] = [:]
    }

    private let git: any ProcessRunner
    private let replays: [[String]: Replay]
    private let recorded = Mutex<[ProcessInvocation]>([])

    init(git: any ProcessRunner, replays: [[String]: Replay]) {
      self.git = git
      self.replays = replays
    }

    var generatorInvocations: [ProcessInvocation] {
      recorded.withLock { $0 }.filter { $0.executable != "git" }
    }

    func run(_ invocation: ProcessInvocation) async throws(ProcessRunnerError) -> ProcessOutput {
      if invocation.executable == "git" { return try await git.run(invocation) }
      recorded.withLock { $0.append(invocation) }
      let argv = [invocation.executable] + invocation.arguments
      guard let replay = replays[argv] else {
        throw .launchFailed(executable: invocation.executable, reason: "no replay for \(argv)")
      }
      if let directory = invocation.workingDirectory {
        for (path, data) in replay.writes {
          let url = URL(filePath: directory).appending(path: path)
          try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
          try? data.write(to: url)
        }
      }
      return ProcessOutput(
        status: .exited(replay.status), stdout: replay.stdout, stderr: replay.stderr)
    }
  }

  private static func replay(_ base: String, writes: [String: Data] = [:]) throws
    -> ReplayRunner.Replay
  {
    let status = try Fixture.text("Xcode/\(base).status")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return ReplayRunner.Replay(
      status: Int32(status) ?? -1, stdout: try Fixture.text("Xcode/\(base).stdout"),
      stderr: try Fixture.text("Xcode/\(base).stderr"), writes: writes)
  }

  private static func xcodegenReplays() throws -> [[String]: ReplayRunner.Replay] {
    let generated = try Fixture.data("Xcode/xcodegen/generated/SPM.xcodeproj/project.pbxproj")
    return [
      ["/usr/bin/env", "xcodegen", "--version"]: try replay("xcodegen/xcodegen-version"),
      ["/usr/bin/env", "xcodegen", "generate"]: try replay(
        "xcodegen/xcodegen-generate", writes: ["SPM.xcodeproj/project.pbxproj": generated]),
    ]
  }

  private static func tuistReplays() throws -> [[String]: ReplayRunner.Replay] {
    let generated = try Fixture.data("Xcode/tuist/generated/App.xcodeproj/project.pbxproj")
    return [
      ["/usr/bin/env", "tuist", "version"]: try replay("tuist/tuist-version"),
      ["/usr/bin/env", "tuist", "generate", "--no-open"]: try replay(
        "tuist/tuist-generate", writes: ["App.xcodeproj/project.pbxproj": generated]),
    ]
  }

  /// The captured XcodeGen case committed in a temp clone, its generated project tracked.
  private static func xcodegenClone(pin: (file: String, text: String)?) async throws
    -> TemporaryGitRepository
  {
    let repository = try await TemporaryGitRepository()
    for path in ["project.yml", "SPM.xcodeproj/project.pbxproj"] {
      try repository.write(
        "\(xcodegenRoot)/\(path)",
        try Fixture.text("Xcode/xcodegen/tree/\(xcodegenRoot)/\(path)"))
    }
    if let pin { try repository.write(pin.file, pin.text) }
    _ = try await repository.commitAll("base")
    return repository
  }

  private static func layout(_ repository: TemporaryGitRepository) -> BrownfieldStateLayout {
    let gitDir = repository.root.appending(path: ".git", directoryHint: .isDirectory)
    return BrownfieldStateLayout(commonDir: gitDir, gitDir: gitDir)
  }

  @Test(
    "a tracked generated project generates in a scratch tree under the git dir and leaves the user's tree clean — catches a generate in place"
  )
  func trackedProjectGeneratesInScratch() async throws {
    let repository = try await Self.xcodegenClone(
      pin: (".mise.toml", "[tools]\nxcodegen = \"2.45.3\"\n"))
    defer { repository.remove() }
    let layout = Self.layout(repository)
    let runner = ReplayRunner(git: repository.runner, replays: try Self.xcodegenReplays())
    let generator = XcodeGenerator(
      runner: runner, repositoryRoot: repository.root, layout: layout)

    let outcome = await generator.generate(
      XcodeGenerateRequest(
        tool: .xcodegen, manifest: "\(Self.xcodegenRoot)/project.yml",
        generatedProjectTracked: true)
    ) { generation in
      FileManager.default.fileExists(
        atPath: generation.tree.appending(
          path: "\(Self.xcodegenRoot)/SPM.xcodeproj/project.pbxproj"
        ).path)
    }

    guard case .generated(let generation, let projectExisted) = outcome else {
      Issue.record("expected a generation, got \(outcome)")
      return
    }
    #expect(projectExisted)
    #expect(generation.location == .scratch)
    #expect(generation.installed == "2.45.3")
    #expect(generation.pin == XcodeGeneratorPin(version: "2.45.3", source: ".mise.toml"))
    #expect(generation.output.contains("Created project at"))
    let scratch = layout.scratchDirectory.standardizedFileURL.path
    #expect(generation.tree.standardizedFileURL.path.hasPrefix(scratch))
    let generate = runner.generatorInvocations.last
    #expect(generate?.arguments == ["xcodegen", "generate"])
    #expect(generate?.workingDirectory?.hasPrefix(scratch) == true)
    #expect(generate?.workingDirectory?.hasSuffix(Self.xcodegenRoot) == true)
    #expect(try await repository.git("status", "--porcelain", "--ignored").isEmpty)
    #expect(!FileManager.default.fileExists(atPath: generation.tree.path))
  }

  @Test(
    "a gitignored generated project generates in the user's tree — catches a scratch tree that drops the project the build needs"
  )
  func ignoredProjectGeneratesInPlace() async throws {
    let repository = try await TemporaryGitRepository()
    defer { repository.remove() }
    try repository.write(
      "\(Self.tuistRoot)/.gitignore",
      try Fixture.text("Xcode/tuist/tree/\(Self.tuistRoot)/.gitignore"))
    try repository.write(
      "\(Self.tuistRoot)/Project.swift",
      try Fixture.text("Xcode/tuist/tree/\(Self.tuistRoot)/Project.swift.txt"))
    _ = try await repository.commitAll("base")
    let runner = ReplayRunner(git: repository.runner, replays: try Self.tuistReplays())
    let generator = XcodeGenerator(
      runner: runner, repositoryRoot: repository.root, layout: Self.layout(repository))

    func config(_ inclusion: XcodeInclusion, manifest: String?) -> XcodeAreaConfig {
      XcodeAreaConfig(
        workspace: "\(Self.tuistRoot)/App.xcworkspace", project: nil, inclusion: inclusion,
        manifest: manifest, schemes: [])
    }
    for inclusion in [XcodeInclusion.synchronized, .explicit] {
      #expect(
        XcodeGenerateRequest(
          xcode: config(inclusion, manifest: "\(Self.tuistRoot)/Project.swift"),
          generatedProjectTracked: false) == nil)
    }
    #expect(
      XcodeGenerateRequest(xcode: config(.tuist, manifest: nil), generatedProjectTracked: false)
        == nil)
    let request = try #require(
      XcodeGenerateRequest(
        xcode: config(.tuist, manifest: "\(Self.tuistRoot)/Project.swift"),
        generatedProjectTracked: false))

    let outcome = await generator.generate(request) { $0.tree.standardizedFileURL.path }

    guard case .generated(let generation, let tree) = outcome else {
      Issue.record("expected a generation, got \(outcome)")
      return
    }
    #expect(generation.location == .inPlace)
    #expect(generation.installed == "4.210.0")
    #expect(generation.pin == nil)
    #expect(tree == repository.root.standardizedFileURL.path)
    #expect(
      runner.generatorInvocations.last?.workingDirectory
        == repository.root.appending(path: Self.tuistRoot).path)
    #expect(
      FileManager.default.fileExists(
        atPath: repository.root.appending(path: "\(Self.tuistRoot)/App.xcodeproj/project.pbxproj")
          .path))
  }

  @Test(
    "a generator missing from PATH is notInstalled with the launch's own message and never generates — catches a silent skip or a generate attempt"
  )
  func missingToolIsNotInstalled() async throws {
    let repository = try await Self.xcodegenClone(pin: nil)
    defer { repository.remove() }
    for tool in XcodeGeneratorTool.allCases {
      let versionArgv =
        tool == .xcodegen
        ? ["/usr/bin/env", "xcodegen", "--version"] : ["/usr/bin/env", "tuist", "version"]
      let runner = ReplayRunner(
        git: repository.runner,
        replays: [versionArgv: try Self.replay("\(tool.rawValue)/not-installed")])
      let generator = XcodeGenerator(
        runner: runner, repositoryRoot: repository.root, layout: Self.layout(repository))
      let message = try Fixture.text("Xcode/\(tool.rawValue)/not-installed.stderr")
        .trimmingCharacters(in: .whitespacesAndNewlines)

      let outcome = await generator.generate(
        XcodeGenerateRequest(
          tool: tool, manifest: "\(Self.xcodegenRoot)/project.yml",
          generatedProjectTracked: false)
      ) { _ in true }

      #expect(outcome == .notInstalled(tool: tool, message: message))
      #expect(runner.generatorInvocations.map(\.arguments) == [Array(versionArgv.dropFirst())])
    }
  }

  @Test(
    "an installed version other than the pin is a versionMismatch naming both, and never generates — catches a mismatched generator rewriting the project"
  )
  func versionMismatchNamesBoth() async throws {
    let repository = try await Self.xcodegenClone(pin: ("Mintfile", "yonaskolb/XcodeGen@2.38.0\n"))
    defer { repository.remove() }
    let runner = ReplayRunner(git: repository.runner, replays: try Self.xcodegenReplays())
    let generator = XcodeGenerator(
      runner: runner, repositoryRoot: repository.root, layout: Self.layout(repository))

    let outcome = await generator.generate(
      XcodeGenerateRequest(
        tool: .xcodegen, manifest: "\(Self.xcodegenRoot)/project.yml",
        generatedProjectTracked: true)
    ) { _ in true }

    #expect(
      outcome
        == .versionMismatch(
          tool: .xcodegen, pinned: XcodeGeneratorPin(version: "2.38.0", source: "Mintfile"),
          installed: "2.45.3"))
    #expect(!runner.generatorInvocations.contains { $0.arguments.contains("generate") })
  }

  @Test(
    "the pin comes from the nearest Mintfile, mise config, .tool-versions or Package.resolved at or above the manifest — catches a pin file ignored or a farther pin winning"
  )
  func pinReadsEachFormatNearestFirst() {
    let manifest = "ios/App/project.yml"
    func pin(_ files: [String: String], tool: XcodeGeneratorTool = .xcodegen)
      -> XcodeGeneratorPin?
    {
      XcodeGenerator.pin(for: tool, manifest: manifest) { files[$0].map { Data($0.utf8) } }
    }

    #expect(
      pin(["Mintfile": "realm/SwiftLint@0.57.0\nyonaskolb/XcodeGen@2.42.0\n"])
        == XcodeGeneratorPin(version: "2.42.0", source: "Mintfile"))
    #expect(
      pin(["ios/.tool-versions": "nodejs 20.1.0\nxcodegen v2.43.0\n"])
        == XcodeGeneratorPin(version: "2.43.0", source: "ios/.tool-versions"))
    #expect(
      pin([
        "mise.toml": "[env]\nxcodegen = \"9\"\n[tools]\n\"aqua:yonaskolb/XcodeGen\" = \"2.44.0\"\n"
      ])
        == XcodeGeneratorPin(version: "2.44.0", source: "mise.toml"))
    #expect(
      pin(["ios/App/.mise.toml": "[tools]\ntuist = \"4.210.0\"\n"], tool: .tuist)
        == XcodeGeneratorPin(version: "4.210.0", source: "ios/App/.mise.toml"))
    #expect(
      pin([
        "ios/Package.resolved":
          #"{"pins":[{"identity":"xcodegen","state":{"version":"2.41.0"}}],"version":2}"#
      ]) == XcodeGeneratorPin(version: "2.41.0", source: "ios/Package.resolved"))
    #expect(
      pin([
        "Mintfile": "yonaskolb/XcodeGen@2.30.0\n",
        "ios/App/Mintfile": "yonaskolb/XcodeGen@2.45.3\n",
      ])
        == XcodeGeneratorPin(version: "2.45.3", source: "ios/App/Mintfile"))
    #expect(pin(["Mintfile": "yonaskolb/XcodeGen@2.42.0\n"], tool: .tuist) == nil)
    #expect(pin([".mise.toml": "[tools]\ntuist = \"4.210.0\"\n"]) == nil)
  }

  @Test(
    "a project.yaml spec is named with --spec — catches XcodeGen looking for a project.yml that isn't there"
  )
  func yamlSpecIsNamed() async throws {
    let repository = try await Self.xcodegenClone(pin: nil)
    defer { repository.remove() }
    var replays = try Self.xcodegenReplays()
    replays[["/usr/bin/env", "xcodegen", "generate", "--spec", "project.yaml"]] =
      replays[["/usr/bin/env", "xcodegen", "generate"]]
    let runner = ReplayRunner(git: repository.runner, replays: replays)
    let generator = XcodeGenerator(
      runner: runner, repositoryRoot: repository.root, layout: Self.layout(repository))

    let outcome = await generator.generate(
      XcodeGenerateRequest(
        tool: .xcodegen, manifest: "\(Self.xcodegenRoot)/project.yaml",
        generatedProjectTracked: false)
    ) { _ in true }

    guard case .generated = outcome else {
      Issue.record("expected a generation, got \(outcome)")
      return
    }
    #expect(
      runner.generatorInvocations.last?.arguments
        == ["xcodegen", "generate", "--spec", "project.yaml"])
  }

  @Test(
    "a generate that exits nonzero, a version the tool doesn't print, a launch failure and a scratch tree outside git each stop before the body — catches a failed generate reported as generated"
  )
  func failuresStopBeforeTheBody() async throws {
    let repository = try await Self.xcodegenClone(pin: nil)
    defer { repository.remove() }
    let version = try Self.replay("xcodegen/xcodegen-version")
    let request = XcodeGenerateRequest(
      tool: .xcodegen, manifest: "\(Self.xcodegenRoot)/project.yml",
      generatedProjectTracked: false)
    func outcome(
      _ replays: [[String]: ReplayRunner.Replay], root: URL? = nil, tracked: Bool = false
    )
      async -> XcodeGenerateOutcome<Bool>
    {
      let runner = ReplayRunner(git: repository.runner, replays: replays)
      let generator = XcodeGenerator(
        runner: runner, repositoryRoot: root ?? repository.root,
        layout: Self.layout(repository))
      return await generator.generate(
        XcodeGenerateRequest(
          tool: request.tool, manifest: request.manifest, generatedProjectTracked: tracked)
      ) { _ in true }
    }

    let failing = ReplayRunner.Replay(status: 1, stdout: "", stderr: "")
    #expect(
      await outcome([
        ["/usr/bin/env", "xcodegen", "--version"]: version,
        ["/usr/bin/env", "xcodegen", "generate"]: failing,
      ]) == .failed(tool: .xcodegen, status: .exited(1), output: ""))

    guard case .failed = await outcome([["/usr/bin/env", "xcodegen", "--version"]: failing])
    else {
      Issue.record("a failing version query must be a failure")
      return
    }
    let silent = ReplayRunner.Replay(status: 0, stdout: "", stderr: "")
    guard case .failed = await outcome([["/usr/bin/env", "xcodegen", "--version"]: silent])
    else {
      Issue.record("a version the tool didn't print must be a failure")
      return
    }
    guard case .blocked = await outcome([:]) else {
      Issue.record("a launch failure must block")
      return
    }

    let outside = FileManager.default.temporaryDirectory
      .appending(path: "swiftgate-nogit-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: outside) }
    let runner = ReplayRunner(
      git: repository.runner, replays: [["/usr/bin/env", "xcodegen", "--version"]: version])
    let generator = XcodeGenerator(
      runner: runner, repositoryRoot: outside, layout: Self.layout(repository))
    let scratchless = await generator.generate(
      XcodeGenerateRequest(
        tool: .xcodegen, manifest: request.manifest, generatedProjectTracked: true)
    ) { _ in true }
    guard case .blocked = scratchless else {
      Issue.record("a scratch tree that can't be made must block, got \(scratchless)")
      return
    }
    #expect(!runner.generatorInvocations.contains { $0.arguments.contains("generate") })
  }
}
