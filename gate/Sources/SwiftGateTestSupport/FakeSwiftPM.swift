import SwiftGateAdapters
import SwiftGateDomain
import Synchronization

/// A scripted ``SwiftPM`` whose `describe` answers from `handler`, `settings` and
/// `codeCoveragePath` from tables, and `test` from `testHandler`; records calls. Unscripted calls
/// fail as unparseable.
public final class FakeSwiftPM: SwiftPM {
  public typealias Handler = @Sendable (String) throws(SwiftPMError) -> PackageManifest

  public typealias TestHandler =
    @Sendable (SwiftTestRequest) throws(SwiftPMError) -> SwiftTestRun

  private let handler: Handler
  private let packageSettings: [String: PackageSettings]
  private let testHandler: TestHandler?
  private let coveragePaths: [String: String]
  private let recorded = Mutex<[String]>([])
  private let recordedTests = Mutex<[SwiftTestRequest]>([])

  /// - Parameters:
  ///   - settings: package directory → settings; unlisted packages set nothing.
  ///   - coveragePaths: package directory → llvm-cov export path.
  public init(
    settings: [String: PackageSettings] = [:], coveragePaths: [String: String] = [:],
    test testHandler: TestHandler? = nil, describe handler: @escaping Handler
  ) {
    self.handler = handler
    self.packageSettings = settings
    self.testHandler = testHandler
    self.coveragePaths = coveragePaths
  }

  /// Answers `describe` with the manifest whose `path` is the requested directory.
  public convenience init(
    serving manifests: [PackageManifest], settings: [String: PackageSettings] = [:],
    coveragePaths: [String: String] = [:], test testHandler: TestHandler? = nil
  ) {
    self.init(settings: settings, coveragePaths: coveragePaths, test: testHandler) {
      directory throws(SwiftPMError) in
      guard let manifest = manifests.first(where: { $0.path == directory }) else {
        throw .commandFailed(
          arguments: ["package", "describe"], status: .exited(1), stderr: "no package")
      }
      return manifest
    }
  }

  /// Package directories passed to `describe`, in call order.
  public var described: [String] { recorded.withLock { $0 } }

  /// Requests passed to `test`, in call order.
  public var testRequests: [SwiftTestRequest] { recordedTests.withLock { $0 } }

  public func describe(packageDirectory: String) async throws(SwiftPMError) -> PackageManifest {
    recorded.withLock { $0.append(packageDirectory) }
    return try handler(packageDirectory)
  }

  public func settings(packageDirectory: String) async throws(SwiftPMError) -> PackageSettings {
    packageSettings[packageDirectory] ?? PackageSettings()
  }

  public func test(_ request: SwiftTestRequest) async throws(SwiftPMError) -> SwiftTestRun {
    recordedTests.withLock { $0.append(request) }
    guard let testHandler else {
      throw .unparseableOutput(command: "test", detail: "FakeSwiftPM does not run tests")
    }
    return try testHandler(request)
  }

  public func codeCoveragePath(packageDirectory: String) async throws(SwiftPMError) -> String {
    guard let path = coveragePaths[packageDirectory] else {
      throw .unparseableOutput(command: "codecov", detail: "FakeSwiftPM has no coverage")
    }
    return path
  }
}
