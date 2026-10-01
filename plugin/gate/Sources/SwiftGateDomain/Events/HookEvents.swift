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
  public static func toolName(_ name: String?) -> String? {
    identifier(name, allowing: [UInt8(ascii: "_")])
  }

  /// `id` when it is `[A-Za-z0-9_-]{1,128}`, else `nil`.
  public static func sessionID(_ id: String?) -> String? {
    identifier(id, allowing: [UInt8(ascii: "_"), UInt8(ascii: "-")])
  }

  private static func identifier(_ text: String?, allowing extra: Set<UInt8>) -> String? {
    guard let text, (1...maxIdentifierLength).contains(text.utf8.count),
      text.utf8.allSatisfy({ isASCIIAlphanumeric($0) || extra.contains($0) })
    else { return nil }
    return text
  }

  private static func isASCIIAlphanumeric(_ byte: UInt8) -> Bool {
    (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
  }

  /// The decision `stdout`, a hook's printed JSON, states.
  public static func decision(stdout: String?) -> HookDecision {
    guard let object = json(stdout) else { return .none }
    let specific = object["hookSpecificOutput"] as? [String: Any]
    switch specific?["permissionDecision"] as? String {
    case "deny": return .block
    case "allow": return .allow
    case "ask": return .ask
    default: break
    }
    if object["decision"] as? String == "block" { return .block }
    if specific?["additionalContext"] != nil || object["systemMessage"] != nil { return .context }
    return .none
  }

  /// The rule ids `stdout` names: a denial's `swiftgate <rule>:` prefix and each finding line's
  /// `- [<severity>] <rule>`.
  public static func ruleIDs(stdout: String?) -> [String] {
    guard let object = json(stdout) else { return [] }
    let specific = object["hookSpecificOutput"] as? [String: Any]
    let texts = [
      specific?["permissionDecisionReason"], specific?["additionalContext"], object["reason"],
      object["systemMessage"],
    ].compactMap { $0 as? String }
    var ids: Set<String> = []
    for line in texts.flatMap({ $0.split(separator: "\n") }) {
      if line.hasPrefix("swiftgate "), let end = line.firstIndex(of: ":") {
        ids.insert(String(line[line.index(line.startIndex, offsetBy: 10)..<end]))
      } else if line.hasPrefix("- ["), let close = line.firstIndex(of: "]") {
        let rest = line[line.index(after: close)...].drop(while: { $0 == " " })
        ids.insert(String(rest.prefix(while: { $0 != " " })))
      }
    }
    return ids.filter(isRuleID).sorted()
  }

  /// Lowercase dotted words, as every gate rule id is spelled.
  private static func isRuleID(_ text: String) -> Bool {
    let words = text.split(separator: ".", omittingEmptySubsequences: false)
    return words.count >= 2 && text.utf8.count < EventPayloadGuard.maxStringBytes
      && words.allSatisfy { word in
        !word.isEmpty
          && word.utf8.allSatisfy {
            (0x61...0x7A).contains($0) || (0x30...0x39).contains($0) || $0 == UInt8(ascii: "-")
          }
      }
  }

  private static func json(_ stdout: String?) -> [String: Any]? {
    guard let stdout else { return nil }
    return (try? JSONSerialization.jsonObject(with: Data(stdout.utf8))) as? [String: Any]
  }

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
  public static func of(payload: Data, salt: String) -> String? {
    guard
      let object = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any],
      let input = object["tool_input"],
      let canonical = try? JSONSerialization.data(
        withJSONObject: input, options: [.sortedKeys, .fragmentsAllowed])
    else { return nil }
    let mac = HMAC<SHA256>.authenticationCode(
      for: canonical, using: SymmetricKey(data: Data(salt.utf8)))
    return mac.map { String(format: "%02x", $0) }.joined()
  }
}
