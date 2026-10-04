import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

/// The new side of each file a captured `change.diff` touches: the lines its hunks show, at their
/// new line numbers, and blank lines between, so line numbers match the file the run saw.
private enum CapturedChange {
  static func files(_ fixture: String) throws -> [ChangedTestFile] {
    var files: [ChangedTestFile] = []
    var path: String?
    var lines: [Int: String] = [:]
    var added: [Int] = []
    var next = 0
    func flush() {
      guard let path else { return }
      let last = lines.keys.max() ?? 0
      let content = (1...max(last, 1)).map { lines[$0] ?? "" }.joined(separator: "\n")
      files.append(
        ChangedTestFile(
          path: path, content: content,
          added: AddedLines(path: path, ranges: added.map { $0...$0 })))
    }
    for line in try Fixture.text("AreaRuns/\(fixture)/change.diff").split(
      separator: "\n", omittingEmptySubsequences: false)
    {
      if line.hasPrefix("+++ b/") {
        flush()
        path = String(line.dropFirst("+++ b/".count))
        lines = [:]
        added = []
      } else if line.hasPrefix("@@ ") {
        let newSide = line.split(separator: " ")[2].dropFirst()
        next = Int(newSide.split(separator: ",")[0]) ?? 0
      } else if line.hasPrefix("+") && !line.hasPrefix("+++") {
        lines[next] = String(line.dropFirst())
        added.append(next)
        next += 1
      } else if line.hasPrefix(" ") {
        lines[next] = String(line.dropFirst())
        next += 1
      }
    }
    flush()
    return files
  }
}

@Suite("changed test ids")
struct ChangedTestIDsTests {
  private static func area(root: String, kind: AreaKind, globs: [String]) -> BrownfieldArea {
    BrownfieldArea(
      name: "area", root: root, language: .other, kind: kind, test: "run-all",
      testFiles: "run {tests}", lint: nil, build: nil, e2e: nil, testGlobs: globs, packs: [],
      xcode: nil)
  }

  @Test(
    "a go test file maps to the test functions its change adds, which the captured run ran — catches a whole package or a helper selected instead of the changed test"
  )
  func goSelectsChangedTestFunctions() throws {
    let files = try CapturedChange.files("go/test-crash")
    let ids = try #require(ChangedTestIDs.ids(kind: .go, areaRoot: ".", files: files))
    #expect(ids.map(\.name) == ["TestExit"])
    #expect(ChangedTestIDs.testsArgument(kind: .go, ids: ids) == "'^(TestExit)$'")
    #expect(try Fixture.text("AreaRuns/go/test-crash/stdout").contains("\"Test\":\"TestExit\""))
  }

  @Test(
    "a cargo test file maps to the test function an edit lands in and to an added one — catches an edit inside a body missed because the declaration line is unchanged"
  )
  func cargoSelectsChangedTestFunctions() throws {
    let edited = try #require(
      ChangedTestIDs.ids(
        kind: .cargo, areaRoot: ".", files: try CapturedChange.files("cargo/test-fail")))
    #expect(edited.map(\.name) == ["sum"])
    #expect(try Fixture.text("AreaRuns/cargo/test-fail/stdout").contains("test sum ..."))
    let added = try #require(
      ChangedTestIDs.ids(
        kind: .cargo, areaRoot: ".", files: try CapturedChange.files("cargo/test-crash")))
    #expect(added.map(\.name) == ["aborts"])
    #expect(ChangedTestIDs.testsArgument(kind: .cargo, ids: edited + added) == "'sum' 'aborts'")
  }

  @Test(
    "node and python test files map to their paths relative to the area root, as the captured commands name them — catches a repository-relative path run from a nested area"
  )
  func nodeAndPythonSelectByAreaRelativePath() throws {
    let node = try #require(
      ChangedTestIDs.ids(
        kind: .node, areaRoot: "packages/turbo-utils",
        files: try CapturedChange.files("node/test-crash")))
    #expect(node.map(\.selector) == ["__tests__/convert-case.test.ts"])
    #expect(node.map(\.file) == ["packages/turbo-utils/__tests__/convert-case.test.ts"])
    #expect(try Fixture.text("AreaRuns/node/test-crash/command").contains(node[0].selector))

    let python = try #require(
      ChangedTestIDs.ids(
        kind: .python, areaRoot: ".", files: try CapturedChange.files("python/test-crash")))
    #expect(python.map(\.selector) == ["gguf-py/tests/test_metadata.py"])
    #expect(try Fixture.text("AreaRuns/python/test-crash/command").contains(python[0].selector))
  }

  @Test(
    "a jvm test file maps to its fully qualified class, from its package line or else its source-set path, as gradle and surefire name it — catches a bare file name no runner selects by"
  )
  func jvmSelectsQualifiedClass() throws {
    let gradle = try #require(
      ChangedTestIDs.ids(
        kind: .jvm, areaRoot: ".", files: try CapturedChange.files("gradle/test-crash")))
    #expect(gradle.map(\.name) == ["okhttp3.sse.internal.ServerSentEventIteratorTest"])
    #expect(try Fixture.text("AreaRuns/gradle/test-crash/command").contains(gradle[0].selector))

    let maven = try #require(
      ChangedTestIDs.ids(
        kind: .jvm, areaRoot: ".", files: try CapturedChange.files("maven/test-fail")))
    #expect(maven.map(\.name) == ["io.github.jhipster.sample.security.SecurityUtilsUnitTest"])
    #expect(
      try Fixture.text("AreaRuns/maven/test-fail/junit.xml").contains(
        "name=\"\(maven[0].name)\""))

    let declared = ChangedTestFile(
      path: "lib/src/test/kotlin/Misplaced.kt",
      content: "package com.example.real\n\nclass Misplaced {\n  @Test fun a() {}\n}",
      added: AddedLines(path: "lib/src/test/kotlin/Misplaced.kt", ranges: [4...4]))
    #expect(
      ChangedTestIDs.ids(kind: .jvm, areaRoot: "lib", files: [declared])?.map(\.name) == [
        "com.example.real.Misplaced"
      ])
    #expect(
      ChangedTestIDs.testsArgument(kind: .jvm, ids: gradle + maven)
        == "'okhttp3.sse.internal.ServerSentEventIteratorTest,"
        + "io.github.jhipster.sample.security.SecurityUtilsUnitTest'")
  }

  @Test(
    "xcode and command areas take no ids, so prove runs their whole test — catches a kind given a selector its runner doesn't accept"
  )
  func kindsWithoutIDs() {
    let file = ChangedTestFile(
      path: "t/a_spec.rb", content: "it 'a' do\nend",
      added: AddedLines(path: "t/a_spec.rb", ranges: [1...2]))
    #expect(ChangedTestIDs.ids(kind: .command, areaRoot: ".", files: [file]) == nil)
    #expect(ChangedTestIDs.ids(kind: .xcode, areaRoot: ".", files: [file]) == nil)
    #expect(ChangedTestIDs.files(areaRoot: ".", files: [file]).map(\.selector) == ["t/a_spec.rb"])
  }

  @Test(
    "a path holding a space and a quote expands to 1 shell word, and each placeholder is replaced — catches an unquoted expansion that splits or injects"
  )
  func expansionQuotes() {
    #expect(ChangedTestIDs.shellQuoted("it's a.test") == #"'it'\''s a.test'"#)
    let ids = [
      AreaTestID(name: "a", selector: "it's a.test", file: "web/it's a.test", line: 1),
      AreaTestID(name: "b", selector: "b.test", file: "web/b.test", line: 1),
    ]
    let tests = ChangedTestIDs.testsArgument(kind: .node, ids: ids)
    #expect(tests == #"'it'\''s a.test' 'b.test'"#)
    #expect(ChangedTestIDs.filesArgument(areaRoot: "web", ids: ids + ids) == tests)
    #expect(
      ChangedTestIDs.expand(
        "jest {tests} --out {junit} {files}", tests: "'x'", files: "'y'", junit: "'/j.xml'")
        == "jest 'x' --out '/j.xml' 'y'")
    #expect(
      ChangedTestIDs.expand("go test {tests}", tests: nil, files: nil, junit: nil)
        == "go test {tests}")
  }

  @Test(
    "a test file is 1 under its area's root that matches a test glob — catches a source file reverted as a test or a test kept as source"
  )
  func testFileMembership() {
    let area = Self.area(
      root: "web", kind: .node, globs: ["web/**/__tests__/**", "web/**/*.test.ts"])
    #expect(ChangedTestIDs.isTestFile("web/src/a.test.ts", of: area))
    #expect(ChangedTestIDs.isTestFile("web/pkg/__tests__/deep/b.ts", of: area))
    #expect(!ChangedTestIDs.isTestFile("web/src/a.ts", of: area))
    #expect(!ChangedTestIDs.isTestFile("api/src/a.test.ts", of: area))
    let rooted = Self.area(root: ".", kind: .python, globs: ["tests/**/*.py"])
    #expect(ChangedTestIDs.isTestFile("tests/test_a.py", of: rooted))
    #expect(!ChangedTestIDs.isTestFile("src/a.py", of: rooted))
  }
}
