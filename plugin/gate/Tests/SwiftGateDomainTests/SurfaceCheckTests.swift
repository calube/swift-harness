import SwiftGateDomain
import Testing

@Suite("surface-check judgement")
struct SurfaceCheckTests {
  @Test(
    "a Swift file named or placed as a test is a test file, and nothing else is — catches a test hidden from the no-tests rule by its path",
    arguments: [
      ("Tests/AppTests/FeatureTests.swift", true),
      ("Packages/Feed/Tests/FeedCoreTests/Helpers.swift", true),
      ("Sources/App/FeatureTest.swift", true),
      ("Sources/App/Feature.swift", false),
      ("Sources/Testing/Latest.swift", false),
      ("Tests/Fixtures/README.md", false),
    ])
  func testFiles(_ example: (path: String, isTest: Bool)) {
    #expect(SurfaceCheck.isTestFile(example.path) == example.isTest)
  }

  @Test(
    "an added test file is judged whole without scanning, and a deleted file is never scanned — catches an added test file passing because its bodies are empty"
  )
  func addedTestFileAndDeletedFile() {
    let surface = SurfaceCommit(
      commit: "c", parent: "p",
      changes: [
        SurfaceFileChange(
          path: "Tests/AppTests/NewTests.swift", parentText: nil, commitText: "@Test func a() {}"),
        SurfaceFileChange(
          path: "Sources/App/Old.swift", parentText: "func b() {}", commitText: nil),
        SurfaceFileChange(
          path: "Sources/App/New.swift", parentText: nil, commitText: "func c() {}"),
      ], otherPaths: [])
    var scanned: [String] = []

    let judgements = SurfaceCheck.judge(surface) { change in
      scanned.append(change.path)
      return []
    }

    #expect(scanned == ["Sources/App/New.swift"])
    #expect(
      judgements == [
        SurfaceJudgement(
          file: "Tests/AppTests/NewTests.swift", line: nil, declaration: "NewTests.swift",
          outcome: .behaviour(.addsTest))
      ])
  }

  @Test(
    "a body that isn't a stub is reported with every stub shape it could have taken, the throw-only, empty-payload case and unchanged-return shapes included — catches a finding that steers the author away from an allowed stub"
  )
  func notAStubNamesEveryShape() throws {
    let surface = SurfaceCommit(commit: "c", parent: "p", changes: [], otherPaths: [])
    let findings = try SurfaceCheck.findings(
      surface,
      judgements: [
        SurfaceJudgement(
          file: "Sources/App/Surface.swift", line: 2, declaration: "load()",
          outcome: .behaviour(.notAStub(excerpt: "return items.count")))
      ])

    #expect(
      findings.first?.message
        == "`load()` isn't an allowed stub (`return items.count`): a surface body is empty; "
        + "returns 1 empty default, payload-free case, enum case built from empty defaults and "
        + "parameters, or parameter or property of `self` unchanged; only throws such an error "
        + "value; or forwards to code the parent declares")
  }

  @Test(
    "a manifest change past added list elements names the change and says a surface only adds dependencies, products and targets — catches a finding that leaves the author guessing which line to undo"
  )
  func manifestChangeNamesTheChange() throws {
    let surface = SurfaceCommit(commit: "c", parent: "p", changes: [], otherPaths: [])
    let findings = try SurfaceCheck.findings(
      surface,
      judgements: [
        SurfaceJudgement(
          file: "Package.swift", line: 16, declaration: "package",
          outcome: .behaviour(.changesManifest(excerpt: "exact: \"1.27.0\"")))
      ])

    #expect(
      findings.first?.message
        == "`package` changes the package manifest (`exact: \"1.27.0\"`): a surface only adds "
        + "dependencies, products and targets to an existing manifest's lists, and removes or "
        + "changes nothing")
  }
}
