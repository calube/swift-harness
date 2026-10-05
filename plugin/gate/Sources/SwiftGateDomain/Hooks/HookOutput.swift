import Foundation

/// The JSON a hook prints on stdout, in the shapes Claude Code documents per event. Every hook
/// exits 0 and decides through this JSON, never through exit code 2, so the decision and its
/// reason travel together.
public enum HookOutput {
  /// Context Claude reads: SessionStart at the start of the session, PreToolUse and PostToolUse
  /// next to the tool result.
  public static func context(_ event: HookEvent, _ text: String) -> String {
    encode(["hookSpecificOutput": ["hookEventName": event.claudeName, "additionalContext": text]])
  }

  /// PreToolUse: refuse the tool call; `reason` is shown to Claude.
  public static func deny(_ reason: String) -> String {
    encode([
      "hookSpecificOutput": [
        "hookEventName": HookEvent.preToolUse.claudeName, "permissionDecision": "deny",
        "permissionDecisionReason": reason,
      ]
    ])
  }

  /// PreToolUse: allow the tool call without a permission prompt; `reason` is shown to the user,
  /// and `context`, when given, to Claude next to the tool result.
  public static func allow(_ reason: String, context: String? = nil) -> String {
    var output = [
      "hookEventName": HookEvent.preToolUse.claudeName, "permissionDecision": "allow",
      "permissionDecisionReason": reason,
    ]
    if let context { output["additionalContext"] = context }
    return encode(["hookSpecificOutput": output])
  }

  /// PreToolUse: run the call with `toolInput`, the whole `tool_input` object, in place of the
  /// one Claude sent. With `allow`, the call is also allowed with that reason shown to the user;
  /// without it, the call goes on to the normal permission flow. `context`, when given, is shown
  /// to Claude next to the tool result.
  public static func rewrite(
    toolInput: [String: Any], allow: String? = nil, context: String? = nil
  ) -> String {
    "{}"
  }

  /// PostToolUse: put `reason` next to the tool result as a problem to fix. Stop: refuse to stop
  /// and give Claude `reason` as what to do next.
  public static func block(_ reason: String) -> String {
    encode(["decision": "block", "reason": reason])
  }

  /// A message shown to the user without continuing the conversation.
  public static func systemMessage(_ text: String) -> String {
    encode(["systemMessage": text])
  }

  private static func encode(_ object: [String: Any]) -> String {
    // Only strings and nested string dictionaries reach here, which always serialize.
    guard
      let data = try? JSONSerialization.data(
        withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    else { return "{}" }
    return String(decoding: data, as: UTF8.self)
  }
}
