import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateRules

/// Changed Core, client and Live sources must come with a change to their module's tests.
enum ImpactCheck {
  static func run(root: URL, git: any Git, base: String) async -> StaticCheckOutcome {
    let changed: [String]
    do throws(GitError) {
      guard let mergeBase = try await git.mergeBase("HEAD", base) else {
        return .blocked(reason: "HEAD and \(base) share no history; pass --base <ref>")
      }
      changed = try await git.changedFiles(since: mergeBase)
    } catch {
      return .blocked(reason: "git: \(error)")
    }
    let exemptions: ImpactExemptions
    do throws(ImpactExemptionsLoadError) {
      exemptions = try ImpactExemptionsLoader(root: root).load()
    } catch {
      switch error.verdict {
      case .red:
        return .invalid(reason: error.description, file: ImpactExemptions.fileName)
      case .blocked, .green:
        return .blocked(reason: error.description)
      }
    }
    do {
      let result = try ImpactAnalysis.evaluate(
        changedFiles: changed, scopes: PathConventionModuleScopes(), exemptions: exemptions)
      return .checked(
        RuleRunResult(
          findings: result.findings,
          allowances: result.waived.map {
            Allowance(ruleID: ImpactAnalysis.ruleID, path: $0.path, line: nil, reason: $0.reason)
          }))
    } catch {
      return .blocked(reason: "impact: \(error)")
    }
  }
}

struct ImpactCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "impact",
    abstract: "Require a test change for every changed Core, client or Live module.")

  @Option(help: "Compare against the merge base of HEAD and this ref.")
  var base = "origin/main"

  @OptionGroup var output: OutputOptions

  func run() async throws {
    let root = URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
    let git = LiveGit(runner: LiveProcessRunner(), repositoryRoot: root.path)
    try await StaticCheckRun.execute(root: root, format: output.format) {
      await ImpactCheck.run(root: root, git: git, base: base)
    }
  }
}
