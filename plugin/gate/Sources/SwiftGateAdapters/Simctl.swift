import Foundation
import SwiftGateDomain

public enum SimctlError: Error, Sendable, Equatable {
  case runner(ProcessRunnerError)
  /// `simctl` exited nonzero; `stderr` is its first two lines, which name the failure.
  case failed(command: String, status: ExitStatus, stderr: String)
  case unreadableOutput(command: String, detail: String)
  /// `simctl` ran past its deadline, which on a loaded machine is too short, not a hang.
  case timedOut(command: String, deadline: Duration)

  /// Simulator trouble is the machine's, never evidence about the code.
  public var verdict: Verdict { .blocked }

  public var message: String {
    switch self {
    case .runner(let error): "simctl could not run: \(error)"
    case .failed(let command, let status, let stderr):
      "simctl \(command) failed (\(status)): \(stderr)"
    case .unreadableOutput(let command, let detail):
      "simctl \(command) printed unexpected output: \(detail)"
    case .timedOut(let command, let deadline):
      "simctl \(command) did not finish within its \(deadline) deadline"
    }
  }
}

/// The `xcrun simctl` operations a simulator-tier run needs.
public protocol Simctl: Sendable {
  func devices() async throws(SimctlError) -> [SimulatorDevice]
  /// Returns the clone's UDID.
  func clone(_ udid: String, name: String) async throws(SimctlError) -> String
  /// Makes a fresh, shut-down device and returns its UDID.
  func create(name: String, deviceType: String, runtime: String) async throws(SimctlError)
    -> String
  /// Boots the device and waits until it has finished booting.
  func boot(_ udid: String) async throws(SimctlError)
  func shutdown(_ udid: String) async throws(SimctlError)
  func delete(_ udid: String) async throws(SimctlError)
  func install(_ udid: String, appPath: String) async throws(SimctlError)
  /// Returns the launched process's PID.
  func launch(_ udid: String, bundleID: String, arguments: [String]) async throws(SimctlError)
    -> Int32
}

public struct LiveSimctl: Simctl {
  public struct Timeouts: Sendable {
    public var quick: Duration
    /// A cold boot of a fresh clone takes tens of seconds on a loaded machine.
    public var boot: Duration

    public init(quick: Duration = .seconds(60), boot: Duration = .seconds(300)) {
      self.quick = quick
      self.boot = boot
    }
  }

  private let runner: any ProcessRunner
  private let timeouts: Timeouts

  public init(runner: any ProcessRunner, timeouts: Timeouts = Timeouts()) {
    self.runner = runner
    self.timeouts = timeouts
  }

  public func devices() async throws(SimctlError) -> [SimulatorDevice] {
    let output = try await simctl(["list", "devices", "--json"], timeout: timeouts.quick)
    return try Self.parseDevices(output.stdout.bytes)
  }

  public func clone(_ udid: String, name: String) async throws(SimctlError) -> String {
    let output = try await simctl(["clone", udid, name], timeout: timeouts.quick)
    let clone = output.stdout.text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard UUID(uuidString: clone) != nil else {
      throw .unreadableOutput(command: "clone", detail: "expected a UDID, got \"\(clone)\"")
    }
    return clone
  }

  public func create(name: String, deviceType: String, runtime: String)
    async throws(SimctlError) -> String
  {
    throw .unreadableOutput(command: "create", detail: "not supported")
  }

  public func boot(_ udid: String) async throws(SimctlError) {
    _ = try await simctl(["bootstatus", udid, "-b"], timeout: timeouts.boot)
  }

  public func shutdown(_ udid: String) async throws(SimctlError) {
    _ = try await simctl(["shutdown", udid], timeout: timeouts.quick)
  }

  public func delete(_ udid: String) async throws(SimctlError) {
    _ = try await simctl(["delete", udid], timeout: timeouts.quick)
  }

  public func install(_ udid: String, appPath: String) async throws(SimctlError) {
    _ = try await simctl(["install", udid, appPath], timeout: timeouts.boot)
  }

  public func launch(_ udid: String, bundleID: String, arguments: [String])
    async throws(SimctlError) -> Int32
  {
    let output = try await simctl(
      ["launch", udid, bundleID] + arguments, timeout: timeouts.quick)
    // `<bundle id>: <pid>`
    let text = output.stdout.text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard
      let pid = text.split(separator: ":").last.flatMap({
        Int32($0.trimmingCharacters(in: .whitespaces))
      })
    else {
      throw .unreadableOutput(
        command: "launch", detail: "expected \"<bundle id>: <pid>\", got \"\(text)\"")
    }
    return pid
  }

  private func simctl(_ arguments: [String], timeout: Duration) async throws(SimctlError)
    -> ProcessOutput
  {
    let output: ProcessOutput
    do {
      output = try await runner.run(
        ProcessInvocation(
          executable: "/usr/bin/xcrun", arguments: ["simctl"] + arguments, timeout: timeout))
    } catch {
      throw .runner(error)
    }
    guard output.status.isSuccess else {
      let summary = output.stderr.text.split(whereSeparator: \.isNewline).prefix(2)
        .map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
      throw .failed(command: arguments.first ?? "", status: output.status, stderr: summary)
    }
    return output
  }

  static func parseDevices(_ data: Data) throws(SimctlError) -> [SimulatorDevice] {
    struct List: Decodable { let devices: [String: [Device]] }
    struct Device: Decodable {
      let udid: String
      let name: String
      let state: String
      let isAvailable: Bool?
    }
    let list: List
    do {
      list = try JSONDecoder().decode(List.self, from: data)
    } catch {
      throw .unreadableOutput(command: "list", detail: "\(error)")
    }
    return list.devices.sorted { $0.key < $1.key }.flatMap { runtime, devices in
      devices.map {
        SimulatorDevice(
          udid: $0.udid, name: $0.name, runtimeIdentifier: runtime, state: $0.state,
          isAvailable: $0.isAvailable ?? false)
      }
    }
  }
}
