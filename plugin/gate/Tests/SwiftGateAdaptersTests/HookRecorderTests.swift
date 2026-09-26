import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import Testing

@Suite("hook payload recorder")
struct HookRecorderTests {
  let directory = FileManager.default.temporaryDirectory
    .appending(path: "swiftgate-record-\(UUID().uuidString)/nested", directoryHint: .isDirectory)
  let moment = Date(timeIntervalSince1970: 1_790_000_000.125)

  func files() throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
  }

  @Test(
    "the payload is stored byte for byte, creating the directory — catches recorded fixtures losing the fields swiftgate does not decode"
  )
  func payloadVerbatim() throws {
    defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
    let input = Data(#"{"hook_event_name":"Stop",  "unknown_field":[1,2]}"#.utf8)
    let recorder = HookRecorder(directory: directory, processID: 42)

    let recording = try recorder.recordPayload(.stop, input: input, at: moment)

    #expect(try Data(contentsOf: recording.payload) == input)
    #expect(recording.payload.lastPathComponent == "20260921T141320.125Z-42-stop.json")
  }

  @Test(
    "the outcome lands beside its payload with exit code, stdout and latency — catches live verdicts and hook latency being unrecoverable after a session"
  )
  func outcomeSidecar() throws {
    defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
    let recorder = HookRecorder(directory: directory, processID: 7)
    let recording = try recorder.recordPayload(.preToolUse, input: Data("{}".utf8), at: moment)

    try recorder.recordOutcome(
      recording, exitCode: 0, stdout: #"{"decision":"block"}"#, stderr: nil, milliseconds: 85)

    let outcome = try #require(
      try JSONSerialization.jsonObject(with: Data(contentsOf: recording.outcome)) as? [String: Any])
    #expect(outcome["event"] as? String == "pre-tool-use")
    #expect(outcome["exit_code"] as? Int == 0)
    #expect(outcome["stdout"] as? String == #"{"decision":"block"}"#)
    #expect(outcome["elapsed_ms"] as? Int == 85)
    #expect(outcome["started_at"] as? String == "2026-09-21T14:13:20.125Z")
    #expect(
      try files() == [
        "20260921T141320.125Z-7-pre-tool-use.json",
        "20260921T141320.125Z-7-pre-tool-use.outcome.json",
      ])
  }

  @Test(
    "concurrent hooks in the same millisecond keep separate recordings — catches parallel PreToolUse payloads overwriting each other"
  )
  func concurrentHooks() throws {
    defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
    _ = try HookRecorder(directory: directory, processID: 1)
      .recordPayload(.preToolUse, input: Data("1".utf8), at: moment)
    _ = try HookRecorder(directory: directory, processID: 2)
      .recordPayload(.preToolUse, input: Data("2".utf8), at: moment)

    #expect(try files().count == 2)
  }
}
