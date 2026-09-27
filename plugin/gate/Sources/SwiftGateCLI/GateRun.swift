import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain

/// What a multi-tier command produced, before it becomes a ``RunReport``.
struct GateRunParts: Sendable {
  var tiers: [TierResult] = []
  var findings: [Finding] = []
  var allowances: [AllowanceCount] = []
}

/// Shared driver for commands that run tests: allocates the run (id and artifact directory),
/// times it, records the report and its history line, prints, and exits with the verdict.
enum GateRun {
  struct Context: Sendable {
    let runID: String
    /// Where the run's logs and reports go.
    let directory: URL
  }

  /// - Parameters:
  ///   - steps: `ready` steps a lower `check` tier added, recorded in the run's history line.
  ///   - proofBases: the refs `prove` retried at, recorded in the run's history line.
  static func execute(
    root: URL, format: OutputFormat, command: String, steps: [String]? = nil,
    proofBases: [String]? = nil, git: (any Git)? = nil,
    body: (Context) async throws -> GateRunParts
  ) async throws {
    let git = git ?? LiveGit(runner: LiveProcessRunner(), repositoryRoot: root.path)
    let clock = ContinuousClock()
    let startedAt = Date()
    let start = clock.now
    let runID = RunID.make(startedAt: startedAt, suffix: UInt32.random(in: .min ... .max))
    let store = RunStore(worktreeRoot: root)
    let directory: URL
    do {
      directory = try store.runDirectory(for: runID)
    } catch {
      // Artifacts are diagnostics; without the run directory they go to a temporary one.
      directory = FileManager.default.temporaryDirectory.appending(
        path: "swiftgate-\(runID)", directoryHint: .isDirectory)
    }
    // Belt and braces beside every invocation's own --only-use-versions-from-resolved-file /
    // -onlyUsePackageVersionsFromResolvedFile: whatever `body` runs must never rewrite a committed
    // Package.resolved, on any path those flags missed.
    let resolvedFilesBefore = await ResolvedFileGuard.snapshot(root: root, git: git)
    var parts = try await body(Context(runID: runID, directory: directory))
    let resolvedFilesAfter = await ResolvedFileGuard.snapshot(root: root, git: git)
    if let finding = try ResolvedFileGuard.finding(
      before: resolvedFilesBefore, after: resolvedFilesAfter)
    {
      parts.findings.append(finding)
    }
    let report = try RunReport(
      runID: runID, durationMilliseconds: milliseconds(clock.now - start), tiers: parts.tiers,
      findings: parts.findings, allowances: parts.allowances)
    do {
      try store.record(
        report, finishedAt: Date(), command: command, steps: steps, proofBases: proofBases)
    } catch {
      FileHandle.standardError.write(Data("swiftgate: could not record run: \(error)\n".utf8))
    }
    Console.write(try ReportRenderer.render(report, format: format))
    let status = report.verdict.exitCode
    if status != 0 { throw ExitCode(status) }
  }

  static func milliseconds(_ duration: Duration) -> Int {
    Int(duration.components.seconds * 1000)
      + Int(duration.components.attoseconds / 1_000_000_000_000_000)
  }

  /// Times `body` on a continuous clock.
  static func timed<T>(_ body: () async throws -> T) async rethrows -> (T, Int) {
    let clock = ContinuousClock()
    let start = clock.now
    let value = try await body()
    return (value, milliseconds(clock.now - start))
  }
}

/// Paths changed since a ref, relative to this project's root (which may sit inside a larger
/// repository).
enum ChangedPaths {
  static func since(_ ref: String, git: any Git) async throws(GitError) -> [String] {
    let prefix = try await git.workingDirectoryPrefix()
    return try await git.changedFiles(since: ref)
      .filter { $0.hasPrefix(prefix) }
      .map { String($0.dropFirst(prefix.count)) }
  }
}
