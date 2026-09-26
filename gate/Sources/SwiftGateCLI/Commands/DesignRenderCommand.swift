import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain

/// Gathers a design page's inputs through `design-lint`'s and `evidence check`'s own code paths,
/// then hands them to ``DesignRender``. Refuses, writing nothing, when the doc fails design-lint.
enum DesignRenderRun {
  struct Options: Sendable, Equatable {
    var design: String
    var packageResolved: String
    var sdk: String?
  }

  enum Outcome: Sendable, Equatable {
    /// `path` is repo-relative; `capabilities` is the Artifact tool's `capabilities` value.
    case written(path: String, designSha: String, capabilities: String, notes: [String])
    /// design-lint's gating findings; no HTML was written.
    case lintFailed([Finding])
    case blocked(String)
  }

  static func outputPath(for design: String) -> String {
    let file = design.split(separator: "/").last.map(String.init) ?? design
    let slug = file.hasSuffix(".md") ? String(file.dropLast(3)) : file
    return ".harness/design-render/\(slug).html"
  }

  static func run(options: Options, root: URL, git: any Git, runner: any ProcessRunner) async
    -> Outcome
  {
    let lint = await DesignLintCheck.run(
      root: root, docPath: options.design, git: git, processRunner: runner)
    switch lint {
    case .blocked(let reason): return .blocked(reason)
    case .invalid(let reason, let file): return .blocked("\(file): \(reason)")
    case .checked(let result):
      let gating = result.findings.filter { $0.severity.failsGate }
      if !gating.isEmpty { return .lintFailed(gating) }
    }

    let docURL = root.appending(path: options.design, directoryHint: .notDirectory)
    let rawText: String
    do {
      rawText = try String(contentsOf: docURL, encoding: .utf8)
    } catch {
      return .blocked("can't read \(options.design): \(error.localizedDescription)")
    }

    var notes: [String] = []
    var claims: [Claim] = []
    var results: [EvidenceCheckResult] = []
    let claimsFile = EvidenceLayout(designDocPath: options.design).claimsFile
    if FileManager.default.fileExists(atPath: root.appending(path: claimsFile).path) {
      let evidence = await EvidenceCheckRun.run(
        options: .init(
          design: options.design, at: nil, packageResolved: options.packageResolved,
          sdk: options.sdk),
        root: root, runner: runner)
      switch evidence {
      case .blocked(let message): return .blocked("evidence check: \(message)")
      case .checked(let checkedClaims, let checkResults):
        claims = checkedClaims
        results = checkResults
      }
    } else {
      notes.append("\(claimsFile) doesn't exist; the page shows no cited evidence.")
    }

    let page = DesignRender.page(
      .init(rawText: rawText, claims: claims, checkResults: results))
    let path = outputPath(for: options.design)
    let outputURL = root.appending(path: path, directoryHint: .notDirectory)
    do {
      try FileManager.default.createDirectory(
        at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(page.html.utf8).write(to: outputURL, options: .atomic)
    } catch {
      return .blocked("can't write \(path): \(error.localizedDescription)")
    }
    return .written(
      path: path, designSha: DesignSha.of(rawText), capabilities: page.capabilityDeclaration,
      notes: notes)
  }

  static func render(_ outcome: Outcome, design: String, format: OutputFormat) -> String {
    switch format {
    case .json:
      var json = DesignRenderJSON(design: design)
      switch outcome {
      case .written(let path, let designSha, let capabilities, let notes):
        json.verdict = Verdict.green.rawValue
        json.output = path
        json.designSha = designSha
        json.capabilities = capabilities
        json.notes = notes
      case .lintFailed(let findings):
        json.verdict = Verdict.red.rawValue
        json.findings = findings.map(describe)
      case .blocked(let message):
        json.verdict = Verdict.blocked.rawValue
        json.message = message
      }
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      return (try? encoder.encode(json)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    case .human:
      switch outcome {
      case .written(let path, let designSha, let capabilities, let notes):
        let lines = [
          "design-render: \(Verdict.green.rawValue) wrote \(path)", "  designSha \(designSha)",
          "  publish with capabilities \(capabilities)",
        ]
        return (lines + notes.map { "  note: \($0)" }).joined(separator: "\n")
      case .lintFailed(let findings):
        let head =
          "design-render: \(Verdict.red.rawValue) design-lint found \(findings.count) gating "
          + "finding(s); nothing was written"
        return ([head] + findings.map { "  \(describe($0))" }).joined(separator: "\n")
      case .blocked(let message):
        return "design-render: \(Verdict.blocked.rawValue) \(message)"
      }
    }
  }

  private static func describe(_ finding: Finding) -> String {
    "\(finding.file): \(finding.ruleID): \(finding.message)"
  }

  static func exitCode(_ outcome: Outcome) -> Int32 {
    switch outcome {
    case .written: Verdict.green.exitCode
    case .lintFailed: Verdict.red.exitCode
    case .blocked: Verdict.blocked.exitCode
    }
  }
}

/// `--json` shape. Keys absent for an outcome are omitted.
struct DesignRenderJSON: Encodable {
  var command = "design-render"
  var verdict = ""
  var design: String
  var output: String?
  var designSha: String?
  var capabilities: String?
  var notes: [String]?
  var findings: [String]?
  var message: String?

  init(design: String) {
    self.design = design
  }
}

struct DesignRenderCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "design-render",
    abstract: "Render a design doc's Artifact page: diagrams, options, evidence badges, approval.",
    discussion:
      "Runs design-lint and evidence check over the doc, then writes "
      + ".harness/design-render/<slug>.html for the design skill to publish with the printed "
      + "capabilities. Exit 0 written, 1 when design-lint finds a gating problem (nothing is "
      + "written), 2 when the doc, its claims or the output can't be read or written.")

  @Argument(help: "The repo-relative design doc to render.")
  var doc: String

  @Option(help: "The repo-relative Package.resolved that package pins are checked against.")
  var packageResolved = "Package.resolved"

  @Option(help: "The SDK version now in effect; defaults to what xcrun reports.")
  var sdk: String?

  @OptionGroup var output: OutputOptions

  func run() async throws {
    let root = URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
    let runner = LiveProcessRunner()
    let outcome = await DesignRenderRun.run(
      options: .init(design: doc, packageResolved: packageResolved, sdk: sdk), root: root,
      git: LiveGit(runner: runner, repositoryRoot: root.path), runner: runner)
    Console.write(DesignRenderRun.render(outcome, design: doc, format: output.format))
    let code = DesignRenderRun.exitCode(outcome)
    if code != 0 { throw ExitCode(code) }
  }
}
