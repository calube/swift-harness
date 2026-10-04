import SwiftGateDomain
import SwiftGateTestSupport
import Testing

/// A captured area run, read as the area runner would hand it over: both streams whole, and the
/// lines its `change.diff` adds.
private struct CapturedLintRun {
  let run: LintRunOutput
  let added: [AddedLines]

  init(_ ecosystem: String, case name: String = "lint", areaRoot: String = ".") throws {
    let directory = "AreaRuns/\(ecosystem)/\(name)"
    let exit = try Fixture.text("\(directory)/exit").trimmingCharacters(in: .whitespacesAndNewlines)
    run = LintRunOutput(
      area: ecosystem, areaRoot: areaRoot, repositoryRoot: "<repo>",
      exitStatus: Int32(exit) ?? -1,
      streams: [try Fixture.text("\(directory)/stdout"), try Fixture.text("\(directory)/stderr")])
    added = try Self.addedLines(Fixture.text("\(directory)/change.diff"))
  }

  /// The new-side line numbers of each `+` line, per `+++ b/` file.
  private static func addedLines(_ diff: String) -> [AddedLines] {
    var result: [AddedLines] = []
    var path: String?
    var lines: [Int] = []
    var next = 0
    func flush() {
      if let path, !lines.isEmpty {
        result.append(AddedLines(path: path, ranges: lines.map { $0...$0 }))
      }
    }
    for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
      if line.hasPrefix("+++ b/") {
        flush()
        path = String(line.dropFirst("+++ b/".count))
        lines = []
      } else if line.hasPrefix("@@ ") {
        next = Int(line.split(separator: " ")[2].dropFirst().split(separator: ",")[0]) ?? 0
      } else if line.hasPrefix("+") {
        lines.append(next)
        next += 1
      } else if line.hasPrefix(" ") {
        next += 1
      }
    }
    flush()
    return result
  }
}

private func located(_ reading: LintReading) -> [String] {
  reading.findings.map { "\($0.path):\($0.line) \($0.rule ?? "-")" }.sorted()
}

@Suite("lint output parser")
struct LintOutputParserTests {
  static let expected: [(ecosystem: String, areaRoot: String, findings: [String])] = [
    (
      "python", ".",
      [
        "gguf-py/gguf/utility.py:8 F401", "gguf-py/gguf/utility.py:342 E302",
        "gguf-py/gguf/utility.py:343 F841", "gguf-py/gguf/utility.py:343 W291",
      ]
    ),
    (
      "node", "packages/api",
      [
        "packages/api/src/dpi.ts:478 @typescript-eslint/no-unused-vars",
        "packages/api/src/dpi.ts:479 @typescript-eslint/no-unused-vars",
        "packages/api/src/dpi.ts:480 no-console",
      ]
    ),
    ("go", ".", ["tools/list/list.go:165 unused", "tools/list/list.go:167 ineffassign"]),
    (
      "cargo", ".",
      [
        "crates/ruff_text_size/src/size.rs:221 clippy::ptr_arg",
        "crates/ruff_text_size/src/size.rs:221 dead_code",
        "crates/ruff_text_size/src/size.rs:221 unreachable_pub",
        "crates/ruff_text_size/src/size.rs:222 clippy::len_zero",
      ]
    ),
    (
      "gradle", ".",
      ["okhttp-sse/src/main/kotlin/okhttp3/sse/EventSources.kt:18 standard:no-wildcard-imports"]
    ),
    ("maven", ".", ["README.md:301 NoHttp"]),
    (
      "ruby", ".",
      [
        "app/lib/hashtag_normalizer.rb:10 Style/RedundantReturn",
        "app/lib/hashtag_normalizer.rb:10 Style/StringConcatenation",
        "app/lib/hashtag_normalizer.rb:10 Style/StringLiterals",
        "app/lib/hashtag_normalizer.rb:9 Lint/UselessAssignment",
      ]
    ),
    (
      "swift", ".",
      [
        "ElementX/Sources/Other/Extensions/Array.swift:100 force_cast",
        "ElementX/Sources/Other/Extensions/Array.swift:101 force_unwrapping",
      ]
    ),
  ]

  @Test(
    "each captured linter's output yields its findings at repository-relative paths and lines — catches a format misread, a module- or area-relative path left unresolved, or a rule id lost",
    arguments: expected.indices)
  func capturedLintOutput(index: Int) throws {
    let entry = Self.expected[index]
    let captured = try CapturedLintRun(entry.ecosystem, areaRoot: entry.areaRoot)

    let reading = LintOutputParser.read(captured.run, added: captured.added)

    #expect(located(reading) == entry.findings.sorted(), "\(entry.ecosystem)")
    #expect(reading.notes == [], "\(entry.ecosystem)")
  }

  @Test(
    "a finding on a line the change didn't add is dropped, even in a changed file — catches whole-file lint findings gating untouched code"
  )
  func untouchedLineDropped() throws {
    let captured = try CapturedLintRun("python")
    let withoutImport = captured.added.map { file in
      AddedLines(path: file.path, ranges: file.ranges.filter { !$0.contains(8) })
    }

    let reading = LintOutputParser.read(captured.run, added: withoutImport)

    #expect(
      located(reading) == [
        "gguf-py/gguf/utility.py:342 E302", "gguf-py/gguf/utility.py:343 F841",
        "gguf-py/gguf/utility.py:343 W291",
      ])
  }

  @Test(
    "a failing lint run whose output holds no format the parser reads is a note naming the area — catches an unknown linter read as a clean pass"
  )
  func unknownFormatIsANote() throws {
    // `go test -json` is no lint format; its status is 1 and its lines are JSON events.
    let captured = try CapturedLintRun("go", case: "test-fail")

    let reading = LintOutputParser.read(captured.run, added: captured.added)

    #expect(reading.findings == [])
    #expect(reading.notes.count == 1)
    #expect(reading.notes.first?.area == "go")
    #expect(reading.notes.first?.text.contains("TestSubtractSliceString") == true)
  }

  @Test(
    "a finding becomes a neutral.lint finding at its path and line, its message led by the linter's rule — catches the rule id or location lost on the way to the report"
  )
  func reportsAsNeutralLint() throws {
    let captured = try CapturedLintRun("maven")
    let lint = try #require(
      LintOutputParser.read(captured.run, added: captured.added).findings.first)

    let finding = try lint.finding(severity: .major)

    #expect(finding.ruleID == "neutral.lint")
    #expect(finding.file == "README.md")
    #expect(finding.line == 301)
    #expect(finding.message.hasPrefix("NoHttp: http:// URLs are not allowed"))
  }
}
