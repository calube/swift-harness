import ArgumentParser
import Foundation
import SwiftGateDomain
import SwiftGateRules

/// Reads each named markdown file and runs ``ProseRules`` over it with the repository's
/// `[docs] sentence_ceiling`. An unreadable file blocks the run rather than passing it unread.
enum ProseCheck {
  static func run(root: URL, files: [String]) -> StaticCheckOutcome {
    guard !files.isEmpty else { return .blocked(reason: "prose: no files given") }
    let ceiling: Int
    switch StaticCheckInputs.loadConfig(root: root) {
    case .success(let config):
      ceiling = config?.docs.sentenceCeiling ?? DocsConfig.defaultSentenceCeiling
    case .failure(let failure): return failure.outcome
    }
    var findings: [Finding] = []
    for file in files {
      let url = URL(filePath: file, relativeTo: root)
      let text: String
      do {
        text = try String(contentsOf: url, encoding: .utf8)
      } catch {
        return .blocked(reason: "prose: can't read \(file): \(error.localizedDescription)")
      }
      do throws(ReportContractViolation) {
        findings += try ProseRules.check(text, file: file, sentenceCeiling: ceiling)
      } catch {
        return .blocked(reason: "prose: \(error)")
      }
    }
    return .checked(RuleRunResult(findings: findings, allowances: []))
  }
}

struct ProseCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "prose",
    abstract:
      "Mechanical plain-English checks over markdown: adverbs, em-dashes, number words, passive "
      + "voice, filler and jargon, and a sentence-length ceiling.",
    discussion:
      "Skips frontmatter, fenced code and diagrams, tables, inline code and HTML comments. "
      + "The sentence ceiling comes from [docs] sentence_ceiling. Exit 0 clean, 1 on a finding, "
      + "2 when a file can't be read.")

  @Argument(help: "The markdown files to check.")
  var files: [String]

  @OptionGroup var output: OutputOptions

  func run() async throws {
    let root = URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
    try await StaticCheckRun.execute(root: root, format: output.format) {
      ProseCheck.run(root: root, files: files)
    }
  }
}
