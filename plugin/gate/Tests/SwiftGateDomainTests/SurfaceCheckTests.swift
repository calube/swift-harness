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
}
