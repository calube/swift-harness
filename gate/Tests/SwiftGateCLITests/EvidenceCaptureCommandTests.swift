import CryptoKit
import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import Testing

@testable import SwiftGateCLI

/// `evidence capture` runs a real process (never a shell) and stores its output under a temp
/// `<slug>.evidence/captures/` directory — never this checkout's own `docs/`.
@Suite("swiftgate evidence capture")
struct EvidenceCaptureCommandTests {
  static let design = "docs/ordering/designs/queue.md"

  static func withTempRoot(_ body: (URL) async throws -> Void) async throws {
    let root = FileManager.default.temporaryDirectory
      .appending(
        path: "swiftgate-evidence-capture-\(UUID().uuidString)", directoryHint: .isDirectory
      )
      .resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try await body(root)
  }

  @Test(
    "the citation hash matches the bytes actually on disk — catches a pin that doesn't match the stored file"
  )
  func citationHashMatchesStoredBytes() async throws {
    try await Self.withTempRoot { root in
      let report = await EvidenceCaptureRun.capture(
        design: Self.design, argv: ["/bin/echo", "hello capture"], workingDirectory: root,
        runner: LiveProcessRunner())
      #expect(report.verdict == .green)
      let citation = try #require(report.citation)
      #expect(citation.kind == .capture)
      let capturePath = try #require(report.capturePath)
      #expect(capturePath == citation.loc)

      // Recompute the hash from the bytes read back from disk, never from a value the code
      // returned, so a citation that lies about what it stored is caught.
      let onDisk = try Data(contentsOf: root.appending(path: capturePath))
      let recomputed = SHA256.hash(data: onDisk).map { String(format: "%02x", $0) }.joined()
      #expect(citation.pin == "sha256:\(recomputed)")
      #expect(capturePath.hasSuffix("/\(recomputed).txt"))
      #expect(String(decoding: onDisk, as: UTF8.self).contains("hello capture"))
    }
  }

  @Test(
    "a failing command's exit status is stored and the capture still succeeds — catches a nonzero exit swallowed instead of recorded"
  )
  func failingCommandStoresExitStatus() async throws {
    try await Self.withTempRoot { root in
      let missing = root.appending(path: "does-not-exist").path
      let report = await EvidenceCaptureRun.capture(
        design: Self.design, argv: ["/bin/ls", missing], workingDirectory: root,
        runner: LiveProcessRunner())

      // The capture itself succeeds even though the captured command failed.
      #expect(report.verdict == .green)
      let exitCode = try #require(report.exitedWith)
      #expect(exitCode != 0)
      #expect(report.signaledWith == nil)

      let capturePath = try #require(report.capturePath)
      let onDisk = try Data(contentsOf: root.appending(path: capturePath))
      let text = String(decoding: onDisk, as: UTF8.self)
      #expect(text.contains("exit: exited \(exitCode)"))
      // stderr is non-empty: ls names the missing path.
      #expect(text.contains(missing))
    }
  }

  @Test(
    "shell metacharacters in an argument reach the process literally, never a shell — catches execution routed through /bin/sh -c"
  )
  func shellMetacharactersAreNotInterpreted() async throws {
    try await Self.withTempRoot { root in
      let marker = root.appending(path: "pwned").path
      let payload = "$(touch \(marker)); *"
      let report = await EvidenceCaptureRun.capture(
        design: Self.design, argv: ["/bin/echo", payload], workingDirectory: root,
        runner: LiveProcessRunner())

      #expect(report.verdict == .green)
      // If argv had ever reached a shell, this file would exist.
      #expect(!FileManager.default.fileExists(atPath: marker))

      let capturePath = try #require(report.capturePath)
      let onDisk = try Data(contentsOf: root.appending(path: capturePath))
      #expect(String(decoding: onDisk, as: UTF8.self).contains(payload))
    }
  }

  @Test(
    "a command that can't even launch is blocked, not reported as a successful capture — catches a launch failure recorded as evidence"
  )
  func launchFailureIsBlocked() async throws {
    try await Self.withTempRoot { root in
      let missingExecutable = root.appending(path: "no-such-binary-\(UUID())").path
      let report = await EvidenceCaptureRun.capture(
        design: Self.design, argv: [missingExecutable], workingDirectory: root,
        runner: LiveProcessRunner())
      #expect(report.verdict == .blocked)
      #expect(report.citation == nil)
      #expect(report.capturePath == nil)
      #expect(report.message.contains("failed to launch"))
    }
  }

  @Test(
    "a capture directory that can't be created is blocked, not reported as a successful capture — catches a write failure recorded as evidence"
  )
  func writeFailureIsBlocked() async throws {
    try await Self.withTempRoot { root in
      let layout = EvidenceLayout(designDocPath: Self.design)
      let parent = root.appending(path: layout.root, directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
      // A plain file sits where captures/ needs to be a directory.
      try Data().write(to: root.appending(path: layout.capturesDirectory))

      let report = await EvidenceCaptureRun.capture(
        design: Self.design, argv: ["/bin/echo", "hi"], workingDirectory: root,
        runner: LiveProcessRunner())
      #expect(report.verdict == .blocked)
      #expect(report.citation == nil)
      #expect(report.capturePath == nil)
      #expect(!report.message.isEmpty)
    }
  }
}
