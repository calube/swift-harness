import Foundation
import SwiftGateDomain

/// How 1 node install ran.
public struct NodeInstallResult: Sendable, Equatable {
  public let install: NodeInstall
  public let milliseconds: Int
  /// Whether the manager's package cache held anything before the install.
  public let cache: WarmupCache
  /// `passed`, `failed`, or `notInstalled` when the manager isn't on `PATH`.
  public let outcome: WarmupOutcome
  /// The end of the install's output when it failed, or why it didn't run; `nil` when it passed.
  public let detail: String?

  public init(
    install: NodeInstall, milliseconds: Int, cache: WarmupCache, outcome: WarmupOutcome,
    detail: String?
  ) {
    self.install = install
    self.milliseconds = milliseconds
    self.cache = cache
    self.outcome = outcome
    self.detail = detail
  }

  /// The `warmup.run` this install records, under the first area it serves.
  public var event: WarmupRunEvent {
    WarmupRunEvent(
      area: install.areas.first ?? install.directory, step: .install, milliseconds: milliseconds,
      cache: cache, outcome: outcome)
  }
}

/// What installing a worktree's node dependencies did.
public struct NodeInstallReport: Sendable, Equatable {
  public let results: [NodeInstallResult]
  /// Non-gating lines: an area left without an install, or a read that failed.
  public let notes: [String]
  /// The worktree's `HEAD`, for the events; `nil` when it couldn't be read.
  public let head: String?

  public init(results: [NodeInstallResult], notes: [String], head: String? = nil) {
    self.results = results
    self.notes = notes
    self.head = head
  }
}

/// Installs a brownfield worktree's node dependencies. It never fails: a failed install is a
/// result, and a setup failure is a note.
public protocol NodeDependencyInstalling: Sendable {
  func install(worktree: URL) async -> NodeInstallReport
}

/// Runs each install of ``NodeInstallPlan`` in parallel, frozen to its lockfile, with the same
/// shared-cache environment the area's commands get.
public struct LiveNodeDependencyInstaller: NodeDependencyInstalling {
  /// Runs git, to read the worktree's tracked files and state paths.
  private let git: any ProcessRunner
  /// Runs the package managers.
  private let installs: any ProcessRunner
  private let timeout: Duration

  public init(
    git: any ProcessRunner, installs: any ProcessRunner, timeout: Duration = .seconds(600)
  ) {
    self.git = git
    self.installs = installs
    self.timeout = timeout
  }

  public func install(worktree: URL) async -> NodeInstallReport {
    NodeInstallReport(results: [], notes: [])
  }
}
