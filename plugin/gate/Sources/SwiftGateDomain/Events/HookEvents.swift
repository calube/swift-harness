import CryptoKit
import Foundation

/// What a hook call told Claude Code, read from the JSON it printed.
public enum HookDecision: String, Sendable, Codable, CaseIterable {
  /// PreToolUse allowed the call without a permission prompt.
  case allow
  /// PreToolUse denied the call, or PostToolUse or Stop blocked.
  case block
  case ask
  /// Context or a message for Claude or the user, and no decision.
  case context
  /// The hook printed nothing.
  case none
}

extension HookEvent: Codable {}

/// `hook.decision`: 1 hook call. Ids, a closed decision and a salted hash only: the tool input,
/// command text, file paths and the hook's own reason text never go in.
public struct HookDecisionEvent: Sendable, Equatable, Codable {
  /// The longest tool name or session id kept.
  public static let maxIdentifierLength = 128

  public let event: HookEvent
  /// `nil` when the payload named no tool, or a name outside `[A-Za-z0-9_]{1,128}`.
  public let tool: String?
  public let decision: HookDecision
  /// The rule ids the hook's output names, sorted.
  public let ruleIDs: [String]
  /// The hook's own time, without reading the payload or writing this event.
  public let milliseconds: Int
  public let sessionID: String?
  /// ``HookInputHash`` of the tool input; `nil` for an event with no tool input.
  public let inputHash: String?

  public init(
    event: HookEvent, tool: String?, decision: HookDecision, ruleIDs: [String], milliseconds: Int,
    sessionID: String?, inputHash: String?
  ) {
    self.event = event
    self.tool = tool
    self.decision = decision
    self.ruleIDs = ruleIDs
    self.milliseconds = milliseconds
    self.sessionID = sessionID
    self.inputHash = inputHash
  }

  /// `name` when it is `[A-Za-z0-9_]{1,128}`, else `nil`.
  public static func toolName(_ name: String?) -> String? { nil }

  /// `id` when it is `[A-Za-z0-9_-]{1,128}`, else `nil`.
  public static func sessionID(_ id: String?) -> String? { nil }

  /// The decision `stdout`, a hook's printed JSON, states.
  public static func decision(stdout: String?) -> HookDecision { .none }

  /// The rule ids `stdout` names: a denial's `swiftgate <rule>:` prefix and each finding line's
  /// `- [<severity>] <rule>`.
  public static func ruleIDs(stdout: String?) -> [String] { [] }

  private enum CodingKeys: String, CodingKey {
    case event, tool, decision, ruleIDs, sessionID, inputHash
    case milliseconds = "ms"
  }
}

/// The HMAC-SHA-256 of a hook payload's `tool_input` under a store's salt: 2 calls with the same
/// input match inside 1 store, and a short command can't be recovered by hashing guesses.
public enum HookInputHash {
  /// Lowercase hex, or `nil` when `payload` has no `tool_input`. The input is re-serialized with
  /// sorted keys, so key order doesn't change the hash.
  public static func of(payload: Data, salt: String) -> String? { nil }
}
