import Foundation
import SwiftGateAdapters
import SwiftGateTestSupport
import Testing

/// This repository's own root `lefthook.yml`: `plugin-repo-prepush-not-wired` found the plugin
/// repo had no pre-push hook, so `check --tier push` (and the commit-msg comments check) never ran
/// automatically here, unlike every consumer bootstrap stamps.
@Suite("this repository's lefthook.yml")
struct RepositoryLefthookTests {
  static func onPath(_ name: String) -> Bool {
    let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
    return path.split(separator: ":").contains {
      FileManager.default.isExecutableFile(atPath: "\($0)/\(name)")
    }
  }

  @Test(
    "pre-push runs the push tier through the plugin shim and commit-msg runs the comments check, and AGENTS.md tells contributors to install it — catches the contributor pre-push gate silently unwired"
  )
  func wiring() throws {
    let text = try String(
      contentsOf: Fixture.harnessCheckout.appending(path: "lefthook.yml"), encoding: .utf8)
    #expect(text.contains(#""plugin/bin/swiftgate" check --tier push"#))
    #expect(text.contains(#""plugin/bin/swiftgate" comments --commit-msg"#))
    let agents = try String(
      contentsOf: Fixture.harnessCheckout.appending(path: "AGENTS.md"), encoding: .utf8)
    #expect(agents.contains("lefthook install"))
  }

  @Test(
    "lefthook install actually wires the pre-push and commit-msg scripts — catches YAML that looks right but lefthook itself rejects",
    .enabled(if: onPath("lefthook") && onPath("git"), "lefthook or git is not on PATH")
  )
  func installs() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "root-lefthook-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let runner = LiveProcessRunner()
    let initialized = try await runner.run(
      ProcessInvocation(
        executable: "git", arguments: ["init", "-q"], workingDirectory: root.path,
        timeout: .seconds(10)))
    #expect(initialized.status.isSuccess, "\(initialized.stderr.text)")
    try FileManager.default.copyItem(
      at: Fixture.harnessCheckout.appending(path: "lefthook.yml"),
      to: root.appending(path: "lefthook.yml"))

    let install = try await runner.run(
      ProcessInvocation(
        executable: "lefthook", arguments: ["install"], workingDirectory: root.path,
        timeout: .seconds(30)))
    #expect(install.status.isSuccess, "\(install.stderr.text)")
    for hook in ["pre-push", "commit-msg"] {
      #expect(
        FileManager.default.fileExists(atPath: root.appending(path: ".git/hooks/\(hook)").path),
        "expected lefthook to install a \(hook) hook")
    }
  }
}
