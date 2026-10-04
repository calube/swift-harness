import Foundation
import SwiftGateAdapters
import Synchronization

/// The device a final pass drives, answered with the calls `Fixtures/AgentDevice/record/capture.sh`
/// captured. Like the real tools it leaves files where they would: each `screenshot` step's PNG,
/// the video at the batch's `record start` path once `record stop` runs, the sheet at
/// `contact-sheet --out`, and the trace at `trace stop`'s path. Captured paths under `/HOME` read
/// as `home`, where the session's app log and the app's data container are laid out.
public enum CapturedFinalPass {
  /// The calls by key, as `key(of:)` names them, and the fixture each answers with.
  static let fixtures: [String: String] = [
    "record stop": "AgentDevice/record/record-stop",
    "record contact-sheet": "AgentDevice/record/contact-sheet",
    "logs start": "AgentDevice/record/logs-start",
    "logs stop": "AgentDevice/record/logs-stop",
    "logs path": "AgentDevice/record/logs-path",
    "network dump": "AgentDevice/record/network-dump",
    "trace start": "AgentDevice/trace-start",
    "trace stop": "AgentDevice/trace-stop",
    "simctl get_app_container": "AgentDevice/record/app-container",
    "simctl spawn": "AgentDevice/record/log-show",
  ]

  /// The file the app's data container holds, relative to the container.
  public static let containerFile = "Documents/count.txt"

  /// - Parameters:
  ///   - batch: the capture every `batch` answers with: `record/recorded-pass` or
  ///     `record/recorded-fail` under `Fixtures/AgentDevice/`, or `batch/pass` or `batch/fail`.
  ///   - failing: call keys answered with exit 1 and no output, as a call that broke.
  public static func runner(batch: String, home: URL, failing: Set<String> = []) throws
    -> FakeProcessRunner
  {
    let batchOutput = try output("AgentDevice/\(batch)", home: home)
    let ran = try executedSteps(batchOutput.stdout.bytes)
    var answers: [String: ProcessOutput] = [:]
    for (key, path) in fixtures { answers[key] = try output(path, home: home) }
    try layOut(home: home, answers: answers)
    let recordTo = Mutex<String?>(nil)
    let fixed = answers
    return FakeProcessRunner { invocation throws(ProcessRunnerError) in
      let arguments = invocation.arguments
      let key = Self.key(of: invocation)
      if failing.contains(key) {
        return ProcessOutput(status: .exited(1), stderr: "broke\n")
      }
      switch key {
      case "batch":
        let steps = Self.steps(arguments)
        recordTo.withLock { $0 = Self.recordPath(steps) }
        for step in steps.prefix(ran) where step["command"] as? String == "screenshot" {
          if let path = (step["input"] as? [String: Any])?["path"] as? String {
            FileManager.default.createFile(atPath: path, contents: Data("png".utf8))
          }
        }
        return batchOutput
      case "record stop":
        if let path = recordTo.withLock({ $0 }) {
          FileManager.default.createFile(atPath: path, contents: Data("mp4".utf8))
        }
      case "record contact-sheet":
        if let out = Self.value(after: "--out", in: arguments) {
          FileManager.default.createFile(atPath: out, contents: Data("png".utf8))
        }
      case "trace stop":
        if arguments.count > 2 {
          FileManager.default.createFile(atPath: arguments[2], contents: Data("trace\n".utf8))
        }
      default:
        break
      }
      return fixed[key]
        ?? ProcessOutput(status: .exited(2), stderr: "unscripted: \(arguments)\n")
    }
  }

  /// `<first> <second>` for `agent-device` calls, such as `record stop`; `batch` alone; and
  /// `simctl <verb>` for `xcrun`.
  public static func key(of invocation: ProcessInvocation) -> String {
    let arguments = invocation.arguments
    if arguments.first == "batch" { return "batch" }
    return arguments.prefix(2).joined(separator: " ")
  }

  private static func output(_ path: String, home: URL) throws -> ProcessOutput {
    let status = try Fixture.text("\(path).status").trimmingCharacters(in: .whitespacesAndNewlines)
    let stdout = try Fixture.text("\(path).stdout").replacingOccurrences(of: "/HOME", with: home.path)
    return ProcessOutput(
      status: .exited(Int32(status) ?? 2), stdout: CapturedStream(bytes: Data(stdout.utf8)),
      stderr: CapturedStream(bytes: try Fixture.data("\(path).stderr")), elapsed: .zero)
  }

  /// The session's app log and the app's data container, where the captured paths name them.
  private static func layOut(home: URL, answers: [String: ProcessOutput]) throws {
    let files = FileManager.default
    if let logs = answers["logs path"],
      let object = try JSONSerialization.jsonObject(with: logs.stdout.bytes) as? [String: Any],
      let path = (object["data"] as? [String: Any])?["path"] as? String
    {
      let log = URL(filePath: path)
      try files.createDirectory(
        at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data("app log line\n".utf8).write(to: log)
    }
    if let container = answers["simctl get_app_container"] {
      let root = URL(
        filePath: container.stdout.text.trimmingCharacters(in: .whitespacesAndNewlines),
        directoryHint: .isDirectory)
      let file = root.appending(path: containerFile)
      try files.createDirectory(
        at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data("1\n".utf8).write(to: file)
    }
  }

  private static func executedSteps(_ stdout: Data) throws -> Int {
    let object = try JSONSerialization.jsonObject(with: stdout) as? [String: Any] ?? [:]
    if let data = object["data"] as? [String: Any] {
      return (data["results"] as? [Any])?.count ?? 0
    }
    let details = (object["error"] as? [String: Any])?["details"] as? [String: Any]
    return (details?["partialResults"] as? [Any])?.count ?? 0
  }

  private static func steps(_ arguments: [String]) -> [[String: Any]] {
    guard let file = value(after: "--steps-file", in: arguments),
      let data = FileManager.default.contents(atPath: file),
      let steps = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
    else { return [] }
    return steps
  }

  private static func recordPath(_ steps: [[String: Any]]) -> String? {
    guard let first = steps.first, first["command"] as? String == "record",
      let input = first["input"] as? [String: Any], input["action"] as? String == "start"
    else { return nil }
    return input["path"] as? String
  }

  private static func value(after flag: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
      return nil
    }
    return arguments[index + 1]
  }
}
