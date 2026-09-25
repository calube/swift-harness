import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import Synchronization

/// Hands `body` a fixed device, or fails like a clone that could not be made.
public struct FakeDevices: SimulatorDeviceProvider {
  public static let device = SimulatorDevice(
    udid: "CLONE-UDID", name: "swift-harness-1-tok",
    runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-26-2", state: "Booted",
    isAvailable: true)

  private let failure: SimulatorCloneError?

  public init(failure: SimulatorCloneError? = nil) {
    self.failure = failure
  }

  public func withDevice<T: Sendable>(_ body: @Sendable (SimulatorDevice) async throws -> T)
    async throws -> T
  {
    if let failure { throw failure }
    return try await body(Self.device)
  }
}

/// Records every `xcodebuild test` request and answers with a fixed exit status.
public final class FakeXcodebuild: Xcodebuild {
  private let status: ExitStatus
  private let versionOutput: String
  private let recorded = Mutex<[XcodebuildTestRequest]>([])

  public init(status: ExitStatus = .exited(0), versionOutput: String = "") {
    self.status = status
    self.versionOutput = versionOutput
  }

  public var requests: [XcodebuildTestRequest] { recorded.withLock { $0 } }

  public func test(_ request: XcodebuildTestRequest, logPath: String)
    async throws(XcodebuildError) -> XcodebuildTestRun
  {
    recorded.withLock { $0.append(request) }
    return XcodebuildTestRun(status: status)
  }

  public func version() async throws(XcodebuildError) -> String { versionOutput }
}

/// Serves recorded `xcresulttool` output from `Fixtures/Xcresult/<scenario>.*` for every bundle.
public struct FakeXcresultReader: XcresultReader {
  private let scenario: String

  public init(scenario: String) {
    self.scenario = scenario
  }

  public func read(bundlePath: String) async throws(XcresultReadError) -> XcresultContents {
    guard let tests = try? Fixture.data("Xcresult/\(scenario).tests.json") else {
      throw .failed(status: .exited(64), stderr: "no fixture \(scenario)")
    }
    return XcresultContents(
      testResults: tests, buildResults: try? Fixture.data("Xcresult/\(scenario).build-results.json")
    )
  }
}
