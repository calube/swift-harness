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
  public func addFile(_ path: String, target: String, projectPath: String) async
    -> XcodeAddFileOutcome
  {
    .io("not implemented")
  }

  /// The names of the targets of the project at `projectPath` under `tree` that compile `path`;
  /// `nil` when the project can't be read.
  public static func targets(compiling path: String, projectPath: String, in tree: URL)
    -> [String]?
  {
    nil
  }
}
