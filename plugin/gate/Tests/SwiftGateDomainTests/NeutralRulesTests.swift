import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@Suite("neutral rules on added lines")
struct NeutralRulesTests {
  /// What 1 captured diff must yield: `U<line>` an unsafe shortcut, `N<line>` an assertion-free
  /// test no judge can rescue, `J<line>` a candidate for the judge cascade.
  static let expected: [String: Set<String>] = [
    "go/nolint": ["U958"],
    "go/skipped-test": ["U63"],
    "go/test-no-assertion": ["J720"],
    "go/test-with-assertion": [],
    "java/ignored-test": ["U156"],
    "java/suppress-warnings": ["U1"],
    "java/test-with-assertion": [],
    "kotlin/bang-bang": ["U71", "U74"],
    "kotlin/ignored-test": ["U29", "J31"],
    "kotlin/suppress": ["U31"],
    "kotlin/test-no-assertion": ["J967"],
    "kotlin/test-with-assertion": [],
    "python/noqa-type-ignore": ["U4", "U6"],
    "python/skipped-test": ["U1428"],
    "python/test-no-assertion": ["J4"],
    "python/test-with-assertion": [],
    "ruby/rubocop-disable": ["U200"],
    "ruby/skipped-test": ["U30"],
    "ruby/test-no-assertion": ["J183"],
    "ruby/test-with-assertion": [],
    "rust/clippy-allow": ["U621"],
    "rust/ignored-test": ["U1041"],
    "rust/test-no-assertion": ["J167"],
    "rust/test-with-assertion": [],
    "swift/as-bang": ["U80"],
    "swift/disabled-test": ["U29"],
    "swift/fatal-error": ["U852"],
    "swift/fp-comment-fatal-error": [],
    "swift/fp-comment-try-bang": [],
    "swift/fp-string-as-bang": [],
    "swift/nonisolated-unsafe": ["U8"],
    "swift/swiftlint-disable": ["U36"],
    "swift/test-no-assertion": ["J276"],
    "swift/test-with-assertion": [],
    "swift/try-bang": ["U60", "U62", "U65"],
    "swift/unchecked-sendable": ["U84"],
    "swift/xctskip-test": ["U65"],
    "typescript/as-any": ["U27"],
    "typescript/eslint-disable": ["U32"],
    "typescript/focused-test": ["U1122"],
    "typescript/fp-comment-as-any": [],
    "typescript/fp-string-as-any": [],
    // An empty body is assertion-free whatever a helper does, so it needs no judge.
    "typescript/skipped-test": ["U3", "N3"],
    "typescript/test-no-assertion": ["J5"],
    "typescript/test-with-assertion": [],
    "typescript/ts-expect-error": ["U11", "U12"],
    "typescript/ts-ignore": ["U13", "U14"],
  ]

  /// The new side of a captured single-file diff: its context and added lines, and whether the
  /// last hunk reaches the end of the file (fewer than git's 3 trailing context lines).
  static func source(fromDiff diff: String) throws -> (NeutralSource, AddedLines) {
    var path: String?
    var isNewFile = false
    var lines: [NeutralSourceLine] = []
    var ranges: [ClosedRange<Int>] = []
    var next = 0
    var trailingContext = 0
    var inHunk = false
    for raw in diff.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
      if !inHunk, raw.hasPrefix("--- ") {
        isNewFile = raw == "--- /dev/null"
      } else if !inHunk, raw.hasPrefix("+++ b/") {
        path = String(raw.dropFirst("+++ b/".count))
      } else if raw.hasPrefix("@@ ") {
        inHunk = true
        let newSide = try #require(raw.split(separator: " ").first { $0.hasPrefix("+") })
        next = try #require(Int(newSide.dropFirst().split(separator: ",")[0]))
      } else if inHunk, raw.hasPrefix("+") {
        lines.append(NeutralSourceLine(number: next, text: String(raw.dropFirst())))
        if let last = ranges.last, last.upperBound == next - 1 {
          ranges[ranges.count - 1] = last.lowerBound...next
        } else {
          ranges.append(next...next)
        }
        next += 1
        trailingContext = 0
      } else if inHunk, raw.hasPrefix(" ") {
        lines.append(NeutralSourceLine(number: next, text: String(raw.dropFirst())))
        next += 1
        trailingContext += 1
      } else if inHunk, raw.hasPrefix("-") {
        trailingContext = 0
      }
    }
    let file = try #require(path)
    let language = try #require(NeutralRules.language(forPath: file), "no language for \(file)")
    let source = NeutralSource(
      path: file, language: language,
      isTest: NeutralRules.isTestPath(file, language: language, globs: []), lines: lines,
      reachesEnd: isNewFile || trailingContext < 3)
    return (source, AddedLines(path: file, ranges: ranges))
  }

  static func outcome(_ result: NeutralCheckResult) -> Set<String> {
    var codes = Set<String>()
    for finding in result.findings {
      let prefix =
        switch finding.ruleID {
        case BrownfieldRuleID.unsafeShortcut.rawValue: "U"
        case BrownfieldRuleID.noAssertion.rawValue: "N"
        default: finding.ruleID + ":"
        }
      codes.insert("\(prefix)\(finding.line ?? 0)")
    }
    for candidate in result.judgeCandidates { codes.insert("J\(candidate.line)") }
    return codes
  }

  static func check(
    _ text: String, path: String, added: [ClosedRange<Int>], allow: [BrownfieldAllow] = []
  )
    throws -> NeutralCheckResult
  {
    let language = try #require(NeutralRules.language(forPath: path))
    let source = NeutralSource(
      path: path, language: language,
      isTest: NeutralRules.isTestPath(path, language: language, globs: []), text: text)
    return try NeutralRules.check(
      source, added: AddedLines(path: path, ranges: added), allow: allow)
  }

  @Test(
    "each captured diff yields exactly the findings its case names, and the false positives none — catches a token matched inside a string or comment"
  )
  func capturedDiffs() throws {
    let root = Fixture.directory.appending(path: "NeutralDiffs")
    var cases = Set<String>()
    for language in try FileManager.default.contentsOfDirectory(atPath: root.path) {
      let directory = root.appending(path: language)
      for file in try FileManager.default.contentsOfDirectory(atPath: directory.path)
      where file.hasSuffix(".diff") {
        cases.insert("\(language)/\(file.dropLast(".diff".count))")
      }
    }
    #expect(cases == Set(Self.expected.keys), "every captured case has an expectation")
    for name in cases.sorted() {
      let (source, added) = try Self.source(fromDiff: try Fixture.text("NeutralDiffs/\(name).diff"))
      let result = try NeutralRules.check(source, added: added, allow: [])
      #expect(Self.outcome(result) == Self.expected[name], "\(name)")
    }
  }

  @Test("a line nobody added never yields a finding — catches a check that reads the whole file")
  func untouchedLines() throws {
    let text = "let a = try! load()\nlet b = data as! Foo\nlet c = 1\n"
    #expect(try Self.check(text, path: "Sources/App/Load.swift", added: [3...3]).findings.isEmpty)
    let flagged = try Self.check(text, path: "Sources/App/Load.swift", added: [2...2])
    #expect(Self.outcome(flagged) == ["U2"])
  }

  @Test(
    "an allow entry follows its line's text: a moved line keeps it, an edited line loses it — catches a line-number key"
  )
  func allowFollowsText() throws {
    let path = "Sources/App/Load.swift"
    let entry = BrownfieldAllow(
      rule: BrownfieldRuleID.unsafeShortcut.rawValue, path: path,
      lineSHA: AllowMatching.lineSHA("let x = try! load()"), reason: "load never throws here")

    let moved = try Self.check(
      "import App\n\nfunc f() {\n    let x = try! load()\n}\n", path: path, added: [1...5],
      allow: [entry])
    #expect(moved.findings.isEmpty)
    #expect(
      moved.allowances == [
        NeutralAllowance(
          rule: .unsafeShortcut, path: path, line: 4, reason: "load never throws here",
          source: .config)
      ])

    let edited = try Self.check(
      "import App\n\nfunc f() {\n    let x = try! load(1)\n}\n", path: path, added: [1...5],
      allow: [entry])
    #expect(Self.outcome(edited) == ["U4"])
    #expect(edited.allowances.isEmpty)
  }

  @Test(
    "an allow entry waives only its own rule and path — catches an entry for 1 file waiving the same line in another"
  )
  func allowScopedToPathAndRule() throws {
    let text = "let x = try! load()\n"
    let sha = AllowMatching.lineSHA("let x = try! load()")
    let otherPath = BrownfieldAllow(
      rule: BrownfieldRuleID.unsafeShortcut.rawValue, path: "Sources/Other.swift", lineSHA: sha,
      reason: "r")
    let otherRule = BrownfieldAllow(
      rule: BrownfieldRuleID.noAssertion.rawValue, path: "Sources/Load.swift", lineSHA: sha,
      reason: "r")
    let result = try Self.check(
      text, path: "Sources/Load.swift", added: [1...1], allow: [otherPath, otherRule])
    #expect(Self.outcome(result) == ["U1"])
  }

  @Test(
    "an inline allow with a reason waives the line; a bare one is still swiftgate.allow-missing-reason — catches a bare allow accepted as a waiver"
  )
  func inlineAllows() throws {
    let path = "api/handlers.py"
    let text = """
      import json
      value = parse(x)  # type: ignore  # swiftgate:allow neutral.unsafe-shortcut — the stub lacks types
      other = parse(y)  # noqa  # swiftgate:allow neutral.unsafe-shortcut

      """
    let result = try Self.check(text, path: path, added: [1...3])
    #expect(Self.outcome(result) == ["U3", "swiftgate.allow-missing-reason:3"])
    #expect(
      result.allowances == [
        NeutralAllowance(
          rule: .unsafeShortcut, path: path, line: 2, reason: "the stub lacks types",
          source: .inline)
      ])
  }

  @Test(
    "a test whose only assertions compare constants is assertion-free without the judge — catches a tautology read as an assertion"
  )
  func tautologies() throws {
    let swift = """
      import XCTest

      final class LoadTests: XCTestCase {
        func testTautology() {
          _ = load()
          XCTAssertTrue(true)
          XCTAssertEqual(1, 1)
        }

        func testReal() {
          XCTAssertEqual(load(), 1)
        }
      }

      """
    let swiftResult = try Self.check(swift, path: "Tests/AppTests/LoadTests.swift", added: [1...14])
    #expect(Self.outcome(swiftResult) == ["N4"])

    let typescript = """
      it('is true', () => {
        expect(true).toBe(true);
      });
      it('loads', () => {
        expect(load()).toBe(1);
      });

      """
    let tsResult = try Self.check(typescript, path: "src/load.test.ts", added: [1...6])
    #expect(Self.outcome(tsResult) == ["N1"])
  }

  @Test(
    "a waived assertion-free test never reaches the judge — catches the allow applied after the cascade"
  )
  func waivedCandidate() throws {
    let path = "tests/test_load.py"
    let text = "def test_load():\n    load()\n"
    let entry = BrownfieldAllow(
      rule: BrownfieldRuleID.noAssertion.rawValue, path: path,
      lineSHA: AllowMatching.lineSHA("def test_load():"), reason: "a smoke test")
    #expect(Self.outcome(try Self.check(text, path: path, added: [1...2])) == ["J1"])
    let waived = try Self.check(text, path: path, added: [1...2], allow: [entry])
    #expect(waived.judgeCandidates.isEmpty)
    #expect(waived.allowances.map(\.line) == [1])
  }

  @Test(
    "skip and focus tokens count only in test files — catches a SwiftUI .disabled modifier flagged as a skipped test"
  )
  func skipTokensNeedTestFiles() throws {
    let text = "Button(\"Go\") {}\n  .disabled(isLoading)\n"
    #expect(try Self.check(text, path: "Sources/App/GoView.swift", added: [1...2]).findings.isEmpty)
    let inTest = try Self.check(text, path: "Tests/AppTests/GoTests.swift", added: [1...2])
    #expect(Self.outcome(inTest) == ["U2"])
  }

  @Test("an area's test globs decide test files over the naming convention — catches globs ignored")
  func testGlobs() {
    #expect(NeutralRules.isTestPath("Tests/AppTests/A.swift", language: .swift, globs: []))
    #expect(!NeutralRules.isTestPath("Sources/App/A.swift", language: .swift, globs: []))
    #expect(NeutralRules.isTestPath("spec/a_spec.rb", language: .ruby, globs: []))
    #expect(NeutralRules.isTestPath("pkg/a_test.go", language: .go, globs: []))
    #expect(
      NeutralRules.isTestPath("Checks/A.swift", language: .swift, globs: ["Checks/**/*.swift"]))
    #expect(
      !NeutralRules.isTestPath(
        "Tests/AppTests/A.swift", language: .swift, globs: ["Checks/**/*.swift"]))
  }

  @Test("a line's hash is SHA-256 of its trimmed text — catches a hash that keys on indentation")
  func lineHash() {
    let sha = "f40fa760a01d75985b218010f6b98666aad3d2812881e9c7b35f9ed6651bcad2"
    #expect(AllowMatching.lineSHA("let x = try! load()") == sha)
    #expect(AllowMatching.lineSHA("    let x = try! load()\t") == sha)
  }

  @Test(
    "a judge candidate names its test's last line, so a judge reads the whole body — catches a candidate cut to its declaration"
  )
  func candidateNamesItsLastLine() throws {
    let text = "def test_load():\n    value = load()\n    check(value)\n\ndef helper():\n    pass\n"
    let result = try Self.check(text, path: "tests/test_load.py", added: [1...3])
    let candidate = try #require(result.judgeCandidates.first)
    #expect(candidate.line == 1)
    #expect(candidate.endLine == 3)
  }

}
