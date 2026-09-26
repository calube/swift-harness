import Foundation
import SwiftGateDomain

/// Opt-in capture of live hook traffic (`SWIFTGATE_HOOK_RECORD_DIR`), so hook fixtures can be
/// replaced with what Claude Code really sends and live verdicts and latencies can be audited.
public struct HookRecorder: Sendable {
  public struct Recording: Sendable, Equatable {
    public let payload: URL
    public let outcome: URL
    let event: HookEvent
    let startedAt: Date
  }

  public static let environmentKey = "SWIFTGATE_HOOK_RECORD_DIR"

  public let directory: URL
  let processID: Int32

  public init(directory: URL, processID: Int32 = ProcessInfo.processInfo.processIdentifier) {
    self.directory = directory
    self.processID = processID
  }

  /// A recorder when the environment asks for one.
  public static func configured(_ environment: [String: String]) -> HookRecorder? {
    guard let path = environment[environmentKey], !path.isEmpty else { return nil }
    return HookRecorder(directory: URL(filePath: path, directoryHint: .isDirectory))
  }

  /// Stores stdin untouched, before the hook runs, so a hook that times out still leaves its
  /// payload behind.
  public func recordPayload(_ event: HookEvent, input: Data, at moment: Date) throws -> Recording {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let stem = "\(Self.compact(moment))-\(processID)-\(event.rawValue)"
    let recording = Recording(
      payload: directory.appending(path: "\(stem).json"),
      outcome: directory.appending(path: "\(stem).outcome.json"), event: event,
      startedAt: moment)
    try input.write(to: recording.payload, options: .withoutOverwriting)
    return recording
  }

  public func recordOutcome(
    _ recording: Recording, exitCode: Int32, stdout: String?, stderr: String?, milliseconds: Int
  ) throws {
    var outcome: [String: Any] = [
      "event": recording.event.rawValue, "exit_code": Int(exitCode), "elapsed_ms": milliseconds,
      "started_at": Self.iso(recording.startedAt),
    ]
    if let stdout { outcome["stdout"] = stdout }
    if let stderr { outcome["stderr"] = stderr }
    let data = try JSONSerialization.data(
      withJSONObject: outcome, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    try data.write(to: recording.outcome, options: .withoutOverwriting)
  }

  private static func iso(_ moment: Date) -> String {
    moment.formatted(
      Date.ISO8601FormatStyle(includingFractionalSeconds: true, timeZone: .gmt))
  }

  private static func compact(_ moment: Date) -> String {
    iso(moment).replacingOccurrences(of: "-", with: "").replacingOccurrences(of: ":", with: "")
  }
}
