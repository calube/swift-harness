import Foundation
import SwiftGateAdapters
import Testing

@Suite("SwiftSourceCollector")
struct SwiftSourceCollectorTests {
  private func makeTree(_ files: [String: String]) throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "swiftgate-sources-\(UUID().uuidString)", directoryHint: .isDirectory)
      .resolvingSymlinksInPath()
    for (path, content) in files {
      let url = root.appending(path: path)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(content.utf8).write(to: url)
    }
    return root
  }

  @Test(
    "walks directories for .swift files, skipping hidden and build output — catches linting .build checkouts"
  )
  func walksDirectories() throws {
    let root = try makeTree([
      "Tests/A/ATests.swift": "a", "Tests/A/notes.md": "n", "Sources/B/B.swift": "b",
      ".build/checkouts/X/X.swift": "x", "App/DerivedData/Gen.swift": "g", ".hidden.swift": "h",
    ])
    defer { try? FileManager.default.removeItem(at: root) }
    let collector = SwiftSourceCollector(root: root)
    #expect(
      try collector.collect(paths: ["."]).map(\.path) == [
        "Sources/B/B.swift", "Tests/A/ATests.swift",
      ])
    #expect(try collector.collect(paths: ["./Tests"]).map(\.text) == ["a"])
  }

  @Test(
    "explicit files and absolute paths inside the root are repository-relative and unique — catches duplicate findings"
  )
  func explicitPaths() throws {
    let root = try makeTree(["Tests/A/ATests.swift": "a"])
    defer { try? FileManager.default.removeItem(at: root) }
    let collector = SwiftSourceCollector(root: root)
    let absolute = root.appending(path: "Tests/A/ATests.swift").path
    #expect(
      try collector.collect(paths: ["Tests/A/ATests.swift", absolute, "Tests"]).map(\.path)
        == ["Tests/A/ATests.swift"])
  }

  @Test(
    "missing paths and paths outside the root are errors, never an empty GREEN — catches typos passing silently"
  )
  func invalidPaths() throws {
    let root = try makeTree(["A.swift": "a"])
    defer { try? FileManager.default.removeItem(at: root) }
    let collector = SwiftSourceCollector(root: root)
    #expect(throws: SourceCollectionError.notFound("Nope")) {
      try collector.collect(paths: ["Nope"])
    }
    #expect(throws: SourceCollectionError.outsideRoot("/etc")) {
      try collector.collect(paths: ["/etc"])
    }
    #expect(throws: SourceCollectionError.outsideRoot("../x")) {
      try collector.collect(paths: ["../x"])
    }
  }

  @Test(
    "excluded directories are skipped when walking — catches deliberate-violation fixtures linted as product code"
  )
  func excludedDirectories() throws {
    let root = try makeTree([
      "gate/Sources/A.swift": "a", "gate/Fixtures/rules/bad/B.swift": "b",
      "gate/FixturesExtra/C.swift": "c",
    ])
    defer { try? FileManager.default.removeItem(at: root) }
    let collector = SwiftSourceCollector(root: root, excluding: ["gate/Fixtures"])

    #expect(
      try collector.collect(paths: ["."]).map(\.path) == [
        "gate/FixturesExtra/C.swift", "gate/Sources/A.swift",
      ])
  }
}
