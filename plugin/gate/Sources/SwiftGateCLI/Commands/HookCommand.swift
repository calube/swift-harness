import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain

extension HookEvent: ExpressibleByArgument {}
extension HookSource: ExpressibleByArgument {}

struct HookCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "hook",
    abstract: "Claude Code hook entry point: reads the event's JSON payload on stdin.",
    discussion: "Wired by hooks/hooks.json. A no-op outside a project with .swiftgate.toml.")

  @Argument(help: "session-start, pre-tool-use, post-tool-use or stop.")
  var event: HookEvent

  @Option(help: "plugin (hooks/hooks.json) or settings (a brownfield clone's settings.json).")
  var source: HookSource = .plugin

  func run() async throws {
    let input = FileHandle.standardInput.readDataToEndOfFile()
    let environment = ProcessInfo.processInfo.environment
    let result = await Self.execute(
      event, input: input, source: source, environment: environment
    ) { root in
      HookDependencies.live(root: root, environment: environment)
    }
    if let stdout = result.stdout { Console.write(stdout) }
    if let stderr = result.stderr {
      FileHandle.standardError.write(Data((stderr + "\n").utf8))
    }
    if result.exitCode != 0 { throw ExitCode(result.exitCode) }
  }

  static func execute(
    _ event: HookEvent, input: Data, source: HookSource = .plugin,
    environment: [String: String], dependencies: (URL) -> HookDependencies
  ) async -> HookResult {
    guard let recorder = HookRecorder.configured(environment) else {
      return await HookRunner.run(event, input: input, source: source, dependencies: dependencies)
    }
    var warnings: [String] = []
    let recording: HookRecorder.Recording?
    do {
      recording = try recorder.recordPayload(event, input: input, at: Date())
    } catch {
      recording = nil
      warnings.append("\(HookRecorder.environmentKey): payload not recorded: \(error)")
    }
    var (result, milliseconds) = await GateRun.timed {
      await HookRunner.run(event, input: input, source: source, dependencies: dependencies)
    }
    if let recording {
      do {
        try recorder.recordOutcome(
          recording, exitCode: result.exitCode, stdout: result.stdout, stderr: result.stderr,
          milliseconds: milliseconds)
      } catch {
        warnings.append("\(HookRecorder.environmentKey): outcome not recorded: \(error)")
      }
    }
    // Stderr on exit 0 only reaches the debug log, so a broken recorder cannot sway a decision.
    if !warnings.isEmpty {
      result.stderr = ([result.stderr].compactMap { $0 } + warnings).joined(separator: "\n")
    }
    return result
  }
}
