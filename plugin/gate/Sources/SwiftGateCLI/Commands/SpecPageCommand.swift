import ArgumentParser
import Foundation
import SwiftGateDomain

/// Reads the page and the spec file and renders the domain's report.
enum SpecPageCheckRun {
  struct Result: Sendable, Equatable {
    let output: String
    let exitCode: Int32
  }

  static let command = "spec-page check"

  static func run(pagePath: String, specPath: String, json: Bool) -> Result {
    let pageData: Data
    do {
      pageData = try Data(contentsOf: URL(filePath: pagePath))
    } catch {
      return blocked(
        "can't read the spec page \(pagePath): \(error.localizedDescription)", nil, json)
    }
    let pageSha = SpecPageCheck.pageSha(pageData)
    guard let page = String(data: pageData, encoding: .utf8) else {
      return blocked("the spec page \(pagePath) isn't UTF-8 text", pageSha, json)
    }
    let spec: String
    do {
      spec = try String(contentsOf: URL(filePath: specPath), encoding: .utf8)
    } catch {
      return blocked(
        "can't read the spec file \(specPath) as UTF-8 text: \(error.localizedDescription)",
        pageSha,
        json)
    }
    let report: SpecPageReport
    do {
      report = try SpecPageCheck.check(page: page, pagePath: pagePath, spec: spec)
    } catch {
      return blocked("\(command) built an invalid finding: \(error)", pageSha, json)
    }
    let output = Output(
      command: command, verdict: report.verdict, message: nil,
      confirm: report.confirm?.rawValue, pageSha: pageSha,
      slices: (report.page?.slices ?? []).map(Output.Slice.init), findings: report.findings)
    return Result(output: render(output, json: json), exitCode: report.verdict.exitCode)
  }

  private static func blocked(_ message: String, _ pageSha: String?, _ json: Bool) -> Result {
    let output = Output(
      command: command, verdict: .blocked, message: message, confirm: nil, pageSha: pageSha,
      slices: [], findings: [])
    return Result(output: render(output, json: json), exitCode: Verdict.blocked.exitCode)
  }

  /// The `--json` report. Every key is always present; an absent value is `null`.
  struct Output: Encodable {
    struct Slice: Encodable {
      let number: Int
      let id: String
      let test: String
      let tier: String
      let line: Int
      let quote: String?

      init(_ slice: SpecPage.Slice) {
        number = slice.number
        id = slice.id
        test = slice.testName
        tier = slice.tier.rawValue
        line = slice.line
        switch slice.spec {
        case .quote(let text): quote = text
        case .none: quote = nil
        }
      }

      private enum CodingKeys: String, CodingKey { case number, id, test, tier, line, quote }

      func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(number, forKey: .number)
        try c.encode(id, forKey: .id)
        try c.encode(test, forKey: .test)
        try c.encode(tier, forKey: .tier)
        try c.encode(line, forKey: .line)
        try c.encode(quote, forKey: .quote)
      }
    }

    let command: String
    let verdict: Verdict
    let message: String?
    let confirm: String?
    let pageSha: String?
    let slices: [Slice]
    let findings: [Finding]

    private enum CodingKeys: String, CodingKey {
      case command, verdict, message, confirm, pageSha, slices, findings
    }

    func encode(to encoder: any Encoder) throws {
      var c = encoder.container(keyedBy: CodingKeys.self)
      try c.encode(command, forKey: .command)
      try c.encode(verdict, forKey: .verdict)
      try c.encode(message, forKey: .message)
      try c.encode(confirm, forKey: .confirm)
      try c.encode(pageSha, forKey: .pageSha)
      try c.encode(slices, forKey: .slices)
      try c.encode(findings, forKey: .findings)
    }
  }

  static func render(_ output: Output, json: Bool) -> String {
    if json {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      let data = (try? encoder.encode(output)) ?? Data()
      return String(decoding: data, as: UTF8.self)
    }
    var lines = ["\(output.command): \(output.verdict.rawValue)"]
    if let message = output.message { lines.append(message) }
    if let confirm = output.confirm { lines.append("confirm: \(confirm)") }
    if let pageSha = output.pageSha { lines.append("pageSha: \(pageSha)") }
    for slice in output.slices {
      lines.append("\(slice.id) \(slice.tier) \(slice.quote == nil ? "none" : "quote")")
    }
    for finding in output.findings {
      let location = finding.line.map { "\(finding.file):\($0)" } ?? finding.file
      lines.append(
        "\(finding.ruleID) [\(finding.severity.rawValue)] \(location): \(finding.message)")
    }
    return lines.joined(separator: "\n")
  }
}

struct SpecPageCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "spec-page",
    abstract: "Check a spec page (fast modes §5.2).",
    subcommands: [SpecPageCheckCommand.self])
}

struct SpecPageCheckCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "check",
    abstract: "Check a spec page's format and length, and its Spec: quotes against the spec file.",
    discussion:
      "Prints confirm: required when a slice says Spec: none or quotes a line the spec file "
      + "doesn't hold word for word, else skippable; each slice's id, slice-<n>-<kebab test "
      + "name>; and pageSha, the SHA-256 of the page's bytes. Exit 0 GREEN, 1 RED on a "
      + "spec-page.format, spec-page.too-long or spec-page.quote-not-in-spec finding, 2 when "
      + "the page or the spec file can't be read.")

  @Argument(help: "The spec page.")
  var page: String

  @Option(help: "The spec file the page quotes.")
  var spec: String

  @Flag(help: "Print JSON.")
  var json = false

  func run() async throws {
    let result = SpecPageCheckRun.run(pagePath: page, specPath: spec, json: json)
    Console.write(result.output)
    if result.exitCode != 0 { throw ExitCode(result.exitCode) }
  }
}
