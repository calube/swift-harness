import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

/// Runs the built `swiftgate` against a temp clone with a fake `claude` first on `PATH`, which
/// writes each argument it receives on its own line.
@Suite("swiftgate claude")
struct ClaudeCommandTests {
  struct Clone {
    let root: URL
    let bin: URL
    let record: URL

    init() throws {
      root = FileManager.default.temporaryDirectory
        .appending(path: "swiftgate-claude-\(UUID().uuidString)", directoryHint: .isDirectory)
      bin = root.appending(path: "bin", directoryHint: .isDirectory)
      record = root.appending(path: "received.txt")
      let worktree = root.appending(path: "repo", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(
        at: worktree.appending(path: ".git", directoryHint: .isDirectory),
        withIntermediateDirectories: true)
      try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
      let fake = bin.appending(path: "claude")
      try Data(
        "#!/bin/sh\nfor argument in \"$@\"; do printf '%s\\n' \"$argument\"; done > '\(record.path)'\n"
          .utf8
      ).write(to: fake)
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
    }

    var worktree: URL { root.appending(path: "repo", directoryHint: .isDirectory) }
    var layout: BrownfieldStateLayout {
      BrownfieldStateLayout(
        commonDir: worktree.appending(path: ".git"), gitDir: worktree.appending(path: ".git"))
    }

    func writeState(settings: Bool) throws {
      try FileManager.default.createDirectory(
        at: layout.cloneRoot, withIntermediateDirectories: true)
      try Data("schema = 1\n".utf8).write(to: layout.config)
      if settings { try Data("{\"hooks\":{}}".utf8).write(to: layout.settings) }
    }

    func run(_ arguments: [String], cwd: URL) throws -> (status: Int32, stderr: String) {
      let process = Process()
      process.executableURL = Fixture.gateDirectory.appending(path: ".build/debug/swiftgate")
      process.arguments = arguments
      process.currentDirectoryURL = cwd
      var environment = ProcessInfo.processInfo.environment
      environment["PATH"] = bin.path + ":/usr/bin:/bin"
      environment["LLVM_PROFILE_FILE"] = root.appending(path: "%p.profraw").path
      process.environment = environment
      let errors = Pipe()
      process.standardError = errors
      process.standardOutput = FileHandle.nullDevice
      try process.run()
      let data = errors.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    var received: [String]? {
      (try? String(contentsOf: record, encoding: .utf8)).map {
        $0.split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init)
      }
    }
  }

  @Test(
    "claude receives --settings with the clone's settings file, then the passed args in order — catches args dropped or reordered"
  )
  func passesSettingsThenArguments() throws {
    let clone = try Clone()
    defer { try? FileManager.default.removeItem(at: clone.root) }
    try clone.writeState(settings: true)
    let subdirectory = clone.worktree.appending(path: "src", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: subdirectory, withIntermediateDirectories: true)

    let result = try clone.run(
      ["claude", "--resume", "-p", "hello world", "--", "x"], cwd: subdirectory)

    #expect(result.status == 0, "\(result.stderr)")
    let received = try #require(clone.received)
    #expect(received.count == 7)
    #expect(received.first == "--settings")
    #expect(
      received.dropFirst().first.map { URL(filePath: $0).resolvingSymlinksInPath().path }
        == clone.layout.settings.resolvingSymlinksInPath().path)
    #expect(Array(received.dropFirst(2)) == ["--resume", "-p", "hello world", "--", "x"])
  }

  @Test(
    "with no settings file claude never starts and the error names the file — catches a session started without the hooks"
  )
  func missingSettingsBlocks() throws {
    let clone = try Clone()
    defer { try? FileManager.default.removeItem(at: clone.root) }
    try clone.writeState(settings: false)

    let result = try clone.run(["claude", "-p", "hello"], cwd: clone.worktree)

    #expect(result.status == 2)
    #expect(result.stderr.contains("swift-harness/settings.json"))
    #expect(result.stderr.contains("discover --apply"))
    #expect(clone.received == nil)
  }
}
