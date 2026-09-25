import SwiftGateAdapters
import SwiftGateDomain
import Synchronization

/// A scripted ``SwiftPM`` whose `describe` answers from `handler`; records described directories.
/// `test` and `codeCoveragePath` are not scripted and fail as unparseable.
public final class FakeSwiftPM: SwiftPM {
  public typealias Handler = @Sendable (String) throws(SwiftPMError) -> PackageManifest

  private let handler: Handler
  private let recorded = Mutex<[String]>([])

  public init(describe handler: @escaping Handler) {
    self.handler = handler
  }

  /// Answers `describe` with the manifest whose `path` is the requested directory.
  public convenience init(serving manifests: [PackageManifest]) {
    self.init { directory throws(SwiftPMError) in
      guard let manifest = manifests.first(where: { $0.path == directory }) else {
        throw .commandFailed(
          arguments: ["package", "describe"], status: .exited(1), stderr: "no package")
      }
      return manifest
    }
  }

  /// Package directories passed to `describe`, in call order.
  public var described: [String] { recorded.withLock { $0 } }

  public func describe(packageDirectory: String) async throws(SwiftPMError) -> PackageManifest {
    recorded.withLock { $0.append(packageDirectory) }
    return try handler(packageDirectory)
  }

  public func test(_ request: SwiftTestRequest) async throws(SwiftPMError) -> SwiftTestRun {
    throw .unparseableOutput(command: "test", detail: "FakeSwiftPM does not run tests")
  }

  public func codeCoveragePath(packageDirectory: String) async throws(SwiftPMError) -> String {
    throw .unparseableOutput(command: "codecov", detail: "FakeSwiftPM has no coverage")
  }
}
