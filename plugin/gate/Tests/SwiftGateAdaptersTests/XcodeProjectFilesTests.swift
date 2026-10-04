import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@Suite("an Xcode project on disk takes an added file and is checked")
struct XcodeProjectFilesTests {
  static let projectPath = "ios/KaMPKitiOS.xcodeproj"
  static let pbxproj = projectPath + "/project.pbxproj"

  static func makeTree() throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "swiftgate-xcode-files-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: root.appending(path: projectPath), withIntermediateDirectories: true)
    try Fixture.data("Xcode/explicit/tree/\(pbxproj)").write(to: root.appending(path: pbxproj))
    return root
  }

  /// Replays the captured `plutil -lint` of `capture` and a passing `xcodebuild -list`.
  static func replaying(lint capture: String) -> FakeProcessRunner {
    FakeProcessRunner { invocation throws(ProcessRunnerError) in
      let base =
        invocation.executable.hasSuffix("plutil")
        ? "Xcode/explicit/plutil-lint-\(capture)" : "Xcode/explicit/xcodebuild-list"
      do {
        let status = try Fixture.text(base + ".status")
          .trimmingCharacters(in: .whitespacesAndNewlines)
        return ProcessOutput(
          status: .exited(Int32(status) ?? -1), stdout: try Fixture.text(base + ".stdout"),
          stderr: try Fixture.text(base + ".stderr"))
      } catch {
        throw .launchFailed(executable: invocation.executable, reason: "\(error)")
      }
    }
  }

  @Test(
    "a project plutil rejects after the edit gets its original bytes back and xcodebuild never runs — catches a damaged project left on disk"
  )
  func lintFailureRestores() async throws {
    let root = try Self.makeTree()
    defer { try? FileManager.default.removeItem(at: root) }
    let original = try Data(contentsOf: root.appending(path: Self.pbxproj))
    let runner = Self.replaying(lint: "damaged")

    let outcome = await XcodeProjectFiles(runner: runner, repositoryRoot: root).addFile(
      "ios/KaMPKitiOS/Extra.swift", target: "KaMPKitiOS", projectPath: Self.projectPath)

    guard case .checkFailed(let command, let status, let output) = outcome else {
      Issue.record("expected a failed check, got \(outcome)")
      return
    }
    #expect(command == "plutil -lint")
    #expect(status == .exited(1))
    #expect(output.contains("Unexpected character"))
    #expect(try Data(contentsOf: root.appending(path: Self.pbxproj)) == original)
    #expect(runner.invocations.map(\.executable) == ["/usr/bin/plutil"])
  }

  @Test(
    "a passing lint and list keep the edit and run plutil before xcodebuild — catches a check skipped"
  )
  func checksPassKeepEdit() async throws {
    let root = try Self.makeTree()
    defer { try? FileManager.default.removeItem(at: root) }
    let runner = Self.replaying(lint: "valid")

    let outcome = await XcodeProjectFiles(runner: runner, repositoryRoot: root).addFile(
      "ios/KaMPKitiOS/Extra.swift", target: "KaMPKitiOS", projectPath: Self.projectPath)

    guard case .added = outcome else {
      Issue.record("expected an add, got \(outcome)")
      return
    }
    #expect(
      runner.invocations.map { [$0.executable] + $0.arguments } == [
        ["/usr/bin/plutil", "-lint", Self.pbxproj],
        ["xcodebuild", "-list", "-json", "-project", Self.projectPath],
      ])
    #expect(
      XcodeProjectFiles.targets(
        compiling: "ios/KaMPKitiOS/Extra.swift", projectPath: Self.projectPath, in: root)
        == ["KaMPKitiOS"])
    #expect(
      XcodeProjectFiles.targets(
        compiling: "ios/KaMPKitiOS/Extra.swift", projectPath: "missing.xcodeproj", in: root)
        == nil)
  }

  @Test(
    "a missing project and an unknown target come back as their own outcomes with no tool run — catches a refusal reported as a check failure"
  )
  func unreadableAndRefused() async throws {
    let root = try Self.makeTree()
    defer { try? FileManager.default.removeItem(at: root) }
    let runner = Self.replaying(lint: "valid")
    let files = XcodeProjectFiles(runner: runner, repositoryRoot: root)

    #expect(
      await files.addFile(
        "ios/KaMPKitiOS/Extra.swift", target: "KaMPKitiOS", projectPath: "x.xcodeproj")
        == .io("x.xcodeproj/project.pbxproj can't be read"))
    let refused = await files.addFile(
      "ios/KaMPKitiOS/Extra.swift", target: "Widget", projectPath: Self.projectPath)
    #expect(
      refused
        == .refused(
          .targetNotFound("Widget", known: ["KaMPKitiOS", "KaMPKitiOSTests", "KaMPKitiOSUITests"])))
    #expect(runner.invocations.isEmpty)
  }

}
