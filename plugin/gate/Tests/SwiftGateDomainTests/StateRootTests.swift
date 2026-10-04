import Foundation
import Testing

@Suite("state root: one seam for every state path")
struct StateRootTests {
  static let sources = URL(filePath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "Sources", directoryHint: .isDirectory)

  @Test(
    "no source file outside RunLayout spells a \".harness code literal — catches a state path that bypasses the state root and dirties a tree the harness doesn't own"
  )
  func onlyRunLayoutNamesTheTreeDirectory() throws {
    var offenders: [String] = []
    var scanned = 0
    let walker = FileManager.default.enumerator(at: Self.sources, includingPropertiesForKeys: nil)
    while let url = walker?.nextObject() as? URL {
      guard url.pathExtension == "swift", url.lastPathComponent != "RunLayout.swift" else {
        continue
      }
      let text = try String(contentsOf: url, encoding: .utf8)
      scanned += 1
      for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false)
        .enumerated()
      where !line.trimmingCharacters(in: .whitespaces).hasPrefix("//")
        && line.contains("\".harness")
      {
        offenders.append("\(url.lastPathComponent):\(number + 1)")
      }
    }
    #expect(scanned > 100, "scanned \(scanned) files under \(Self.sources.path)")
    #expect(offenders.isEmpty, "\(offenders)")
  }
}
