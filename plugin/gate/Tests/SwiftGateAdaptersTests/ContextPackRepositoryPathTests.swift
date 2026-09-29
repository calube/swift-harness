import Foundation
import SwiftGateAdapters
import Testing

@Suite("the repository-relative path a context pack cites")
struct ContextPackRepositoryPathTests {
  /// A fresh directory named through `/var` or `/tmp`, which macOS links under `/private`, so the
  /// root and the path can spell the same place differently.
  private static func unresolvedRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appending(
        path: "swiftgate-repository-path-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: root.appending(path: ".git/swift-harness/plans/p", directoryHint: .isDirectory),
      withIntermediateDirectories: true)
    return root
  }

  @Test(
    "a relative path comes back unchanged — catches a relative path read against the working directory"
  )
  func relativeIsUnchanged() throws {
    let root = try Self.unresolvedRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(
      ContextPackFiles.repositoryPath(".git/swift-harness/plans/p/spec-page.md", root: root)
        == ".git/swift-harness/plans/p/spec-page.md")
  }

  @Test(
    "an absolute path inside the root comes back relative to it, whether it spells the root through its symlink or not — catches a path compared as text alone"
  )
  func absoluteInsideIsRelative() throws {
    let root = try Self.unresolvedRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let resolved = root.resolvingSymlinksInPath()
    for base in [root, resolved] {
      let path = base.appending(path: ".git/swift-harness/plans/p/spec-page.md")
        .path(percentEncoded: false)
      #expect(
        ContextPackFiles.repositoryPath(path, root: root)
          == ".git/swift-harness/plans/p/spec-page.md",
        "\(path)")
      #expect(
        ContextPackFiles.repositoryPath(path, root: resolved)
          == ".git/swift-harness/plans/p/spec-page.md", "\(path)")
    }
  }

  @Test(
    "an absolute path outside the root, the root itself, or a sibling sharing its name as a prefix is nil, while a file directly under the root is not — catches a machine path that reaches a pack"
  )
  func absoluteOutsideIsNil() throws {
    let root = try Self.unresolvedRoot().resolvingSymlinksInPath()
    defer { try? FileManager.default.removeItem(at: root) }
    let rootPath = root.path(percentEncoded: false)
    let trimmed = rootPath.hasSuffix("/") ? String(rootPath.dropLast()) : rootPath
    for path in [trimmed, trimmed + "-sibling/spec-page.md", "/etc/hosts"] {
      #expect(ContextPackFiles.repositoryPath(path, root: root) == nil, "\(path)")
    }
    #expect(
      ContextPackFiles.repositoryPath(trimmed + "/spec-page.md", root: root) == "spec-page.md")
  }
}
