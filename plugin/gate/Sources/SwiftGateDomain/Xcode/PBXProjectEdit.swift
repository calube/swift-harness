/// Why a file couldn't be added to a project.
public enum PBXProjectEditError: Error, Sendable, Equatable {
  case unparsable(PBXProjectError)
  case targetNotFound(String, known: [String])
  case noSourcesPhase(target: String)
  /// The extension isn't 1 a Sources phase compiles.
  case notASourceFile(String)
  /// No group of the project holds the path's folder or any folder above it.
  case outsideProject(String)
  /// The text around an object the edit touches isn't laid out the way Xcode writes it, so it
  /// can't be edited without rewriting it.
  case unrecognizedLayout(String)
}

/// The objects 1 add created or extended.
public struct PBXAddedFile: Sendable, Equatable {
  public let fileReferenceID: String
  public let buildFileID: String
  /// The group the file reference joined; `nil` when an existing reference was reused.
  public let groupID: String?
  public let sourcesPhaseID: String

  public init(
    fileReferenceID: String, buildFileID: String, groupID: String?, sourcesPhaseID: String
  ) {
    self.fileReferenceID = fileReferenceID
    self.buildFileID = buildFileID
    self.groupID = groupID
    self.sourcesPhaseID = sourcesPhaseID
  }
}

public enum PBXAddFileResult: Sendable, Equatable {
  /// `text` is the whole edited `project.pbxproj`.
  case added(PBXAddedFile, text: String)
  /// The target already compiles the path, explicitly or through a synchronized folder.
  case alreadyCompiled
}

/// Adds 1 source file to 1 target of a `project.pbxproj` by inserting lines, so every byte the
/// edit doesn't need stays as it was.
public enum PBXProjectEdit {
  /// - Parameters:
  ///   - path: repository-relative.
  ///   - projectPath: the `.xcodeproj` directory, repository-relative.
  public static func addFile(
    _ path: String, target: String, projectPath: String, to text: String
  ) throws(PBXProjectEditError) -> PBXAddFileResult {
    .alreadyCompiled
  }

  /// A 24-digit uppercase hex object id derived from `kind`, `path` and `target` only.
  public static func stableID(_ kind: String, path: String, target: String) -> String {
    ""
  }
}
