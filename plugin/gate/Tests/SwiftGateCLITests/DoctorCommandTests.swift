import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

/// `doctor` against a temp repository holding session records and a real plugin-shaped tree in
/// another temp directory. The machine probes all fail to launch, so only the repository and the
/// session records decide the plugin findings.
@Suite("doctor: session plugin records")
struct DoctorCommandTests {
  private static let config = """
    schema = 1
    xcode = "26.2"
    app_scheme = "App"
    packages = ["Packages/*"]

    [simulator]
    device = "iPhone 17"
    os = "26.2"
    """

  private static let pluginFiles: [String: String] = [
    ".claude-plugin/plugin.json": #"{"name":"swift-harness","version":"0.1.0"}"#,
    "skills/build/SKILL.md": "# Build\n",
    "agents/build-worker.md": "You are a build worker.\n",
    "workflows/build-task.js": "export default {}\n",
  ]

  private let repository: URL
  private let plugin: URL

  init() throws {
    func directory(_ prefix: String) -> URL {
      TestTemporaryDirectory.root
        .appending(path: "\(prefix)-\(UUID().uuidString)", directoryHint: .isDirectory)
        .resolvingSymlinksInPath()
    }
    repository = directory("swiftgate-doctor-repo")
    plugin = directory("swiftgate-doctor-plugin")
    try Self.write(repository, ".swiftgate.toml", Self.config)
    for (path, content) in Self.pluginFiles { try Self.write(plugin, path, content) }
  }

  private static func write(_ root: URL, _ path: String, _ content: String) throws {
    let url = root.appending(path: path)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(content.utf8).write(to: url)
  }

  private func cleanUp() {
    TestTemporaryDirectory.remove(repository)
    TestTemporaryDirectory.remove(plugin)
  }

  /// Records `id` as starting now-ish, against the plugin tree as it is on disk.
  private func recordSession(_ id: String, at seconds: TimeInterval) throws {
    let record = try SessionRecord(
      sessionId: id, recordedAt: Date(timeIntervalSince1970: seconds), pluginRoot: plugin.path,
      pluginVersion: "0.1.0", treeHash: try PluginTree.hash(root: plugin), transcriptPath: nil)
    try SessionRecordStore(worktreeRoot: repository).write(record)
  }

  private func editPrompt() throws {
    try Self.write(plugin, "agents/build-worker.md", "You are a build worker. Loop to green.\n")
  }

  private func sessionFindings(_ sessionID: String?) async throws -> [Finding] {
    let runner = FakeProcessRunner { invocation throws(ProcessRunnerError) in
      throw .launchFailed(executable: invocation.executable, reason: "not on this test machine")
    }
    let parts = try await DoctorRun.run(
      root: repository, sessionID: sessionID, swiftPM: FakeSwiftPM(serving: []), runner: runner)
    return parts.findings.filter {
      [Doctor.pluginChangedRuleID, Doctor.sessionRecordRuleID].contains($0.ruleID)
    }
  }

  @Test(
    "a prompt edited after the session recorded its tree is a major doctor.plugin-changed naming both real hashes, and an unedited tree passes — catches doctor comparing anything but the tree at the record's plugin root"
  )
  func editedPromptFailsAndUneditedPasses() async throws {
    defer { cleanUp() }
    try recordSession("session-a", at: 1_000)
    let before = try PluginTree.hash(root: plugin)
    #expect(try await sessionFindings("session-a").isEmpty)

    try editPrompt()
    let after = try PluginTree.hash(root: plugin)
    let findings = try await sessionFindings("session-a")
    let finding = try #require(findings.first)
    #expect(findings.count == 1)
    #expect(finding.ruleID == Doctor.pluginChangedRuleID)
    #expect(finding.severity == .major)
    #expect(finding.message.contains(before))
    #expect(finding.message.contains(after))
  }

  @Test(
    "--session judges that session's record, never the newest or another session's — catches a stale older session passing on a fresh session's record, or a fresh one failing on a stale one's"
  )
  func sessionPicksItsOwnRecord() async throws {
    defer { cleanUp() }
    try recordSession("session-a", at: 1_000)
    try editPrompt()
    try recordSession("session-b", at: 2_000)

    #expect(try await sessionFindings("session-a").map(\.ruleID) == [Doctor.pluginChangedRuleID])
    #expect(try await sessionFindings("session-b").isEmpty)
    #expect(try await sessionFindings(nil).isEmpty)

    let unknown = try await sessionFindings("session-c")
    #expect(unknown.map(\.ruleID) == [Doctor.sessionRecordRuleID])
    #expect(unknown.map(\.severity) == [.nit])
    #expect(unknown.first?.message.contains("session-c") == true)
  }

  @Test(
    "without --session the newest record is judged — catches doctor reading the oldest or any record"
  )
  func newestRecordWithoutSession() async throws {
    defer { cleanUp() }
    try recordSession("session-b", at: 1_000)
    try editPrompt()
    try recordSession("session-a", at: 2_000)
    #expect(try await sessionFindings(nil).isEmpty)
    try editPrompt()
    try Self.write(plugin, "skills/build/SKILL.md", "# Build, again\n")
    #expect(try await sessionFindings(nil).map(\.ruleID) == [Doctor.pluginChangedRuleID])
  }

  @Test(
    "a deleted plugin root is a major doctor.plugin-changed naming it — catches a session whose plugin moved passing as unchanged"
  )
  func deletedPluginRootFails() async throws {
    defer { cleanUp() }
    try recordSession("session-a", at: 1_000)
    try FileManager.default.removeItem(at: plugin)
    let findings = try await sessionFindings("session-a")
    #expect(findings.map(\.ruleID) == [Doctor.pluginChangedRuleID])
    #expect(findings.map(\.severity) == [.major])
    #expect(findings.first?.message.contains(plugin.path) == true)
  }

  @Test(
    "no session records at all is a doctor.session-record nit and never a gating finding — catches a repository bootstrapped before the hook failing doctor"
  )
  func noRecordsIsANote() async throws {
    defer { cleanUp() }
    let findings = try await sessionFindings(nil)
    #expect(findings.map(\.ruleID) == [Doctor.sessionRecordRuleID])
    #expect(findings.allSatisfy { !$0.severity.failsGate })
  }

  @Test(
    "a record of an unknown schema version is a major doctor.session-record naming its file, asked for by --session or found by the scan — catches an unreadable record silently treated as a match"
  )
  func unreadableRecordFails() async throws {
    defer { cleanUp() }
    try recordSession("session-a", at: 1_000)
    let file = try SessionRecordStore(worktreeRoot: repository).file(sessionID: "session-z")
    try Data(#"{"schemaVersion":2}"#.utf8).write(to: file)

    for sessionID in ["session-z", nil] {
      let findings = try await sessionFindings(sessionID)
      #expect(findings.map(\.ruleID) == [Doctor.sessionRecordRuleID], "\(sessionID ?? "newest")")
      #expect(findings.map(\.severity) == [.major])
      #expect(findings.first?.message.contains("session-z.json") == true)
      #expect(findings.first?.message.contains("schemaVersion 2") == true)
    }
    #expect(try await sessionFindings("session-a").isEmpty)
  }
}
