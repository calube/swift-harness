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
    let root = URL(filePath: worktree, directoryHint: .isDirectory)
    let report = await dependencies.installer.install(worktree: root)
    var notes = report.notes
    if !report.results.isEmpty {
      do throws(HarnessEventWriteError) {
        try dependencies.events(root).append(
          contentsOf: report.results.map {
            HarnessEvent(
              eventID: UUID().uuidString, time: Date(), head: report.head,
              source: HarnessEventSource(route: nil), payload: .warmupRun($0.event))
          })
      } catch {
        notes.append("node install: warmup.run events not written: \(error)")
      }
    }
    let installs = report.results.map {
      WorktreeReport.Install(
        directory: $0.install.directory, manager: $0.install.manager, command: $0.install.command,
        areas: $0.install.areas, ms: $0.milliseconds, cache: $0.cache, outcome: $0.outcome,
        detail: $0.detail)
    }
    let lines =
      installs.map { install in
        let areas = install.areas.joined(separator: ", ")
        let seconds = String(format: "%.1f s", Double(install.ms) / 1000)
        switch install.outcome {
        case .passed:
          return "installed \(areas) (`\(install.command)` in \(install.directory), \(seconds), "
            + "\(install.cache.rawValue) cache)"
        case .failed, .dropped, .notInstalled:
          return "\(areas)'s install `\(install.command)` \(install.outcome.rawValue) after "
            + "\(seconds): \(install.detail ?? "no output"); its commands run without it"
        }
      } + notes
    return Outcome(
      installs: installs, notes: notes,
      message: lines.isEmpty ? "" : "; " + lines.joined(separator: "; "))
  }
}
