import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import Testing

@Suite("brownfield config file")
struct BrownfieldConfigFileTests {
  static func makeDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "swiftgate-config-file-\(UUID().uuidString)", directoryHint: .isDirectory)
      .resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  @Test(
    "a linked worktree finds the config under the common dir, not its own git dir — catches a writer that creates a second config per worktree"
  )
  func linkedWorktree() throws {
    let root = try Self.makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let common = root.appending(path: "clone/.git", directoryHint: .isDirectory)
    let gitDir = common.appending(path: "worktrees/task", directoryHint: .isDirectory)
    let worktree = root.appending(path: "task", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: common.appending(path: "swift-harness"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
    try Data("schema = 1\n".utf8).write(to: common.appending(path: "swift-harness/config.toml"))
    try Data("../..\n".utf8).write(to: gitDir.appending(path: "commondir"))
    try Data("gitdir: \(gitDir.path)\n".utf8).write(to: worktree.appending(path: ".git"))

    let file = try BrownfieldConfigFile.locate(worktree: worktree)
    #expect(
      file.url.standardizedFileURL.path
        == common.appending(path: "swift-harness/config.toml").standardizedFileURL.path)
  }

  @Test(
    "an invalid config fails the update and stays byte for byte — catches a writer that replaces what it couldn't read"
  )
  func invalidConfigUntouched() throws {
    let root = try Self.makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appending(path: "config.toml")
    let original = Data("schema = 1\n[harness]\nprofile = \"owned\"\n".utf8)
    try original.write(to: url)
    var called = false
    let error = #expect(throws: BrownfieldConfigFileError.self) {
      try BrownfieldConfigFile(url: url).update { config in
        called = true
        return config
      }
    }
    guard case .invalid(let path, _) = error else {
      Issue.record("expected invalid, got \(String(describing: error))")
      return
    }
    #expect(path == url.path)
    #expect(!called)
    #expect(try Data(contentsOf: url) == original)
  }
}
