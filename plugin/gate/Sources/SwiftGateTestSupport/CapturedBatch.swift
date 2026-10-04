import Foundation
import SwiftGateAdapters

/// `agent-device batch` answered with a batch captured by `Fixtures/AgentDevice/batch/capture.sh`,
/// or by another capture script whose fixture directory the caller names.
/// Like the real tool, it writes a file at each `screenshot` step's `path`; the bytes stand in for
/// a PNG, which no rule decodes.
public enum CapturedBatch {
  public static let directory = "AgentDevice/batch"

  public static func output(_ name: String, directory: String = directory) throws -> ProcessOutput {
    let status = try Fixture.text("\(directory)/\(name).status")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return ProcessOutput(
      status: .exited(Int32(status) ?? 2),
      stdout: CapturedStream(bytes: try Fixture.data("\(directory)/\(name).stdout")),
      stderr: CapturedStream(bytes: try Fixture.data("\(directory)/\(name).stderr")),
      elapsed: .zero)
  }

  /// Answers every `batch` with `name`'s capture, writing only the screenshots of the steps that
  /// ran before it stopped, and any other call with `other`.
  public static func runner(
    _ name: String, directory: String = directory,
    other: ProcessOutput = ProcessOutput(status: .exited(0), stdout: "{}")
  ) throws -> FakeProcessRunner {
    let output = try output(name, directory: directory)
    let ran = try executedSteps(output.stdout.bytes)
    return FakeProcessRunner { invocation throws(ProcessRunnerError) in
      guard invocation.arguments.first == "batch" else { return other }
      writeScreenshots(invocation.arguments, upTo: ran)
      return output
    }
  }

  /// How many steps the capture ran: all of a passing batch's, or a failing one's partial results.
  private static func executedSteps(_ stdout: Data) throws -> Int {
    let object = try JSONSerialization.jsonObject(with: stdout) as? [String: Any] ?? [:]
    if let data = object["data"] as? [String: Any] {
      return (data["results"] as? [Any])?.count ?? 0
    }
    let error = object["error"] as? [String: Any]
    let details = error?["details"] as? [String: Any]
    return (details?["partialResults"] as? [Any])?.count ?? 0
  }

  private static func writeScreenshots(_ arguments: [String], upTo count: Int) {
    guard let flag = arguments.firstIndex(of: "--steps-file"), flag + 1 < arguments.count,
      let data = FileManager.default.contents(atPath: arguments[flag + 1]),
      let steps = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
    else { return }
    for step in steps.prefix(count) where step["command"] as? String == "screenshot" {
      if let path = (step["input"] as? [String: Any])?["path"] as? String {
        FileManager.default.createFile(atPath: path, contents: Data("png".utf8))
      }
    }
  }
}
