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
    let tracked = GitTrackedTree(runner: git, directory: worktree)
    let layout: BrownfieldStateLayout
    let snapshot: TrackedTreeSnapshot
    do {
      layout = try await tracked.stateLayout()
      snapshot = try await tracked.snapshot()
    } catch {
      return NodeInstallReport(
        results: [],
        notes: ["node install: couldn't read \(worktree.path)'s tracked files: \(error)"])
    }
    let head = try? await tracked.head()
    let config: BrownfieldConfig
    do throws(ProfileLoadError) {
      guard
        case .brownfield(let loaded)? = try ConfigLoader().loadProfile(
          repositoryRoot: worktree, commonDir: layout.commonDir)
      else {
        return NodeInstallReport(
          results: [], notes: ["node install: \(layout.config.path) holds no brownfield config"],
          head: head)
      }
      config = loaded
    } catch {
      return NodeInstallReport(
        results: [], notes: ["node install: reading \(layout.config.path): \(error)"], head: head)
    }

    let plan = NodeInstallPlan.plan(areas: config.areas, tree: snapshot)
    let areas = Dictionary(
      config.areas.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
    let ran = await withTaskGroup(of: (Int, NodeInstallResult, String?).self) { group in
      for (index, install) in plan.installs.enumerated() {
        let environment =
          install.areas.first.flatMap { areas[$0] }.map {
            AreaCacheEnvironment.make(area: $0, layout: layout, tree: snapshot).variables
          } ?? [:]
        group.addTask {
          let (result, note) = await run(install, in: worktree, environment: environment)
          return (index, result, note)
        }
      }
      var collected: [(Int, NodeInstallResult, String?)] = []
      for await entry in group { collected.append(entry) }
      return collected.sorted { $0.0 < $1.0 }
    }
    return NodeInstallReport(
      results: ran.map(\.1), notes: plan.notes + ran.compactMap(\.2), head: head)
  }

  /// 1 install, and a note when its cache's state couldn't be read.
  private func run(_ install: NodeInstall, in worktree: URL, environment: [String: String])
    async -> (NodeInstallResult, String?)
  {
    var root = worktree.path(percentEncoded: false)
    while root.count > 1, root.hasSuffix("/") { root.removeLast() }
    let directory = install.directory == "." ? root : "\(root)/\(install.directory)"
    let overlay = environment.mapValues { Optional($0) }
    let (cache, note) = await cacheState(install, directory: directory, overlay: overlay)
    let started = ContinuousClock.now
    let outcome: WarmupOutcome
    let detail: String?
    do throws(ProcessRunnerError) {
      let output = try await installs.run(
        ProcessInvocation(
          executable: install.manager.rawValue, arguments: install.arguments,
          environmentOverlay: overlay, workingDirectory: directory, timeout: timeout))
      switch output.status {
      case .exited(0):
        (outcome, detail) = (.passed, nil)
      case .exited(let code):
        (outcome, detail) = (.failed, "exit \(code): " + Self.tail(output))
      case .signaled(let signal):
        (outcome, detail) = (.failed, "killed by signal \(signal): " + Self.tail(output))
      }
    } catch {
      switch error {
      case .launchFailed(_, let reason):
        (outcome, detail) = (.notInstalled, "\(install.manager.rawValue): \(reason)")
      case .timedOut(_, let after, let stdout, let stderr):
        (outcome, detail) = (
          .failed,
          "timed out after \(after): "
            + Self.tail(
              ProcessOutput(status: .signaled(9), stdout: stdout, stderr: stderr, elapsed: after))
        )
      case .cancelled:
        (outcome, detail) = (.failed, "cancelled")
      }
    }
    let elapsed = ContinuousClock.now - started
    let milliseconds = Int(
      elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
    return (
      NodeInstallResult(
        install: install, milliseconds: milliseconds, cache: cache, outcome: outcome,
        detail: detail),
      note
    )
  }

  /// `warm` when the directory the manager names as its cache holds anything. A cache path that
  /// can't be read counts as `cold`, with a note saying so.
  private func cacheState(
    _ install: NodeInstall, directory: String, overlay: [String: String?]
  ) async -> (WarmupCache, String?) {
    let question = ([install.manager.rawValue] + install.cachePathArguments).joined(separator: " ")
    let output: ProcessOutput
    do throws(ProcessRunnerError) {
      output = try await installs.run(
        ProcessInvocation(
          executable: install.manager.rawValue, arguments: install.cachePathArguments,
          environmentOverlay: overlay, workingDirectory: directory, timeout: .seconds(30)))
    } catch {
      return (
        .cold, "\(install.directory): `\(question)` failed (\(error)); install recorded as cold"
      )
    }
    let path = output.stdout.text.split(whereSeparator: \.isNewline).last.map {
      $0.trimmingCharacters(in: .whitespaces)
    }
    guard output.status.isSuccess, let path, path.hasPrefix("/") else {
      return (
        .cold,
        "\(install.directory): `\(question)` printed no cache path; install recorded as cold"
      )
    }
    let entries = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
    return (entries.isEmpty ? .cold : .warm, nil)
  }

  /// The last 40 lines of the install's output, stdout then stderr.
  static func tail(_ output: ProcessOutput) -> String {
    let lines = (output.stdout.text + output.stderr.text).split(
      separator: "\n", omittingEmptySubsequences: false)
    return lines.suffix(40).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
