import Foundation
import SwiftGateDomain

/// The toolchain's `swift format` (plan D2). Paths are repository-relative.
public protocol SwiftFormatter: Sendable {
  /// Strict-mode violations in `paths`. A file that does not parse is one violation with no rule.
  func lint(paths: [String]) async throws(SwiftFormatError) -> [FormatViolation]

  /// Rewrites `path` in place; `true` when its bytes changed.
  func format(path: String) async throws(SwiftFormatError) -> Bool
}

public struct FormatViolation: Sendable, Equatable {
  public let path: String
  public let line: Int
  public let column: Int
  /// `nil` when the file did not parse.
  public let rule: String?
  public let message: String

  public init(path: String, line: Int, column: Int, rule: String?, message: String) {
    self.path = path
    self.line = line
    self.column = column
    self.rule = rule
    self.message = message
  }
}

/// `swift format` could not answer: `blocked`, never evidence about the code.
public enum SwiftFormatError: Error, Sendable, Equatable {
  case process(ProcessRunnerError)
  case commandFailed(arguments: [String], status: ExitStatus, stderr: String)
  case unparseableOutput(String)
  case unreadable(path: String, reason: String)

  public var verdict: Verdict { .blocked }
}

public struct LiveSwiftFormatter: SwiftFormatter {
  private let runner: any ProcessRunner
  private let repositoryRoot: String
  private let executable: String
  private let timeout: Duration

  public init(
    runner: any ProcessRunner, repositoryRoot: String, executable: String = "swift",
    timeout: Duration = .seconds(60)
  ) {
    self.runner = runner
    self.repositoryRoot = repositoryRoot
    self.executable = executable
    self.timeout = timeout
  }

  /// Keeps each argv well under `ARG_MAX`.
  private static let batchSize = 256

  public func lint(paths: [String]) async throws(SwiftFormatError) -> [FormatViolation] {
    var violations: [FormatViolation] = []
    for start in stride(from: 0, to: paths.count, by: Self.batchSize) {
      let batch = Array(paths[start..<min(start + Self.batchSize, paths.count)])
      let arguments = ["format", "lint", "--strict", "--"] + batch
      let output = try await run(arguments)
      // Exit 1 with violations is the answer; exit 0 must come with no output.
      guard output.status == .exited(0) || output.status == .exited(1) else {
        throw .commandFailed(
          arguments: arguments, status: output.status, stderr: output.stderr.text)
      }
      let parsed = try SwiftFormatOutput.violations(
        in: output.stderr.text, repositoryRoot: repositoryRoot)
      if output.status == .exited(1), parsed.isEmpty {
        throw .commandFailed(
          arguments: arguments, status: output.status, stderr: output.stderr.text)
      }
      violations += parsed
    }
    return violations
  }

  public func format(path: String) async throws(SwiftFormatError) -> Bool {
    let url = URL(filePath: repositoryRoot, directoryHint: .isDirectory).appending(path: path)
    let before = try read(url, path: path)
    let arguments = ["format", "format", "--in-place", "--", path]
    let output = try await run(arguments)
    guard output.status.isSuccess else {
      throw .commandFailed(arguments: arguments, status: output.status, stderr: output.stderr.text)
    }
    return try read(url, path: path) != before
  }

  private func read(_ url: URL, path: String) throws(SwiftFormatError) -> Data {
    do {
      return try Data(contentsOf: url)
    } catch {
      throw .unreadable(path: path, reason: error.localizedDescription)
    }
  }

  private func run(_ arguments: [String]) async throws(SwiftFormatError) -> ProcessOutput {
    do {
      return try await runner.run(
        ProcessInvocation(
          executable: executable, arguments: arguments, workingDirectory: repositoryRoot,
          timeout: timeout))
    } catch {
      throw .process(error)
    }
  }
}

/// Parses `swift format lint` diagnostics from stderr:
/// `<path>:<line>:<column>: <level>: [<Rule>] <message>`, where parse errors carry no `[Rule]`.
public enum SwiftFormatOutput {
  public static func violations(in stderr: String, repositoryRoot: String) throws(SwiftFormatError)
    -> [FormatViolation]
  {
    let rootPrefix = repositoryRoot.hasSuffix("/") ? repositoryRoot : repositoryRoot + "/"
    var violations: [FormatViolation] = []
    for line in stderr.split(separator: "\n") where !line.isEmpty {
      guard let violation = parse(line, rootPrefix: rootPrefix) else {
        throw .unparseableOutput(String(line))
      }
      violations.append(violation)
    }
    return violations
  }

  private static func parse(_ line: Substring, rootPrefix: String) -> FormatViolation? {
    for level in [": error: ", ": warning: "] {
      guard let marker = line.range(of: level) else { continue }
      let location = line[..<marker.lowerBound].split(
        separator: ":", omittingEmptySubsequences: false)
      guard location.count >= 3, let lineNumber = Int(location[location.count - 2]),
        let column = Int(location[location.count - 1])
      else { return nil }
      var path = location.dropLast(2).joined(separator: ":")
      if path.hasPrefix(rootPrefix) { path = String(path.dropFirst(rootPrefix.count)) }
      var message = String(line[marker.upperBound...])
      var rule: String?
      if message.hasPrefix("["), let close = message.firstIndex(of: "]") {
        rule = String(message[message.index(after: message.startIndex)..<close])
        message = String(message[message.index(after: close)...]).trimmingCharacters(
          in: .whitespaces)
      }
      return FormatViolation(
        path: path, line: lineNumber, column: column, rule: rule, message: message)
    }
    return nil
  }
}
