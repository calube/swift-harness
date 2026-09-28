import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateRules

/// Wires the commit reader to the body scan and the domain's judgement.
enum SurfaceCheckRun {
  static func judgements(commit: String, reader: any SurfaceCommitReading)
    async throws(SurfaceReadError) -> (SurfaceCommit, [SurfaceJudgement])
  {
    let surface = try await reader.read(commit)
    let callees = surface.changes.reduce(into: Set<String>()) {
      $0.formUnion(SurfaceBodyScan.forwardCallees(in: $1))
    }
    // The parent's whole tree is parsed only when some body could forward into it.
    let parent =
      callees.isEmpty
      ? SurfaceParentIndex(functions: [], types: [])
      : SurfaceParentIndex.build(try await reader.parentSwiftSources(of: surface))
    let judgements = SurfaceCheck.judge(surface) { SurfaceBodyScan.judge($0, parent: parent) }
    return (surface, judgements)
  }

  static func outcome(commit: String, reader: any SurfaceCommitReading) async
    -> StaticCheckOutcome
  {
    do {
      let (surface, judgements) = try await judgements(commit: commit, reader: reader)
      return .checked(
        RuleRunResult(
          findings: try SurfaceCheck.findings(surface, judgements: judgements), allowances: []))
    } catch let error as SurfaceReadError {
      return .blocked(reason: describe(error, commit: commit))
    } catch {
      return .blocked(reason: "surface-check: \(error)")
    }
  }

  static func describe(_ error: SurfaceReadError, commit: String) -> String {
    switch error {
    case .unknownCommit(let name): "surface-check: `\(name)` names no commit"
    case .parentUnavailable(let sha):
      "surface-check: can't load the first parent of \(sha) (a root commit, or a shallow clone "
        + "without it)"
    case .missingPath(let path):
      "surface-check: git lists `\(path)` as changed in \(commit), but neither side holds it"
    case .git(let error): "surface-check: git failed reading \(commit): \(error)"
    }
  }
}

struct SurfaceCheckCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "surface-check",
    abstract: "Check that a surface commit adds API and no behaviour (fast modes §3.2).",
    discussion:
      "Diffs the commit against its first parent and judges every added or changed body in its "
      + "Swift files: each must be empty, return 1 empty default (nil, [], [:], 0, false, \"\", "
      + ".init()) or a payload-free enum case, or forward to code the parent already declares. "
      + "A reducer returns .none for every action, a SwiftUI body is EmptyView() or a container "
      + "of it, a preview holds no non-empty sample data, and the commit adds no test. Exit 0 "
      + "clean, 1 on any surface-check.behaviour finding, 2 when the commit or its first parent "
      + "can't be read.")

  @Argument(help: "The commit to check.")
  var commit: String

  @OptionGroup var output: OutputOptions

  func run() async throws {
    let root = URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
    let reader = LiveSurfaceCommitReader(runner: LiveProcessRunner(), repositoryRoot: root.path)
    try await StaticCheckRun.execute(root: root, format: output.format) {
      await SurfaceCheckRun.outcome(commit: commit, reader: reader)
    }
  }
}
