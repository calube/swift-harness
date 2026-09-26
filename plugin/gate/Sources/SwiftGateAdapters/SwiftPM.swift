import Foundation
import SwiftGateDomain

/// The SwiftPM operations the gate needs. Package directories are repository-relative.
public protocol SwiftPM: Sendable {
  func describe(packageDirectory: String) async throws(SwiftPMError) -> PackageManifest

  /// Build settings `describe` omits, from `swift package dump-package`.
  func settings(packageDirectory: String) async throws(SwiftPMError) -> PackageSettings

  /// Runs `swift test`. A nonzero exit (failing tests, build errors) is a normal result: judging it
  /// from the xUnit reports is the evidence layer's job.
  func test(_ request: SwiftTestRequest) async throws(SwiftPMError) -> SwiftTestRun

  /// Absolute path of the llvm-cov export JSON a coverage-enabled `swift test` writes.
  func codeCoveragePath(packageDirectory: String) async throws(SwiftPMError) -> String
}

public struct SwiftTestRequest: Sendable, Equatable {
  public var packageDirectory: String
  /// Each is passed as one `--filter` regular expression.
  public var filters: [String]
  public var parallel: Bool
  public var codeCoverage: Bool
  /// Absolute path for the XCTest xUnit report; Swift Testing's lands beside it.
  public var xunitOutputPath: String

  public init(
    packageDirectory: String, filters: [String] = [], parallel: Bool = true,
    codeCoverage: Bool = false, xunitOutputPath: String
  ) {
    self.packageDirectory = packageDirectory
    self.filters = filters
    self.parallel = parallel
    self.codeCoverage = codeCoverage
    self.xunitOutputPath = xunitOutputPath
  }
}

public struct SwiftTestRun: Sendable, Equatable {
  public var output: ProcessOutput
  public var xctestReportPath: String
  /// SwiftPM derives this from the `--xunit-output` path by appending `-swift-testing` to its stem.
  public var swiftTestingReportPath: String

  public init(output: ProcessOutput, xctestReportPath: String, swiftTestingReportPath: String) {
    self.output = output
    self.xctestReportPath = xctestReportPath
    self.swiftTestingReportPath = swiftTestingReportPath
  }
}

/// Every case means SwiftPM could not answer, which is never evidence about the code: `blocked`.
public enum SwiftPMError: Error, Sendable, Equatable {
  case process(ProcessRunnerError)
  case commandFailed(arguments: [String], status: ExitStatus, stderr: String)
  case unparseableOutput(command: String, detail: String)

  public var verdict: Verdict { .blocked }
}

/// ``SwiftPM`` over the `swift` CLI via a ``ProcessRunner``.
public struct LiveSwiftPM: SwiftPM {
  private let runner: any ProcessRunner
  private let repositoryRoot: String
  private let executable: String
  private let queryTimeout: Duration
  private let testTimeout: Duration
  private let manifestCache: ManifestAnswerCache?

  /// - Parameters:
  ///   - repositoryRoot: absolute path of the worktree's top-level directory.
  ///   - queryTimeout: for `describe` and `--show-codecov-path`, which may resolve dependencies.
  ///   - manifestCache: where `describe` and `dump-package` answers are kept between processes;
  ///     `nil` to ask `swift` every time.
  public init(
    runner: any ProcessRunner, repositoryRoot: String, executable: String = "swift",
    queryTimeout: Duration = .seconds(300), testTimeout: Duration = .seconds(900),
    manifestCache: URL? = nil
  ) {
    self.runner = runner
    self.repositoryRoot = repositoryRoot
    self.executable = executable
    self.queryTimeout = queryTimeout
    self.testTimeout = testTimeout
    self.manifestCache = manifestCache.map {
      ManifestAnswerCache(directory: $0, repositoryRoot: repositoryRoot)
    }
  }

  public func describe(packageDirectory: String) async throws(SwiftPMError) -> PackageManifest {
    let output = try await manifestAnswer(
      ["package", "describe", "--type", "json"], packageDirectory: packageDirectory)
    do {
      return try PackageManifest(describeJSON: output, repositoryRoot: repositoryRoot)
    } catch {
      throw .unparseableOutput(command: "package describe", detail: "\(error)")
    }
  }

  public func settings(packageDirectory: String) async throws(SwiftPMError) -> PackageSettings {
    let output = try await manifestAnswer(
      ["package", "dump-package"], packageDirectory: packageDirectory)
    do {
      return try PackageSettings(dumpPackageJSON: output)
    } catch {
      throw .unparseableOutput(command: "package dump-package", detail: "\(error)")
    }
  }

  /// Only successful answers are kept, so a transient failure is retried next time.
  private func manifestAnswer(_ arguments: [String], packageDirectory: String)
    async throws(SwiftPMError) -> Data
  {
    let command = arguments.joined(separator: " ")
    if let cached = manifestCache?.answer(command, packageDirectory: packageDirectory) {
      return cached
    }
    let output = try await run(arguments, in: packageDirectory, timeout: queryTimeout)
    try Self.requireSuccess(arguments, output)
    if !output.stdout.truncated {
      manifestCache?.store(output.stdout.bytes, command, packageDirectory: packageDirectory)
    }
    return output.stdout.bytes
  }

  public func test(_ request: SwiftTestRequest) async throws(SwiftPMError) -> SwiftTestRun {
    var arguments = ["test"]
    arguments.append(request.parallel ? "--parallel" : "--no-parallel")
    if request.codeCoverage { arguments.append("--enable-code-coverage") }
    arguments += ["--xunit-output", request.xunitOutputPath]
    for filter in request.filters { arguments += ["--filter", filter] }
    let output = try await run(
      arguments, in: request.packageDirectory, timeout: testTimeout,
      // The snapshot library's default silently records missing references and passes.
      environmentOverlay: ["SNAPSHOT_TESTING_RECORD": "never"])
    return SwiftTestRun(
      output: output, xctestReportPath: request.xunitOutputPath,
      swiftTestingReportPath: Self.swiftTestingReportPath(for: request.xunitOutputPath))
  }

  public func codeCoveragePath(packageDirectory: String) async throws(SwiftPMError) -> String {
    let arguments = ["test", "--show-codecov-path"]
    let output = try await run(arguments, in: packageDirectory, timeout: queryTimeout)
    try Self.requireSuccess(arguments, output)
    let path = output.stdout.text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard path.hasPrefix("/"), path.hasSuffix(".json"), !path.contains("\n") else {
      throw .unparseableOutput(
        command: "test --show-codecov-path", detail: "expected one absolute .json path")
    }
    return path
  }

  public static func swiftTestingReportPath(for xunitPath: String) -> String {
    let url = URL(filePath: xunitPath)
    let stem = url.deletingPathExtension().lastPathComponent
    let renamed = url.deletingLastPathComponent().appending(path: "\(stem)-swift-testing")
    return url.pathExtension.isEmpty
      ? renamed.path : renamed.appendingPathExtension(url.pathExtension).path
  }

  private func run(
    _ arguments: [String], in packageDirectory: String, timeout: Duration,
    environmentOverlay: [String: String?] = [:]
  ) async throws(SwiftPMError) -> ProcessOutput {
    let directory =
      packageDirectory.isEmpty ? repositoryRoot : "\(repositoryRoot)/\(packageDirectory)"
    do {
      return try await runner.run(
        ProcessInvocation(
          executable: executable, arguments: arguments, environmentOverlay: environmentOverlay,
          workingDirectory: directory, timeout: timeout))
    } catch {
      throw .process(error)
    }
  }

  private static func requireSuccess(_ arguments: [String], _ output: ProcessOutput)
    throws(SwiftPMError)
  {
    guard output.status.isSuccess else {
      throw .commandFailed(arguments: arguments, status: output.status, stderr: output.stderr.text)
    }
    if output.stdout.truncated {
      throw .unparseableOutput(
        command: arguments.joined(separator: " "), detail: "output exceeded the capture cap")
    }
  }
}
