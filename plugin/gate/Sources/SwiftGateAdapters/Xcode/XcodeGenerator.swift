import Foundation
import SwiftGateDomain

/// A tool that writes an Xcode project from a spec the repository commits.
public enum XcodeGeneratorTool: String, Sendable, Equatable, CaseIterable {
  case xcodegen
  case tuist

  /// `nil` for an inclusion whose project is edited, not generated.
  public init?(inclusion: XcodeInclusion) {
    return nil
  }
}

/// The generator version a repository asks for, and the file that asks.
public struct XcodeGeneratorPin: Sendable, Equatable {
  public let version: String
  /// Repository-relative.
  public let source: String

  public init(version: String, source: String) {
    self.version = version
    self.source = source
  }
}

/// 1 area's generate step.
public struct XcodeGenerateRequest: Sendable, Equatable {
  public let tool: XcodeGeneratorTool
  /// Repository-relative path of `project.yml` or `Project.swift`.
  public let manifest: String
  /// A committed generated project generates in a scratch tree, so the user's tree gets no diff.
  public let generatedProjectTracked: Bool

  public init(tool: XcodeGeneratorTool, manifest: String, generatedProjectTracked: Bool) {
    self.tool = tool
    self.manifest = manifest
    self.generatedProjectTracked = generatedProjectTracked
  }

  /// `nil` when the area has no generator or no manifest.
  public init?(xcode: XcodeAreaConfig, generatedProjectTracked: Bool) {
    return nil
  }
}

/// Where a generator wrote its project.
public enum XcodeGeneratedLocation: Sendable, Equatable {
  /// The user's tree: the generated project is gitignored.
  case inPlace
  /// A scratch worktree at `HEAD` under the git dir, removed once the caller's body returns.
  case scratch
}

/// A generate that ran to a zero exit.
public struct XcodeGeneration: Sendable, Equatable {
  public let tool: XcodeGeneratorTool
  /// The installed version, as the tool prints it.
  public let installed: String
  /// `nil` when the repository pins no version: the caller reports the run as unpinned.
  public let pin: XcodeGeneratorPin?
  public let location: XcodeGeneratedLocation
  /// The toplevel of the tree the project was generated in.
  public let tree: URL
  /// The generator's stdout and stderr.
  public let output: String
  public let elapsed: Duration

  public init(
    tool: XcodeGeneratorTool, installed: String, pin: XcodeGeneratorPin?,
    location: XcodeGeneratedLocation, tree: URL, output: String, elapsed: Duration
  ) {
    self.tool = tool
    self.installed = installed
    self.pin = pin
    self.location = location
    self.tree = tree
    self.output = output
    self.elapsed = elapsed
  }
}

/// What a generate step came to. Only ``generated(_:_:)`` ran the caller's body.
public enum XcodeGenerateOutcome<Value: Sendable>: Sendable {
  case generated(XcodeGeneration, Value)
  /// The tool isn't on `PATH`; `message` is what the launch printed.
  case notInstalled(tool: XcodeGeneratorTool, message: String)
  /// The installed version isn't the pinned one, so the generator never ran.
  case versionMismatch(tool: XcodeGeneratorTool, pinned: XcodeGeneratorPin, installed: String)
  /// The version query or the generate exited nonzero.
  case failed(tool: XcodeGeneratorTool, status: ExitStatus, output: String)
  /// The step couldn't run at all: a launch failure, a timeout or a scratch tree that wasn't made.
  case blocked(tool: XcodeGeneratorTool, reason: String)
}

extension XcodeGenerateOutcome: Equatable where Value: Equatable {}

/// Runs an area's `xcodegen generate` or `tuist generate` at the version the repository pins.
public struct XcodeGenerator: Sendable {
  private let runner: any ProcessRunner
  private let repositoryRoot: URL
  private let layout: BrownfieldStateLayout
  private let timeout: Duration

  /// - Parameters:
  ///   - repositoryRoot: the worktree's toplevel.
  ///   - layout: its brownfield state, whose scratch directory holds the scratch trees.
  public init(
    runner: any ProcessRunner = LiveProcessRunner(), repositoryRoot: URL,
    layout: BrownfieldStateLayout, timeout: Duration = .seconds(600)
  ) {
    self.runner = runner
    self.repositoryRoot = repositoryRoot
    self.layout = layout
    self.timeout = timeout
  }

  /// Generates the project and hands `body` the result while the tree holding it still exists.
  public func generate<Value: Sendable>(
    _ request: XcodeGenerateRequest, _ body: (XcodeGeneration) async -> Value
  ) async -> XcodeGenerateOutcome<Value> {
    .blocked(tool: .xcodegen, reason: "")
  }

  /// The pin the nearest file at or above the manifest's directory declares for `tool`.
  public static func pin(
    for tool: XcodeGeneratorTool, manifest: String, read: (String) -> Data?
  ) -> XcodeGeneratorPin? {
    nil
  }
}
