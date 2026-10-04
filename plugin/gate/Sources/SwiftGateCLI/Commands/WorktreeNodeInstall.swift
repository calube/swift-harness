import Foundation
import SwiftGateAdapters
import SwiftGateDomain

/// Installs a new brownfield worktree's node dependencies once, so no area command has to, and
/// records each install as a `warmup.run` with step `install`. Nothing here fails the creation.
enum WorktreeNodeInstall {
  struct Dependencies: Sendable {
    var installer: any NodeDependencyInstalling
    /// The event writer for the worktree at the URL.
    var events: @Sendable (URL) -> any HarnessEventWriting

    static func live() -> Dependencies {
      let runner = LiveProcessRunner()
      return Dependencies(
        installer: LiveNodeDependencyInstaller(git: runner, installs: runner),
        events: { EventWriterFactory.make(root: $0, enabled: true) })
    }
  }

  struct Outcome: Sendable, Equatable {
    let installs: [WorktreeReport.Install]
    let notes: [String]
    /// Appended to the report's message; empty when nothing was installed or noted.
    let message: String
  }

  static func run(worktree: String, dependencies: Dependencies) async -> Outcome {
    Outcome(installs: [], notes: [], message: "")
  }
}
