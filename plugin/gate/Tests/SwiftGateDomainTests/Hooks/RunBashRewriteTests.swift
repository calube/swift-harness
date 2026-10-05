import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

/// A run session's Bash call as the trial's transcript recorded it, with its tool result and, for
/// a call the tool moved to the background, what that background task wrote before it was stopped.
struct RecordedBashCall: Decodable {
  struct ToolInput: Decodable {
    let command: String
    let timeout: Int?
  }

  let toolInput: ToolInput
  let result: String
  let backgroundOutput: String?

  enum CodingKeys: String, CodingKey {
    case toolInput = "tool_input"
    case result
    case backgroundOutput = "background_output"
  }

  static func load(_ name: String) throws -> [RecordedBashCall] {
    try JSONDecoder().decode([RecordedBashCall].self, from: Fixture.data("Hooks/\(name).json"))
  }
}

/// Runs `script` the way the Bash tool does: `zsh -c` with the profile's aliases and options
/// defined first, then `eval` of the command, with a stdin that is never written or closed.
private struct ProfileShell {
  /// The trial user's hazards: `cp -i` prompts on stdin, `ls` and `cat` are listers that read
  /// stdin when given no operand, and `noclobber` refuses `>` onto an existing file.
  static let profile = """
    alias cp='cp -i'; alias mv='mv -i'; alias cat='/bin/cat -'; alias ls='/bin/cat'
    setopt noclobber
    """

  let directory: URL

  init() throws {
    directory = TestTemporaryDirectory.root
      .appending(path: "run-bash-rewrite-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data("new\n".utf8).write(to: directory.appending(path: "src.txt"))
    try Data("old\n".utf8).write(to: directory.appending(path: "dst.txt"))
  }

  func remove() { try? FileManager.default.removeItem(at: directory) }

  /// The command's output and exit status, or `nil` when it was still running after `seconds`.
  /// With no `seconds` it waits for the exit however long a loaded machine takes, and a command
  /// that never exits is terminated once the suite's time limit cancels the wait.
  func run(_ command: String, seconds: Double? = nil) async throws
    -> (output: String, status: Int32)?
  {
    let quoted = "'" + command.replacingOccurrences(of: "'", with: "'\\''") + "'"
    let process = Process()
    process.executableURL = URL(filePath: "/bin/zsh")
    process.arguments = ["-f", "-c", Self.profile + "\neval " + quoted]
    process.currentDirectoryURL = directory
    let input = Pipe()
    let output = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = output
    let (exits, exited) = AsyncStream<Void>.makeStream()
    process.terminationHandler = { _ in exited.finish() }
    try process.run()
    defer { withExtendedLifetime(input) {} }
    guard let seconds else {
      await withTaskCancellationHandler {
        for await _ in exits {}
      } onCancel: {
        process.terminate()
      }
      let data = output.fileHandleForReading.readDataToEndOfFile()
      return (String(decoding: data, as: UTF8.self), process.terminationStatus)
    }
    let deadline = Date().addingTimeInterval(seconds)
    while process.isRunning, Date() < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    guard !process.isRunning else {
      process.terminate()
      process.waitUntilExit()
      return nil
    }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    return (String(decoding: data, as: UTF8.self), process.terminationStatus)
  }

  func contents(_ name: String) throws -> String {
    try String(contentsOf: directory.appending(path: name), encoding: .utf8)
  }
}

@Suite("A run session's Bash call is rewritten before it runs", .timeLimit(.minutes(5)))
struct RunBashRewriteTests {
  @Test(
    "the trial's 2 hung calls, a cat aliased to a stdin reader and a cp aliased to cp -i, both hit the 600 s timeout, and each is rewritten to run isolated with its 600 s timeout kept since it runs swiftgate — catches the rewrite skipping a call or capping a harness wait"
  )
  func capturedHangsIsolatedTimeoutKept() throws {
    let calls = try RecordedBashCall.load("practice-trials-alias-hang-bash")
    try #require(calls.count == 2)
    #expect(calls[1].backgroundOutput?.contains("(y/n [n])") == true)
    for call in calls {
      #expect(call.result.contains("did not complete within its 600s timeout"))
      let rewrite = try #require(
        RunBashRewrite.rewrite(
          command: call.toolInput.command, timeout: call.toolInput.timeout, runInBackground: false,
          isolateShell: true, capTimeout: true))
      #expect(rewrite.command == RunBashRewrite.isolated(call.toolInput.command))
      #expect(rewrite.command != call.toolInput.command)
      #expect(rewrite.timeout == 600_000)
      #expect(rewrite.note == nil)
    }
  }

  @Test(
    "the trial's long foreground script with no swiftgate in it has its 600 s timeout held to 120 s, with a note naming guard.foreground-timeout; in the background, or outside the cap, it runs as written — catches the cap missing, or reaching a call it shouldn't"
  )
  func capturedLongForegroundCapped() throws {
    let calls = try RecordedBashCall.load("practice-trials-long-foreground-bash")
    let call = try #require(calls.first)
    let command = call.toolInput.command
    let capped = try #require(
      RunBashRewrite.rewrite(
        command: command, timeout: call.toolInput.timeout, runInBackground: false,
        isolateShell: false, capTimeout: true))
    #expect(capped.command == command)
    #expect(capped.timeout == RunBashRewrite.foregroundCapMilliseconds)
    #expect(capped.note?.contains(RunBashRewrite.foregroundTimeoutRuleID) == true)
    #expect(
      RunBashRewrite.rewrite(
        command: command, timeout: 600_000, runInBackground: true, isolateShell: false,
        capTimeout: true) == nil)
    #expect(
      RunBashRewrite.rewrite(
        command: command, timeout: 600_000, runInBackground: false, isolateShell: false,
        capTimeout: false) == nil)
    #expect(
      RunBashRewrite.rewrite(
        command: command, timeout: 90_000, runInBackground: false, isolateShell: false,
        capTimeout: true) == nil)
    #expect(
      RunBashRewrite.rewrite(
        command: command, timeout: nil, runInBackground: false, isolateShell: false,
        capTimeout: true) == nil)
  }

  @Test(
    "a call running swiftgate by name, by an absolute path or through \"$SG\" keeps its timeout, while one that only mentions it in text is capped — catches the exemption keyed on the word anywhere",
    arguments: [
      ("swiftgate check --tier slice --json", 600_000),
      ("/opt/plugin/bin/swiftgate build gate-wait spec --tier merge --json", 600_000),
      ("SG=/opt/plugin/bin/swiftgate; \"$SG\" run clock spec --wait-until cutoffAt", 600_000),
      ("\"$SG\" qa run --plan spec --json > out.json", 600_000),
      ("echo swiftgate; sleep 300", RunBashRewrite.foregroundCapMilliseconds),
      ("python3 long.py", RunBashRewrite.foregroundCapMilliseconds),
    ])
  func swiftgateCallsKeepTimeout(_ command: String, _ expected: Int) {
    let rewrite = RunBashRewrite.rewrite(
      command: command, timeout: 600_000, runInBackground: false, isolateShell: false,
      capTimeout: true)
    #expect((rewrite?.timeout ?? 600_000) == expected, "\(command)")
  }

  @Test(
    "an isolated command is not isolated again — catches a second hook or a resent call nesting the wrapper"
  )
  func isolationIsIdempotent() throws {
    let once = RunBashRewrite.isolated("cp a b")
    #expect(once != "cp a b")
    #expect(RunBashRewrite.isolated(once) == once)
    let rewrite = RunBashRewrite.rewrite(
      command: once, timeout: nil, runInBackground: false, isolateShell: true, capTimeout: true)
    #expect(rewrite == nil)
  }

  @Test(
    "in a zsh whose profile aliases cp to cp -i and cat and ls to stdin readers, with noclobber on and a stdin that never closes, the trial's shape of call hangs as written but runs the real binaries and returns once isolated — catches a rewrite the alias still reaches, as a prefix on the same line would be"
  )
  func isolatedCommandRunsRealBinaries() async throws {
    let shell = try ProfileShell()
    defer { shell.remove() }
    let command =
      "cat >> /dev/null; cp src.txt dst.txt; echo again > dst.txt; cat <<'EOF'\nheredoc kept\nEOF\n"
      + "cat dst.txt; ls -d ."

    let asWritten = try await shell.run(command, seconds: 2)
    #expect(asWritten == nil, "\(asWritten?.output ?? "")")

    let run = try #require(
      try await shell.run(RunBashRewrite.isolated(command)),
      "the isolated command still waited on stdin")
    #expect(run.output == "heredoc kept\nagain\n.\n", "\(run.output)")
    #expect(run.status == 0)
    #expect(try shell.contents("dst.txt") == "again\n")
  }

  @Test(
    "an isolated command keeps quotes, a quoted heredoc, cd and its exit status — catches the wrapper mangling the command it carries"
  )
  func isolationPreservesCommand() async throws {
    let shell = try ProfileShell()
    defer { shell.remove() }
    let command = "mkdir -p 'a b' && cd 'a b' && printf '%s\\n' \"it's\" '$HOME' && pwd -P | "
      + "sed 's#.*/##'; python3 - <<'PY'\nprint('q\\'s')\nPY\nexit 3"

    let isolated = RunBashRewrite.isolated(command)
    #expect(isolated != command)
    let run = try #require(try await shell.run(isolated))
    #expect(run.output == "it's\n$HOME\na b\nq's\n", "\(run.output)")
    #expect(run.status == 3)
  }
}
