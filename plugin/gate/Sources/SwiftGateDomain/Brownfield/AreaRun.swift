import Foundation

/// 1 command an area runs, already expanded: no `{files}`, `{tests}` or `{junit}` remains.
public struct AreaCommandRequest: Sendable, Equatable {
  public let area: String
  public let step: AreaStep
  /// Run through `/bin/sh -c`.
  public let command: String
  /// Absolute: the area's root.
  public let workingDirectory: String
  public let deadline: Duration
  /// Added to the inherited environment, such as a shared package cache.
  public let environment: [String: String]
  /// Absolute path the command writes JUnit XML to, when `{junit}` was expanded.
  public let junitPath: String?
  /// Absolute path an `xcodebuild` test command writes its result bundle to, which the runner
  /// reads for the failing tests' ids since `xcodebuild` writes no JUnit.
  public let resultBundlePath: String?

  public init(
    area: String, step: AreaStep, command: String, workingDirectory: String, deadline: Duration,
    environment: [String: String], junitPath: String?, resultBundlePath: String? = nil
  ) {
    self.area = area
    self.step = step
    self.command = command
    self.workingDirectory = workingDirectory
    self.deadline = deadline
    self.environment = environment
    self.junitPath = junitPath
    self.resultBundlePath = resultBundlePath
  }
}

/// How an area command ended. `tail` is the last 40 lines of its combined output.
public enum AreaCommandOutcome: Sendable, Equatable {
  case passed
  /// `junit` holds the report's bytes when the request named a path and the command wrote it.
  case failed(exit: Int32, tail: String, junit: Data?)
  /// The test process died rather than reporting a failure. `signal` is `nil` when the death was
  /// read from the runner's output, such as a forked JVM's `System.exit`, and no signal was named.
  case crashed(signal: Int32?, tail: String)
  case timedOut(tail: String)
}

extension AreaCommandOutcome {
  /// `/bin/sh` exits 127 when it can't find the command's tool.
  public var toolNotInstalled: Bool {
    if case .failed(127, _, _) = self { true } else { false }
  }
}
