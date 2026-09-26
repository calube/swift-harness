import CryptoKit
import Foundation

/// SwiftPM's answers about a package's manifest (`describe`, `dump-package`), kept on disk so a
/// hook or pre-commit run does not pay a `swift` process per package each time. An answer is
/// reused while the package's `Package.swift` and `Package.resolved` are byte-identical and the
/// repository root is unchanged; `describe` reads only the package's own manifest, so a change
/// in a dependency's manifest does not invalidate it. Unreadable or unwritable entries only cost
/// a fresh `swift` run.
struct ManifestAnswerCache: Sendable {
  private static let format = "1"

  let directory: URL
  let repositoryRoot: String

  func answer(_ command: String, packageDirectory: String) -> Data? {
    guard let key = key(command, packageDirectory: packageDirectory),
      let stored = try? Data(contentsOf: file(command, packageDirectory: packageDirectory)),
      let newline = stored.firstIndex(of: UInt8(ascii: "\n")),
      stored[..<newline].elementsEqual(key.utf8)
    else { return nil }
    return stored[stored.index(after: newline)...]
  }

  func store(_ output: Data, _ command: String, packageDirectory: String) {
    guard let key = key(command, packageDirectory: packageDirectory) else { return }
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try? (Data("\(key)\n".utf8) + output).write(
      to: file(command, packageDirectory: packageDirectory), options: .atomic)
  }

  private func file(_ command: String, packageDirectory: String) -> URL {
    directory.appending(path: "\(Self.hex(Data("\(command)\0\(packageDirectory)".utf8))).answer")
  }

  /// `nil` when the manifest cannot be read: let `swift` report why.
  private func key(_ command: String, packageDirectory: String) -> String? {
    let package =
      packageDirectory.isEmpty
      ? URL(filePath: repositoryRoot, directoryHint: .isDirectory)
      : URL(filePath: repositoryRoot, directoryHint: .isDirectory).appending(
        path: packageDirectory, directoryHint: .isDirectory)
    guard let manifest = try? Data(contentsOf: package.appending(path: "Package.swift")) else {
      return nil
    }
    let resolved = try? Data(contentsOf: package.appending(path: "Package.resolved"))
    var hasher = SHA256()
    for part in [Self.format, command, repositoryRoot, packageDirectory] {
      hasher.update(data: Data("\(part)\0".utf8))
    }
    hasher.update(data: manifest)
    hasher.update(data: Data(resolved == nil ? "\0absent".utf8 : "\0present\0".utf8))
    if let resolved { hasher.update(data: resolved) }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  private static func hex(_ data: Data) -> String {
    SHA256.hash(data: data).prefix(16).map { String(format: "%02x", $0) }.joined()
  }
}
