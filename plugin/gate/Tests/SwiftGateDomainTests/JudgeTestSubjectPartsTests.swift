import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@Suite("judge test name")
struct JudgeTestNameTests {
  @Test(
    "each dash splits behaviour from catches — catches a split on 1 dash only",
    arguments: ["—", "–", "-"])
  func splitsOnEveryDash(dash: String) {
    let source = """
      @Test("total is $5 \(dash) catches shoppers billed twice")
      func total() {}
      """
    #expect(
      JudgeTestName.parse(source: source)
        == JudgeTestName(
          full: "total is $5 \(dash) catches shoppers billed twice",
          behavior: "total is $5",
          catches: "catches shoppers billed twice"))
  }

  @Test("a name with no catches part is all behaviour — catches a behaviour left empty")
  func noCatchesPart() {
    let source = """
      @Test("adding two items totals 9")
      func total() {}
      """
    #expect(
      JudgeTestName.parse(source: source)
        == JudgeTestName(
          full: "adding two items totals 9", behavior: "adding two items totals 9", catches: nil))
  }

  @Test("a hyphen inside a word doesn't split — catches a split on any dash character")
  func hyphenInsideWordStays() {
    let source = """
      @Test("a non-empty cart-total shows")
      func total() {}
      """
    #expect(JudgeTestName.parse(source: source).behavior == "a non-empty cart-total shows")
  }

  @Test(
    "a test with no display string is named by its func — catches an empty name for XCTest and bare @Test"
  )
  func functionNameFallback() {
    let xctest = """
      func testIncrementUpdatesTheCount() {
        XCTAssertEqual(count, 1)
      }
      """
    let bare = """
      @Test(.tags(.fast))
      func incrementsOnce() async {}
      """
    #expect(JudgeTestName.parse(source: xctest).full == "testIncrementUpdatesTheCount")
    #expect(JudgeTestName.parse(source: bare).full == "incrementsOnce")
  }

  @Test("a backticked func name loses its backticks — catches a name that keeps its quoting")
  func backtickedName() {
    let source = """
      @Test
      func `adding two items totals 9 — catches a lost item`() {}
      """
    #expect(
      JudgeTestName.parse(source: source)
        == JudgeTestName(
          full: "adding two items totals 9 — catches a lost item",
          behavior: "adding two items totals 9", catches: "catches a lost item"))
  }

  @Test("escapes in a display string are unescaped — catches a name that keeps its backslashes")
  func unescapesDisplayString() {
    let source = #"""
      @Test("shows \"Due today\" for \\.today\tnow")
      func dueToday() {}
      """#
    #expect(JudgeTestName.parse(source: source).full == "shows \"Due today\" for \\.today\tnow")
  }

  @Test("a raw display string is read verbatim — catches a raw string read as a func name")
  func rawDisplayString() {
    let source = ##"""
      @Test(#"parses "\d+" digits"#)
      func digits() {}
      """##
    #expect(JudgeTestName.parse(source: source).full == #"parses "\d+" digits"#)
  }

  @Test(
    "a display string on the line after @Test( is found — catches a name parser bound to 1 line"
  )
  func multiLineAttribute() {
    let source = """
      @Test(
        "retries back off — catches retries hammering the server",
        .timeLimit(.minutes(1))
      )
      func retries() async {}
      """
    #expect(
      JudgeTestName.parse(source: source).full
        == "retries back off — catches retries hammering the server")
  }

  @Test("a commented-out @Test isn't the name — catches a name read from a comment")
  func ignoresCommentedAttribute() {
    let source = """
      // @Test("old name — catches nothing")
      /* func oldName() */
      @Test("new name — catches the count not advancing")
      func newName() {}
      """
    #expect(
      JudgeTestName.parse(source: source).full == "new name — catches the count not advancing")
  }

  @Test("an absent catches part encodes as null — catches a state field that drops the key")
  func encodesNullCatches() throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let name = JudgeTestName(full: "counter works", behavior: "counter works", catches: nil)
    let json = String(decoding: try encoder.encode(name), as: UTF8.self)
    #expect(json == #"{"behavior":"counter works","catches":null,"full":"counter works"}"#)
  }
}

@Suite("judge assertions")
struct JudgeAssertionsTests {
  @Test(
    "a receive closure over 3 lines with a nested brace is 1 entry — catches a join that stops at the first }"
  )
  func joinsMultiLineClosure() {
    let source = """
      func factLoads() async {
        await store.receive(\\.factResponse) {
          $0.items = items.map { $0.id }
          $0.isLoading = false
        }
        await store.send(.onDisappear)
      }
      """
    #expect(
      JudgeAssertions.extract(source: source) == [
        "await store.receive(\\.factResponse) { $0.items = items.map { $0.id } $0.isLoading = false }",
        "await store.send(.onDisappear)",
      ])
  }

  @Test("try and await before an assertion are kept — catches a statement cut after its effects")
  func keepsEffectKeywords() {
    let source = """
      func loads() async throws {
        let entry = try #require(entries.first)
        await #expect(throws: APIError.self) { try await client.load() }
        let value = try XCTUnwrap(optional)
      }
      """
    #expect(
      JudgeAssertions.extract(source: source) == [
        "try #require(entries.first)",
        "await #expect(throws: APIError.self) { try await client.load() }",
        "try XCTUnwrap(optional)",
      ])
  }

  @Test("a multi-line #expect becomes 1 line — catches an assertion cut at its first line")
  func joinsMultiLineExpect() {
    let source = """
      func request() {
        #expect(
          transport.requests.first?.value(forHTTPHeaderField: "Accept")
            == "application/json"
        )
      }
      """
    #expect(
      JudgeAssertions.extract(source: source) == [
        #"#expect( transport.requests.first?.value(forHTTPHeaderField: "Accept") == "application/json" )"#
      ])
  }

  @Test(
    "every assertion form comes back in source order — catches a parser that groups by kind"
  )
  func sourceOrder() {
    let source = """
      func mixed() async throws {
        XCTAssertEqual(value.label, "0")
        #expect(count == 1)
        await store.send(.incrementButtonTapped) { $0.count = 1 }
        XCTAssertTrue(app.buttons["go"].exists)
        let unwrapped = try #require(maybe)
      }
      """
    #expect(
      JudgeAssertions.extract(source: source) == [
        #"XCTAssertEqual(value.label, "0")"#,
        "#expect(count == 1)",
        "await store.send(.incrementButtonTapped) { $0.count = 1 }",
        #"XCTAssertTrue(app.buttons["go"].exists)"#,
        "try #require(maybe)",
      ])
  }

  @Test(
    "#expect( in a comment or a string isn't an assertion — catches a count inflated by text"
  )
  func ignoresCommentsAndStrings() {
    let source = ##"""
      func onlyOne() {
        // #expect(commented == true)
        /* XCTAssertEqual(a, b) /* nested #expect(x) */ still a comment */
        let label = "#expect(inside a string)"
        let raw = ##"await store.send(.raw) "#expect(also text)"##
        let block = """
          #require(inside a multi-line string)
          """
        let interpolated = "value \(label) #expect(after interpolation)"
        #expect(real == true) // #expect(trailing comment)
      }
      """##
    #expect(JudgeAssertions.extract(source: source) == ["#expect(real == true)"])
  }

  @Test("a string holding a brace doesn't unbalance a closure — catches a join cut at a quoted }")
  func quotedBraceInsideClosure() {
    let source = #"""
      func label() async {
        await store.send(.renamed("}")) {
          $0.title = "{ open"
        }
        #expect(store.state.title == "{ open")
      }
      """#
    #expect(
      JudgeAssertions.extract(source: source) == [
        #"await store.send(.renamed("}")) { $0.title = "{ open" }"#,
        #"#expect(store.state.title == "{ open")"#,
      ])
  }

  @Test(
    "an assertion inside a helper closure counts once — catches a nested assertion counted twice or not at all"
  )
  func helperClosures() {
    let source = """
      func helpers() async throws {
        let check: (Int) -> Void = { n in #expect(n > 0) }
        await #expect(throws: (any Error).self) {
          try #require(nil as Int?)
        }
      }
      """
    #expect(
      JudgeAssertions.extract(source: source) == [
        "#expect(n > 0)",
        "await #expect(throws: (any Error).self) { try #require(nil as Int?) }",
      ])
  }

  @Test(
    "a lookalike identifier isn't an assertion — catches a match inside a longer name"
  )
  func identifierBoundaries() {
    let source = """
      func lookalikes() async {
        myXCTAssertHelper(value)
        await otherstore.send(.tap)
        store.sendable = true
        XCTAssertNil(error)
      }
      """
    #expect(JudgeAssertions.extract(source: source) == ["XCTAssertNil(error)"])
  }

  @Test(
    "a snapshot-only test has no assertions while an #expect test has 1 — catches a snapshot call read as an assertion"
  )
  func noAssertions() {
    let snapshotOnly = """
      func view() {
        assertSnapshot(of: CounterView(store: store), as: .dump)
      }
      """
    let withExpect = """
      func view() {
        assertSnapshot(of: CounterView(store: store), as: .dump)
        #expect(store.state.count == 5)
      }
      """
    #expect(JudgeAssertions.extract(source: snapshotOnly) == [])
    #expect(JudgeAssertions.extract(source: withExpect) == ["#expect(store.state.count == 5)"])
  }
}

@Suite("judge test subject parts on the judge fixture cases")
struct JudgeTestSubjectPartsFixtureTests {
  static let casesDirectory = Fixture.gateDirectory.appending(
    path: "Fixtures/judge/cases", directoryHint: .isDirectory)

  static func caseSources() throws -> [(id: String, source: String)] {
    let ids = try FileManager.default.contentsOfDirectory(atPath: casesDirectory.path())
      .filter { !$0.hasPrefix(".") }
      .sorted()
    return try ids.map { id in
      let data = try Data(contentsOf: casesDirectory.appending(path: "\(id)/Test.swift.txt"))
      return (id, String(decoding: data, as: UTF8.self))
    }
  }

  /// An independent reading of the declared name: the first `@Test` string literal, else the first
  /// func. It's good enough for these fixtures, which hold no comments or raw strings.
  static func declaredName(_ source: String) throws -> String? {
    let range = NSRange(source.startIndex..., in: source)
    let display = try NSRegularExpression(pattern: #"@Test\(\s*"((?:[^"\\]|\\.)*)""#)
    if let match = display.firstMatch(in: source, range: range),
      let captured = Range(match.range(at: 1), in: source)
    {
      return String(source[captured])
        .replacingOccurrences(of: #"\\"#, with: "\u{0}")
        .replacingOccurrences(of: #"\""#, with: "\"")
        .replacingOccurrences(of: "\u{0}", with: #"\"#)
    }
    let function = try NSRegularExpression(pattern: #"func\s+(\w+)\s*\("#)
    guard let match = function.firstMatch(in: source, range: range),
      let captured = Range(match.range(at: 1), in: source)
    else { return nil }
    return String(source[captured])
  }

  static let markers = [
    "#expect", "#require", "XCTAssert", "XCTUnwrap", "store.send", "store.receive",
  ]

  @Test(
    "every fixture case's name is its declared name — catches a parser that only handles hand-written inputs"
  )
  func everyCaseParsesItsName() throws {
    let cases = try Self.caseSources()
    #expect(cases.count >= 66)
    for (id, source) in cases {
      let expected = try #require(try Self.declaredName(source), "\(id) declares no test")
      let name = JudgeTestName.parse(source: source)
      #expect(name.full == expected, "\(id)")
      #expect(name.full.isEmpty == false, "\(id)")
    }
  }

  @Test(
    "every fixture case with an assertion yields 1 or more, each starting at its assertion — catches a missed assertion form"
  )
  func everyCaseYieldsItsAssertions() throws {
    let cases = try Self.caseSources()
    #expect(cases.count >= 66)
    for (id, source) in cases {
      let hasMarker = Self.markers.contains { source.contains($0) }
      let assertions = JudgeAssertions.extract(source: source)
      #expect(assertions.isEmpty == !hasMarker, "\(id)")
      for line in assertions {
        let body = line.replacing(/^((try|await)\s+)*/, with: "")
        #expect(Self.markers.contains { body.hasPrefix($0) }, "\(id): \(line)")
        #expect(!line.contains("\n"), "\(id): \(line)")
      }
    }
  }

  @Test(
    "the 2 captured Jev cases parse to the state the request sent — catches drift from the captured request"
  )
  func capturedCases() throws {
    let cases = Dictionary(uniqueKeysWithValues: try Self.caseSources().map { ($0.id, $0.source) })
    let counter = try #require(cases["counter-increment"])
    let own = try #require(cases["own-double"])
    #expect(
      JudgeTestName.parse(source: counter)
        == JudgeTestName(
          full: "tapping + twice shows 2 — catches the counter not advancing on tap",
          behavior: "tapping + twice shows 2",
          catches: "catches the counter not advancing on tap"))
    #expect(
      JudgeAssertions.extract(source: counter) == [
        "await store.send(.incrementButtonTapped) { $0.count = 1 }",
        "await store.send(.incrementButtonTapped) { $0.count = 2 }",
      ])
    #expect(JudgeAssertions.extract(source: own) == [#"#expect(profile.name == "Ada")"#])
  }
}
