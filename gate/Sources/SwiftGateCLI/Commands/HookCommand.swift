import ArgumentParser
import Foundation
import SwiftGateDomain

extension HookEvent: ExpressibleByArgument {}

struct HookCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "hook",
    abstract: "Claude Code hook entry point: reads the event's JSON payload on stdin.",
    discussion: "Wired by hooks/hooks.json. A no-op outside a project with .swiftgate.toml.")

  @Argument(help: "session-start, pre-tool-use, post-tool-use or stop.")
  var event: HookEvent

  func run() async throws {
    let input = FileHandle.standardInput.readDataToEndOfFile()
    let environment = ProcessInfo.processInfo.environment
    let result = await HookRunner.run(event, input: input) { root in
      HookDependencies.live(root: root, environment: environment)
    }
    if let stdout = result.stdout { Console.write(stdout) }
    if let stderr = result.stderr {
      FileHandle.standardError.write(Data((stderr + "\n").utf8))
    }
    if result.exitCode != 0 { throw ExitCode(result.exitCode) }
  }
}
