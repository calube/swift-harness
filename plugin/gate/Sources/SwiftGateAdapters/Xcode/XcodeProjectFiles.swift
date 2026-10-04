import Foundation
import SwiftGateDomain

/// What 1 add to a project on disk came to.
public enum XcodeAddFileOutcome: Sendable, Equatable {
  case added(PBXAddedFile)
  case alreadyCompiled
  case refused(PBXProjectEditError)
  /// A check of the edited project failed, and the original bytes are back on disk.
  case checkFailed(command: String, status: ExitStatus, output: String)
  /// The project couldn't be read, written or restored.
  case io(String)
}

/// Reads, edits and checks the `project.pbxproj` of an `.xcodeproj` in a repository.
public struct XcodeProjectFiles: Sendable {
  private let runner: any ProcessRunner
  private let repositoryRoot: URL
  private let timeout: Duration

  public init(
    runner: any ProcessRunner = LiveProcessRunner(), repositoryRoot: URL,
    timeout: Duration = .seconds(120)
  ) {
    self.runner = runner
    self.repositoryRoot = repositoryRoot
    self.timeout = timeout
  }

  /// Adds `path` to `target`, then checks the project with `plutil -lint` and `xcodebuild -list`.
  /// A failed check puts the original bytes back.
  public func addFile(_ path: String, target: String, projectPath: String) async
    -> XcodeAddFileOutcome
  {
    let pbxproj = projectPath + "/project.pbxproj"
    let file = repositoryRoot.appending(path: pbxproj)
    guard let original = FileManager.default.contents(atPath: file.path) else {
      return .io("\(pbxproj) can't be read")
    }
    let edit: PBXAddFileResult
    do {
      edit = try PBXProjectEdit.addFile(
        path, target: target, projectPath: projectPath,
        to: String(decoding: original, as: UTF8.self))
    } catch {
      return .refused(error)
    }
    guard case .added(let added, let text) = edit else { return .alreadyCompiled }
    do {
      try Data(text.utf8).write(to: file, options: .atomic)
    } catch {
      return .io("writing \(pbxproj): \(error)")
    }
    let checks: [(String, String, [String])] = [
      ("plutil -lint", "/usr/bin/plutil", ["-lint", pbxproj]),
      ("xcodebuild -list", "xcodebuild", ["-list", "-json", "-project", projectPath]),
    ]
    for (command, executable, arguments) in checks {
      let failure: (ExitStatus, String)?
      do {
        let output = try await runner.run(
          ProcessInvocation(
            executable: executable, arguments: arguments,
            workingDirectory: repositoryRoot.path, timeout: timeout))
        failure =
          output.status.isSuccess
          ? nil
          : (
            output.status,
            (output.stdout.text + output.stderr.text)
              .trimmingCharacters(in: .whitespacesAndNewlines)
          )
      } catch {
        failure = (.exited(-1), "\(error)")
      }
      guard let (status, output) = failure else { continue }
      do {
        try original.write(to: file, options: .atomic)
      } catch {
        return .io("\(command) failed and \(pbxproj) wasn't restored: \(error)")
      }
      return .checkFailed(command: command, status: status, output: output)
    }
    return .added(added)
  }

  /// The names of the targets of the project at `projectPath` under `tree` that compile `path`;
  /// `nil` when the project can't be read.
  public static func targets(compiling path: String, projectPath: String, in tree: URL)
    -> [String]?
  {
    guard
      let data = FileManager.default.contents(
        atPath: tree.appending(path: projectPath + "/project.pbxproj").path),
      let project = try? PBXProject(parsing: String(decoding: data, as: UTF8.self))
    else { return nil }
    return TargetMembership(project: project, projectPath: projectPath)
      .targets(compiling: path).map(\.name)
  }
}
