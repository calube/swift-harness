import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@Suite("Hook adapters")
struct HookAdaptersTests {
  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appending(path: "swiftgate-hook-\(UUID().uuidString)", directoryHint: .isDirectory)
      .resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  @Test(
    "the project root is the nearest ancestor with .swiftgate.toml, never past the git root — catches hooks acting on a parent repository's config"
  )
  func locatesProjectRoot() throws {
    let base = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: base) }
    let outer = base.appending(path: "outer")
    let app = outer.appending(path: "examples/App")
    let nestedRepo = outer.appending(path: "vendor/Other")
    for directory in [app.appending(path: "Packages/Feed"), nestedRepo.appending(path: "Sources")] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    try Data().write(to: outer.appending(path: ".swiftgate.toml"))
    try Data().write(to: app.appending(path: ".swiftgate.toml"))
    try FileManager.default.createDirectory(
      at: nestedRepo.appending(path: ".git"), withIntermediateDirectories: true)

    #expect(ProjectRoot.locate(from: app.appending(path: "Packages/Feed"))?.path == app.path)
    #expect(ProjectRoot.locate(from: outer.appending(path: "examples"))?.path == outer.path)
    #expect(ProjectRoot.locate(from: nestedRepo.appending(path: "Sources")) == nil)
    #expect(ProjectRoot.locate(from: base) == nil)
  }

  @Test(
    "hook state round-trips per session, survives corruption as empty, and ignores itself in git — catches strikes leaking between sessions or state committed"
  )
  func hookState() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = HookStateStore(worktreeRoot: root)
    let state = StopState(
      consecutiveBlocks: 2, lastRed: StopState.RedMemo(fingerprint: "f", summary: "RED"))

    try store.saveStopState(state, session: "session/../a")
    try store.saveLastGreen("abc")

    #expect(store.stopState(session: "session/../a") == state)
    #expect(store.stopState(session: "other") == StopState())
    #expect(store.lastGreen() == "abc")
    let ignore = try String(
      contentsOf: root.appending(path: "\(HookStateStore.directory)/.gitignore"), encoding: .utf8)
    #expect(ignore == "*\n")
    let files = try FileManager.default.contentsOfDirectory(
      atPath: root.appending(path: HookStateStore.directory).path)
    #expect(files.allSatisfy { !$0.contains("/") && !$0.hasPrefix("..") })

    try Data("{not json".utf8).write(
      to: root.appending(path: HookStateStore.directory).appending(
        path: files.first { $0.hasPrefix("stop-") } ?? "x"))
    #expect(store.stopState(session: "session/../a") == StopState())
  }

  @Test(
    "the selected Xcode is DEVELOPER_DIR, else xcode-select, read from its Info.plist — catches the pin check reading the wrong Xcode"
  )
  func selectedXcode() async throws {
    let base = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: base) }
    let developer = base.appending(path: "Xcode-26.1.app/Contents/Developer")
    try FileManager.default.createDirectory(at: developer, withIntermediateDirectories: true)
    let plist = try PropertyListSerialization.data(
      fromPropertyList: ["CFBundleShortVersionString": "26.1"], format: .xml, options: 0)
    try plist.write(to: base.appending(path: "Xcode-26.1.app/Contents/Info.plist"))

    let fromEnvironment = LiveXcodeSelection(
      runner: FakeProcessRunner { _ throws(ProcessRunnerError) in
        Issue.record("xcode-select must not run when DEVELOPER_DIR is set")
        return ProcessOutput(status: .exited(1))
      }, developerDirectoryOverride: developer.path)
    let viaSelect = LiveXcodeSelection(
      runner: FakeProcessRunner { invocation throws(ProcessRunnerError) in
        #expect(invocation.executable == "/usr/bin/xcode-select")
        return ProcessOutput(status: .exited(0), stdout: developer.path + "\n")
      }, developerDirectoryOverride: nil)

    #expect(try await fromEnvironment.selected().version == "26.1")
    #expect(try await viaSelect.selected().developerDirectory == developer.path)
    #expect(try await viaSelect.selected().version == "26.1")
  }

  @Test(
    "revision resolves HEAD and is nil before the first commit — catches a fresh repo read as an error"
  )
  func revision() async throws {
    let repo = try await TemporaryGitRepository()
    defer { repo.remove() }
    #expect(try await repo.adapter.revision("HEAD") == nil)
    try repo.write("A.swift", "let a = 1\n")
    let head = try await repo.commitAll("base")
    #expect(try await repo.adapter.revision("HEAD") == head)
  }
}
