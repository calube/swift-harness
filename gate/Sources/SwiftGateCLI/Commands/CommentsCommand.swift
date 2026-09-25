import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateRules

/// Mechanical comment discipline on the lines a commit adds (standards K1–K2).
enum CommentsCheck {
  /// Resolves module scopes from the repository's config, then checks.
  static func run(root: URL, git: any Git, swiftPM: any SwiftPM) async -> StaticCheckOutcome {
    let config: Config?
    switch StaticCheckInputs.loadConfig(root: root) {
    case .success(let loaded): config = loaded
    case .failure(let failure): return failure.outcome
    }
    switch await ScopeResolution.resolve(config: config, root: root, swiftPM: swiftPM) {
    case .failed(let outcome): return outcome
    case .resolved(let scopes):
      let collector = SwiftSourceCollector(root: root, excluding: config?.exclude ?? [])
      return await run(git: git, scopes: scopes, isExcluded: collector.isExcluded)
    }
  }

  /// - Parameter isExcluded: takes a project-relative path; excluded files are not checked.
  static func run(
    git: any Git, scopes: ResolvedScopes, isExcluded: (String) -> Bool = { _ in false }
  ) async -> StaticCheckOutcome {
    let prefix: String
    let added: [AddedLines]
    let contents: [String: String]
    do throws(GitError) {
      prefix = try await git.workingDirectoryPrefix()
      added = try await git.stagedAddedLines().filter {
        $0.path.hasSuffix(".swift") && $0.path.hasPrefix(prefix)
          && !isExcluded(String($0.path.dropFirst(prefix.count)))
      }
      contents = try await git.stagedContents(of: added.map(\.path))
    } catch {
      return .blocked(reason: "git: \(error)")
    }
    // Git paths are toplevel-relative; module scopes are relative to this project's root.
    let local = added.map {
      AddedLines(path: String($0.path.dropFirst(prefix.count)), ranges: $0.ranges)
    }
    let inputs = zip(added, local).compactMap { staged, lines in
      contents[staged.path].map { SourceInput(path: lines.path, text: $0) }
    }
    let context = RuleContext(scopes: scopes.resolver)
    return scopes.appendingNotices(
      to: StaticCheck.evaluate(RuleCatalog.comments, inputs, context: context, restrictTo: local))
  }
}

struct CommentsCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "comments",
    abstract: "Check comments on staged added lines (pre-commit).")

  @Flag(help: "Check the lines the staged change adds. Required; the only supported mode.")
  var staged = false

  @OptionGroup var output: OutputOptions

  func validate() throws {
    guard staged else { throw ValidationError("pass --staged") }
  }

  func run() async throws {
    let root = URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
    let git = LiveGit(runner: LiveProcessRunner(), repositoryRoot: root.path)
    try await StaticCheckRun.execute(root: root, format: output.format) {
      await CommentsCheck.run(
        root: root, git: git, swiftPM: ScopeResolution.liveSwiftPM(root: root))
    }
  }
}
