import SwiftGateDomain
import Testing

private func area(
  _ name: String, kind: AreaKind, root: String = ".", test: String? = nil,
  testFiles: String? = nil
) -> BrownfieldArea {
  BrownfieldArea(
    name: name, root: root, language: kind == .xcode || kind == .swiftpm ? .swift : .other,
    kind: kind, test: test, testFiles: testFiles, lint: nil, build: nil, e2e: nil, testGlobs: [],
    packs: [], xcode: nil)
}

/// The test command `discover --apply` wrote for the Aidoku iOS validation trial's app area.
private let aidokuTest =
  "xcodebuild test -project Aidoku.xcodeproj -scheme Aidoku -destination "
  + "'platform=iOS Simulator,name=iPhone 17' -skipMacroValidation -skipPackagePluginValidation"
private let aidoku = area("Aidoku", kind: .xcode, test: aidokuTest)

@Suite("acceptance test reference")
struct AcceptanceTestReferenceTests {
  @Test(
    "`test: <id>` and `test <area>: <id>` parse, and a command, a source path or the shell's own `test` builtin don't — catches a test id run as a shell command"
  )
  func parses() {
    #expect(
      AcceptanceTestReference.parse("test: AidokuTests/LargeDownloadConfirmationTests")
        == AcceptanceTestReference(area: nil, id: "AidokuTests/LargeDownloadConfirmationTests"))
    #expect(
      AcceptanceTestReference.parse("  test web:   src/export.test.ts ")
        == AcceptanceTestReference(area: "web", id: "src/export.test.ts"))
    #expect(
      AcceptanceTestReference.parse("AidokuTests/LargeDownloadConfirmationTests.swift") == nil)
    #expect(AcceptanceTestReference.parse("pytest api/tests/test_download.py") == nil)
    #expect(AcceptanceTestReference.parse("test -f build/out.csv") == nil)
    #expect(AcceptanceTestReference.parse("qa/export.acceptance.sh") == nil)
  }

  @Test(
    "an empty `test:` still parses as the test form and resolves to nothing — catches `test:` handed to /bin/sh, where the builtin exits 0 and the row passes"
  )
  func emptyIDDoesNotRun() throws {
    let reference = try #require(AcceptanceTestReference.parse("test:"))
    #expect(reference.id.isEmpty)
    guard case .failure(let unresolved) = reference.resolve(in: [aidoku], junitPath: nil) else {
      Issue.record("an empty test id resolved to a command")
      return
    }
    #expect(unresolved.reason.contains("names no test"), "\(unresolved.reason)")
  }

  @Test(
    "given a result bundle path, an xcode area's command writes its bundle there and names it, and a swiftpm area's doesn't — catches an xcodebuild row left with nothing to show a test ran"
  )
  func xcodeResultBundle() throws {
    let reference = AcceptanceTestReference(
      area: nil, id: "AidokuTests/LargeDownloadConfirmationTests")
    let bundle = "/run/qa/01-req-download.acceptance.xcresult"
    let resolved = try reference.resolve(
      in: [aidoku], junitPath: "/run/qa/01-req-download.acceptance.junit.xml",
      resultBundlePath: bundle
    ).get()
    #expect(
      resolved
        == AcceptanceTestCommand(
          area: "Aidoku", root: ".",
          command: aidokuTest + " -only-testing:'AidokuTests/LargeDownloadConfirmationTests'"
            + " -resultBundlePath '\(bundle)'",
          resultBundlePath: bundle))

    let swiftpm = area(
      "Probe", kind: .swiftpm, test: "swift test", testFiles: "swift test --filter {tests}")
    let narrowed = try AcceptanceTestReference(area: nil, id: "ProbeTests.ResetTests")
      .resolve(in: [swiftpm], junitPath: nil, resultBundlePath: bundle).get()
    #expect(narrowed.resultBundlePath == nil)
    #expect(!narrowed.command.contains("resultBundlePath"), "\(narrowed.command)")
  }

  @Test(
    "an xcode area runs its test command with -only-testing: the quoted id, in its root — catches the Aidoku trial's acceptance row that /bin/sh ran as a path and exited 126"
  )
  func xcodeOnlyTesting() throws {
    let reference = AcceptanceTestReference(
      area: nil, id: "AidokuTests/LargeDownloadConfirmationTests")
    let resolved = try reference.resolve(in: [aidoku], junitPath: nil).get()
    #expect(
      resolved
        == AcceptanceTestCommand(
          area: "Aidoku", root: ".",
          command: aidokuTest + " -only-testing:'AidokuTests/LargeDownloadConfirmationTests'"))
  }

  @Test(
    "other kinds fill their test_files `{tests}` or `{files}` with the id, and `{junit}` with the path — catches 1 kind's filter forced on every area"
  )
  func otherKindsUseTestFiles() throws {
    let swiftpm = area("core", kind: .swiftpm, testFiles: "swift test --filter {tests}")
    #expect(
      try AcceptanceTestReference(area: nil, id: "CoreTests.ExportTests/testColumns")
        .resolve(in: [swiftpm], junitPath: nil).get().command
        == "swift test --filter 'CoreTests.ExportTests/testColumns'")
    let go = area("api", kind: .go, root: "api", testFiles: "go test ./... -run {tests}")
    let goCommand = try AcceptanceTestReference(area: nil, id: "TestExportCSV")
      .resolve(in: [go], junitPath: nil).get()
    #expect(goCommand.command == "go test ./... -run '^(TestExportCSV)$'")
    #expect(goCommand.root == "api")
    let python = area(
      "api", kind: .python, testFiles: "pytest {files} --junitxml {junit}")
    #expect(
      try AcceptanceTestReference(area: nil, id: "tests/test_export.py")
        .resolve(in: [python], junitPath: "/tmp/qa/01.junit.xml").get().command
        == "pytest 'tests/test_export.py' --junitxml '/tmp/qa/01.junit.xml'")
  }

  @Test(
    "with several test-running areas the check must name 1, and a named area must exist and be able to narrow its tests — catches a test run in the wrong area or run whole"
  )
  func areaChoice() throws {
    let web = area(
      "web", kind: .node, root: "web", test: "npm test", testFiles: "npx vitest run {files}")
    let docs = area("docs", kind: .command, test: "make docs-test")
    let buildOnly = area("tools", kind: .command)

    func reason(_ reference: AcceptanceTestReference, _ areas: [BrownfieldArea]) -> String? {
      guard case .failure(let unresolved) = reference.resolve(in: areas, junitPath: nil) else {
        return nil
      }
      return unresolved.reason
    }

    let unnamed = try #require(
      reason(AcceptanceTestReference(area: nil, id: "AidokuTests/X"), [aidoku, web, buildOnly]))
    #expect(unnamed.contains("Aidoku") && unnamed.contains("web"), "\(unnamed)")
    #expect(!unnamed.contains("tools"), "\(unnamed)")
    #expect(unnamed.contains("test <area>:"), "\(unnamed)")

    #expect(
      try AcceptanceTestReference(area: "web", id: "src/export.test.ts")
        .resolve(in: [aidoku, web], junitPath: nil).get()
        == AcceptanceTestCommand(
          area: "web", root: "web", command: "npx vitest run 'src/export.test.ts'"))
    #expect(
      try AcceptanceTestReference(area: nil, id: "AidokuTests/X")
        .resolve(in: [aidoku, buildOnly], junitPath: nil).get().area == "Aidoku")

    let missing = try #require(reason(AcceptanceTestReference(area: "ios", id: "X"), [aidoku]))
    #expect(missing.contains("`ios`"), "\(missing)")

    let whole = try #require(reason(AcceptanceTestReference(area: "docs", id: "X"), [docs]))
    #expect(whole.contains("test_files"), "\(whole)")

    let xcodeWithoutTest = area("App", kind: .xcode)
    let none = try #require(
      reason(AcceptanceTestReference(area: nil, id: "AppTests/X"), [xcodeWithoutTest]))
    #expect(none.contains("no area"), "\(none)")
  }
}
