import Foundation
import SwiftGateDomain

/// The JSON a result bundle yields for ``SimulatorTestEvidence``.
public struct XcresultContents: Sendable, Equatable {
  /// `xcresulttool get test-results tests`.
  public let testResults: Data
  /// `xcresulttool get build-results`; `nil` when that read failed, since the test tree alone
  /// still judges every run that got as far as running tests.
  public let buildResults: Data?

  public init(testResults: Data, buildResults: Data?) {
    self.testResults = testResults
    self.buildResults = buildResults
  }
}

public enum XcresultReadError: Error, Sendable, Equatable {
  case runner(ProcessRunnerError)
  /// `xcresulttool` exited nonzero, e.g. because `xcodebuild` never wrote the bundle.
  case failed(status: ExitStatus, stderr: String)

  /// No readable bundle says nothing about the code.
  public var verdict: Verdict { .blocked }

  public var message: String {
    switch self {
    case .runner(let error): "xcresulttool could not run: \(error)"
    case .failed(let status, let stderr): "xcresulttool failed (\(status)): \(stderr)"
    }
  }
}

/// Reads a result bundle through `xcresulttool` (Xcode 26.2: `get test-results tests` and
/// `get build-results`, schema 0.1.0). The only Xcode-version-sensitive adapter (spec §5.2).
public protocol XcresultReader: Sendable {
  func read(bundlePath: String) async throws(XcresultReadError) -> XcresultContents
}

public struct LiveXcresultReader: XcresultReader {
  private let runner: any ProcessRunner
  private let timeout: Duration

  public init(runner: any ProcessRunner, timeout: Duration = .seconds(120)) {
    self.runner = runner
    self.timeout = timeout
  }

  public func read(bundlePath: String) async throws(XcresultReadError) -> XcresultContents {
    let tests = try await xcresulttool(["get", "test-results", "tests", "--path", bundlePath])
    guard tests.status.isSuccess else {
      throw .failed(status: tests.status, stderr: Self.firstLine(tests.stderr.text))
    }
    let build = try await xcresulttool(["get", "build-results", "--path", bundlePath])
    return XcresultContents(
      testResults: tests.stdout.bytes,
      buildResults: build.status.isSuccess ? build.stdout.bytes : nil
    )
  }

  private func xcresulttool(_ arguments: [String]) async throws(XcresultReadError)
    -> ProcessOutput
  {
    do {
      return try await runner.run(
        ProcessInvocation(
          executable: "/usr/bin/xcrun", arguments: ["xcresulttool"] + arguments, timeout: timeout))
    } catch {
      throw .runner(error)
    }
  }

  private static func firstLine(_ text: String) -> String {
    text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
  }
}
