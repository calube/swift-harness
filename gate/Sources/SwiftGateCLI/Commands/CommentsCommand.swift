import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateRules

/// Mechanical comment discipline on the lines a commit adds (standards K1–K2).
enum CommentsCheck {
  static func run(git: any Git, context: RuleContext = defaultContext) async -> StaticCheckOutcome {
    let added: [AddedLines]
    let contents: [String: String]
    do throws(GitError) {
      added = try await git.stagedAddedLines().filter { $0.path.hasSuffix(".swift") }
      contents = try await git.stagedContents(of: added.map(\.path))
    } catch {
      return .blocked(reason: "git: \(error)")
    }
    let inputs = added.compactMap { lines in
      contents[lines.path].map { SourceInput(path: lines.path, text: $0) }
    }
    return StaticCheck.evaluate(RuleCatalog.comments, inputs, context: context, restrictTo: added)
  }

  static let defaultContext = RuleContext(scopes: PathConventionModuleScopes())
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
      await CommentsCheck.run(git: git)
    }
  }
}
