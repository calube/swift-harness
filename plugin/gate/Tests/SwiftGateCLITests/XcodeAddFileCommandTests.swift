import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Synchronization
import Testing

@testable import SwiftGateCLI

@Suite("swiftgate xcode add-file")
struct XcodeAddFileCommandTests {
  static let projectPath = "ios/KaMPKitiOS.xcodeproj"
  static let pbxproj = projectPath + "/project.pbxproj"
  static let newFile = "ios/KaMPKitiOS/BreedDetailScreen.swift"

  /// Runs git and plutil for real and replays a captured `xcodebuild -list`, recording each argv.
  final class Runner: ProcessRunner {
    let listCapture: String
    let live = LiveProcessRunner()
    let calls = Mutex<[[String]]>([])

    init(listCapture: String) { self.listCapture = listCapture }

    func run(_ invocation: ProcessInvocation) async throws(ProcessRunnerError) -> ProcessOutput {
      calls.withLock { $0.append([invocation.executable] + invocation.arguments) }
      guard invocation.executable.hasSuffix("xcodebuild") else {
        return try await live.run(invocation)
      }
      let base = "Xcode/explicit/\(listCapture)"
      do {
        let status = try Fixture.text(base + ".status").trimmingCharacters(
          in: .whitespacesAndNewlines)
        return ProcessOutput(
          status: .exited(Int32(status) ?? -1), stdout: try Fixture.text(base + ".stdout"),
          stderr: try Fixture.text(base + ".stderr"))
      } catch {
        throw .launchFailed(executable: invocation.executable, reason: "\(error)")
      }
    }
  }

  static func config(inclusion: String) -> String {
    """
    schema = 1

    [harness]
    profile = "brownfield"

    [brownfield]
    discovered_at = "0123abcd"
    slice_budget_s = 30
    time_budget_min = 0

    [[areas]]
    name = "ios"
    root = "ios"
    language = "swift"
    kind = "xcode"
    build = "xcodebuild build -project ios/KaMPKitiOS.xcodeproj -scheme KaMPKitiOS"
    test_globs = []
    packs = []

    [areas.xcode]
    project = "ios/KaMPKitiOS.xcodeproj"
    inclusion = "\(inclusion)"
    schemes = ["KaMPKitiOS"]

    """
  }

  /// A clone with its own `.git`, holding the captured explicit project and a new Swift file.
  static func makeClone(inclusion: String = "explicit") async throws -> URL {
    let root = TestTemporaryDirectory.root
      .appending(path: "swiftgate-xcode-\(UUID().uuidString)", directoryHint: .isDirectory)
      .resolvingSymlinksInPath()
    let project = root.appending(path: projectPath, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    try Fixture.data("Xcode/explicit/tree/\(pbxproj)").write(
      to: root.appending(path: pbxproj))
    try FileManager.default.createDirectory(
      at: root.appending(path: "ios/KaMPKitiOS"), withIntermediateDirectories: true)
    try Data("struct BreedDetailScreen {}\n".utf8).write(to: root.appending(path: newFile))
    let git = try await LiveProcessRunner().run(
      ProcessInvocation(
        executable: "git", arguments: ["init", "-q"], workingDirectory: root.path,
        timeout: .seconds(30)))
    #expect(git.status.isSuccess)
    let state = root.appending(path: ".git/swift-harness", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
    try Data(config(inclusion: inclusion).utf8).write(to: state.appending(path: "config.toml"))
    return root
  }

  static func projectText(_ root: URL) throws -> String {
    try String(contentsOf: root.appending(path: pbxproj), encoding: .utf8)
  }

  @Test(
    "adding a new file to an explicit project writes a project the membership reader and plutil accept, then a second add is a no-op — catches an unchecked or repeated edit"
  )
  func addsThenNoOps() async throws {
    let root = try await Self.makeClone()
    defer { try? FileManager.default.removeItem(at: root) }
    let runner = Runner(listCapture: "xcodebuild-list")
    let dependencies = XcodeAddFileCommand.Dependencies(processRunner: runner)

    let outcome = try await XcodeAddFileCommand.addFile(
      directory: root, path: Self.newFile, target: "KaMPKitiOS", dependencies: dependencies)

    guard case .added(let project, let added, let note) = outcome else {
      Issue.record("expected an add, got \(outcome)")
      return
    }
    #expect(project == Self.projectPath)
    #expect(note == nil)
    let edited = try Self.projectText(root)
    #expect(edited.contains("\(added.buildFileID) /* BreedDetailScreen.swift in Sources */,"))
    let membership = TargetMembership(
      project: try PBXProject(parsing: edited), projectPath: Self.projectPath)
    #expect(membership.targets(compiling: Self.newFile).map(\.name) == ["KaMPKitiOS"])
    let calls = runner.calls.withLock { $0 }
    #expect(calls.contains(["/usr/bin/plutil", "-lint", Self.pbxproj]))
    #expect(calls.contains { $0.last == Self.projectPath && $0.contains("-list") })

    let again = try await XcodeAddFileCommand.addFile(
      directory: root, path: Self.newFile, target: "KaMPKitiOS", dependencies: dependencies)
    #expect(again == .alreadyCompiled(project: Self.projectPath))
    #expect(try Self.projectText(root) == edited)
  }

  @Test(
    "a project xcodebuild can't list after the edit is put back as it was and the add fails — catches a broken project left on disk"
  )
  func failedCheckRestores() async throws {
    let root = try await Self.makeClone()
    defer { try? FileManager.default.removeItem(at: root) }
    let original = try Self.projectText(root)

    await #expect {
      _ = try await XcodeAddFileCommand.addFile(
        directory: root, path: Self.newFile, target: "KaMPKitiOS",
        dependencies: .init(processRunner: Runner(listCapture: "xcodebuild-list-damaged")))
    } throws: { error in
      guard let failure = error as? XcodeAddFileCommand.Failure else { return false }
      return failure.verdict == .red && failure.message.contains("xcodebuild -list")
        && failure.message.contains("damaged")
    }
    #expect(try Self.projectText(root) == original)
  }

  @Test(
    "a synchronized area writes nothing and says the folder takes the file in — catches an explicit entry added beside the folder"
  )
  func synchronizedDoesNothing() async throws {
    let root = try await Self.makeClone(inclusion: "synchronized")
    defer { try? FileManager.default.removeItem(at: root) }
    let original = try Self.projectText(root)

    let outcome = try await XcodeAddFileCommand.addFile(
      directory: root, path: Self.newFile, target: "KaMPKitiOS",
      dependencies: .init(processRunner: Runner(listCapture: "xcodebuild-list")))

    #expect(outcome == .synchronized(project: Self.projectPath))
    #expect(try Self.projectText(root) == original)
  }

  @Test(
    "a file no Xcode area holds, or one that doesn't exist, fails naming it — catches an add to an unrelated project"
  )
  func refusesUnknownPaths() async throws {
    let root = try await Self.makeClone()
    defer { try? FileManager.default.removeItem(at: root) }
    for path in ["web/app.swift", "ios/KaMPKitiOS/Missing.swift"] {
      await #expect {
        _ = try await XcodeAddFileCommand.addFile(
          directory: root, path: path, target: "KaMPKitiOS",
          dependencies: .init(processRunner: Runner(listCapture: "xcodebuild-list")))
      } throws: { error in
        (error as? XcodeAddFileCommand.Failure)?.message.contains(path) == true
      }
    }
  }
}
