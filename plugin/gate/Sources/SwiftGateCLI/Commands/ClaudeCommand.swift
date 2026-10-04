import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain

/// `swiftgate claude [args…]`: starts `claude --settings <common>/swift-harness/settings.json`
/// with the arguments passed through, so a brownfield clone gets the hooks with no file in its
/// tree.
struct ClaudeCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "claude",
    abstract: "Start claude with the brownfield clone's hook settings.")

  @Argument(parsing: .captureForPassthrough, help: "Passed to claude unchanged.")
  var arguments: [String] = []

  func run() async throws {
    let cwd = URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
    guard case .brownfield(_, let layout)? = ProjectRoot.locateProfile(from: cwd) else {
      throw failure(
        "\(cwd.path) isn't in a brownfield clone: no \(StateRootResolver.commonConfigFile) under "
          + "its git common dir. Run `swiftgate discover --apply` first")
    }
    let settings = layout.settings.path
    guard FileManager.default.fileExists(atPath: settings) else {
      throw failure("\(settings) doesn't exist; `swiftgate discover --apply` writes it")
    }
    // Replacing this process, rather than waiting on a child, leaves claude the terminal's
    // foreground process, so Ctrl-C and job control reach it alone.
    let argv = ["claude", "--settings", settings] + arguments
    var pointers = argv.map { strdup($0) } + [nil]
    execvp("claude", &pointers)
    let reason = String(cString: strerror(errno))
    throw failure("claude could not start: \(reason); is it on PATH?")
  }

  private func failure(_ message: String) -> ExitCode {
    FileHandle.standardError.write(Data("swiftgate claude: \(message)\n".utf8))
    return ExitCode(Verdict.blocked.exitCode)
  }
}
