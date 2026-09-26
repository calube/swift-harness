import Foundation
import SwiftGateAdapters
import Testing

@Suite("canonical paths")
struct CanonicalPathTests {
  @Test(
    "the temporary directory resolves to its /private/var/folders form, as the compiler reports it — catches roots that never prefix a tool-reported path under /var or /tmp"
  )
  func temporaryDirectory() throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "swiftgate-canonical-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let foundation = directory.resolvingSymlinksInPath().path
    #expect(foundation.hasPrefix("/var/folders/"))

    #expect(CanonicalPath.of(directory) == "/private" + foundation)
    #expect(CanonicalPath.of(URL(filePath: "/private" + foundation)) == "/private" + foundation)
    #expect(CanonicalPath.of(URL(filePath: "/tmp")) == "/private/tmp")
  }

  @Test(
    "a path that does not exist keeps its missing components under its resolved ancestor — catches a new file's path compared in a different spelling from its root"
  )
  func missingComponents() throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "swiftgate-canonical-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let root = CanonicalPath.of(directory)

    #expect(
      CanonicalPath.of(directory.appending(path: "New/File.swift")) == root + "/New/File.swift")
    #expect(
      CanonicalPath.of(directory.appending(path: "New/../Other.swift")) == root + "/Other.swift")
    #expect(CanonicalPath.of(URL(filePath: "/no/such/dir")) == "/no/such/dir")
  }

  @Test(
    "symlinks inside the path are resolved — catches a symlinked checkout judged as two repositories"
  )
  func symlink() throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "swiftgate-canonical-\(UUID().uuidString)", directoryHint: .isDirectory)
    let real = directory.appending(path: "real", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let link = directory.appending(path: "link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

    #expect(
      CanonicalPath.of(link.appending(path: "A.swift")) == CanonicalPath.of(real) + "/A.swift")
    #expect(
      CanonicalPath.url(link.appending(path: "Sub", directoryHint: .isDirectory)).hasDirectoryPath)
  }
}
