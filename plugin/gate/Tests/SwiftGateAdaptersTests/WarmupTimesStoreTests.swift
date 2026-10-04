import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@Suite("Warm-up times store")
struct WarmupTimesStoreTests {
  private static func layout() throws -> (BrownfieldStateLayout, URL) {
    let root = TestTemporaryDirectory.root
      .appending(path: "swiftgate-warmup-store-\(UUID().uuidString)", directoryHint: .isDirectory)
    let gitDir = root.appending(path: ".git", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
    return (BrownfieldStateLayout(commonDir: gitDir, gitDir: gitDir), root)
  }

  private static let web = WarmupAreaRecord(
    coldMilliseconds: 61_000, testMilliseconds: 45_000, steps: [.build: .passed, .test: .failed])
  private static let api = WarmupAreaRecord(
    coldMilliseconds: 9_000, testMilliseconds: 4_000, steps: [.build: .passed, .test: .passed])

  @Test(
    "records from 2 areas land in 1 file per tree and read back — catches a record that replaces the other areas"
  )
  func recordsAccumulate() async throws {
    let (layout, root) = try Self.layout()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WarmupTimesStore(layout: layout)

    try await store.record(area: "web", Self.web, tree: "t1")
    try await store.record(area: "api", Self.api, tree: "t1")

    let load = store.load(tree: "t1")
    #expect(load.file.areas == ["web": Self.web, "api": Self.api])
    #expect(load.notes.isEmpty)
    #expect(store.load(tree: "t2").file.areas.isEmpty)
  }

  @Test(
    "a times file that doesn't decode reads empty with a note naming it, and the next record replaces it — catches silent corruption"
  )
  func corruptFileIsNamed() async throws {
    let (layout, root) = try Self.layout()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WarmupTimesStore(layout: layout)
    try FileManager.default.createDirectory(
      at: layout.warmupDirectory, withIntermediateDirectories: true)
    try Data("{not json".utf8).write(to: layout.warmup(tree: "t1"))

    let load = store.load(tree: "t1")
    #expect(load.file.areas.isEmpty)
    #expect(load.notes.count == 1 && load.notes[0].contains(layout.warmup(tree: "t1").path))

    let notes = try await store.record(area: "web", Self.web, tree: "t1")
    #expect(notes.count == 1)
    #expect(store.load(tree: "t1").file.areas == ["web": Self.web])
  }
}
