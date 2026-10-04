import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain

/// `swiftgate xcode`: edits to an Xcode project the harness doesn't own.
struct XcodeCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "xcode",
    abstract: "Add files to Xcode targets without restructuring the project.",
    subcommands: [XcodeAddFileCommand.self])
}

/// `swiftgate xcode add-file <path> --target <t>`: joins 1 file to 1 target the way the area's
/// inclusion kind says.
struct XcodeAddFileCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "add-file",
    abstract: "Add a source file to an Xcode target.")

  @Argument(help: "The file, repository-relative.")
  var path: String

  @Option(help: "The target that compiles it.")
  var target: String

  @Flag(help: "Print JSON.")
  var json = false

  /// The inputs a test replaces.
  struct Dependencies: Sendable {
    var processRunner: any ProcessRunner = LiveProcessRunner()
  }

  /// What the command did. `project` is the `.xcodeproj`, repository-relative.
  enum Outcome: Sendable, Equatable {
    case added(project: String, PBXAddedFile, note: String?)
    case alreadyCompiled(project: String)
    /// The target's synchronized folder takes the file in: nothing to write.
    case synchronized(project: String?)
    /// The generator ran and its project compiles the file in the target.
    case regenerated(project: String, tool: XcodeGeneratorTool)
  }

  /// Why nothing was added; `verdict` picks the exit code.
  struct Failure: Error, Sendable, Equatable {
    let message: String
    let verdict: Verdict
  }

  /// Joins `path` to `target` in the clone holding `directory`.
  static func addFile(
    directory: URL, path: String, target: String, dependencies: Dependencies
  ) async throws(Failure) -> Outcome {
    throw Failure(message: "xcode add-file: not implemented yet", verdict: .blocked)
  }

  func run() async throws {
    try StubCommand.notImplemented("xcode add-file", json: json)
  }
}
