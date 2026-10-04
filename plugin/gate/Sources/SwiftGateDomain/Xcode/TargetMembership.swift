/// A target as membership answers name it.
public struct XcodeTarget: Sendable, Hashable {
  public let name: String
  public let isTest: Bool

  public init(name: String, isTest: Bool) {
    self.name = name
    self.isTest = isTest
  }
}

/// Which targets of 1 Xcode project build a repository path, from the project's explicit build
/// phases and its synchronized folders. Paths are repository-relative.
public struct TargetMembership: Sendable {
  public let project: PBXProject
  /// The `.xcodeproj` directory, repository-relative, such as `ios/App.xcodeproj`.
  public let projectPath: String

  public init(project: PBXProject, projectPath: String) {
    self.project = project
    self.projectPath = projectPath
  }

  /// Targets whose Sources phase compiles the path, explicitly or through a synchronized folder.
  public func targets(compiling path: String) -> [XcodeTarget] { [] }

  /// Targets any of whose build phases hold the path, or whose synchronized folders take it in.
  public func targets(including path: String) -> [XcodeTarget] { [] }

  /// Folders that hold a file some target compiles, and every synchronized folder.
  public var sourceRoots: [String] { [] }

  /// `xcode.file-not-in-target` for each new Swift file under a source root that no target
  /// compiles. `inclusion` picks the remedy the message names.
  public func newFileFindings(
    _ newFiles: [String], inclusion: XcodeInclusion
  ) throws(ReportContractViolation) -> [Finding] { [] }
}
