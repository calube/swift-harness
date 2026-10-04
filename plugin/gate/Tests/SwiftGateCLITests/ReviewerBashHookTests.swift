import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

/// Replays the recorded verifier span call, with its command and agent swapped in.
@Suite("PreToolUse limits a review agent's Bash to its span lines")
struct ReviewerBashHookTests {
  static let fixture = "pre-tool-use-bash-reviewer-span"
  static let recordedCommand =
    "/PLUGIN/bin/swiftgate events span start --phase verify --build-run 20261004-capture "
    + "--task 'reviewer-span' --role review"

  /// The hook's `hookSpecificOutput`, or `nil` when it printed nothing.
  func decide(
    _ command: String = recordedCommand, agentType: String = "swift-harness:verifier",
    inProject: Bool = true
  ) async throws -> [String: String]? {
    let harness = try HookHarness()
    defer { harness.repository.remove() }
    let outside = FileManager.default.temporaryDirectory
      .appending(path: "swiftgate-outside-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: outside) }
    let quoted = String(decoding: try JSONEncoder().encode(command), as: UTF8.self)
    let (result, _) = try await harness.run(
      .preToolUse, Self.fixture, cwd: inProject ? nil : outside,
      replacing: [
        "\"\(Self.recordedCommand)\"": quoted,
        "\"swift-harness:verifier\"": "\"\(agentType)\"",
      ])
    guard result.stdout != nil else { return nil }
    return try #require(try harness.json(result)["hookSpecificOutput"] as? [String: String])
  }

  @Test(
    "the recorded verifier span line is allowed outright, and the same line with `&& rm` is denied naming the rule — catches the hook blocking a reviewer's own span, or passing a chained one"
  )
  func recordedSpanLineAllowedAndChainDenied() async throws {
    let allowed = try #require(try await decide())
    #expect(allowed["permissionDecision"] == "allow")
    let denied = try #require(try await decide(Self.recordedCommand + " && rm -rf Sources"))
    #expect(denied["permissionDecision"] == "deny")
    #expect(denied["permissionDecisionReason"]?.contains(ReviewerBashGuard.ruleID) == true)
  }

  @Test(
    "each reviewer's git commit and rm are denied, while the build worker's same commit is allowed — catches a reviewer changing the tree, or the worker losing its Bash",
    arguments: ["git commit -am 'apply the finding'", "rm -rf Sources"])
  func reviewersDeniedWorkerAllowed(_ command: String) async throws {
    for agent in ReviewerBashGuard.reviewerAgentTypes {
      let denied = try #require(try await decide(command, agentType: agent), "\(agent)")
      #expect(denied["permissionDecision"] == "deny", "\(agent)")
      #expect(denied["permissionDecisionReason"]?.contains(ReviewerBashGuard.ruleID) == true)
    }
    let worker = try #require(
      try await decide("git commit -am 'implement'", agentType: "swift-harness:build-worker"))
    #expect(worker["permissionDecision"] == "allow")
  }

  @Test(
    "outside a swiftgate project a reviewer's rm is still denied, while its span line and the worker's commands stay silent — catches the reviewer limit lapsing where the other hooks no-op"
  )
  func outsideProjectStillGuardsReviewers() async throws {
    let denied = try #require(try await decide("rm -rf Sources", inProject: false))
    #expect(denied["permissionDecision"] == "deny")
    #expect(denied["permissionDecisionReason"]?.contains(ReviewerBashGuard.ruleID) == true)
    #expect(try await decide(inProject: false) == nil)
    #expect(
      try await decide("rm -rf x", agentType: "swift-harness:build-worker", inProject: false)
        == nil)
  }
}
