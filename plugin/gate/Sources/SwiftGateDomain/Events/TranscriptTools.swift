import Foundation

/// 1 `tool_use` of a transcript: its id, kind and time, and the path a file tool named. Held in
/// memory only: ``ToolIngest`` stores counts and repo-relative paths, never the raw path.
public struct TranscriptToolCall: Sendable, Equatable {
  public let id: String
  /// `nil` for a name ``ToolKind`` doesn't hold.
  public let kind: ToolKind?
  public let time: Date
  /// `tool_use` to `tool_result`; `nil` when the transcript holds no result for it.
  public let milliseconds: Int?
  /// `file_path`, `path` or `notebook_path` of a file tool, as the agent wrote it.
  public let path: String?
  /// The transcript line's working directory.
  public let cwd: String?

  public init(
    id: String, kind: ToolKind?, time: Date, milliseconds: Int?, path: String?, cwd: String?
  ) {
    self.id = id
    self.kind = kind
    self.time = time
    self.milliseconds = milliseconds
    self.path = path
    self.cwd = cwd
  }
}

/// Reads tool calls from a Claude Code transcript: each `tool_use` block's `id`, `name` and file
/// path input, each `tool_result` block's `tool_use_id`, and the lines' `timestamp` and `cwd`.
public enum TranscriptTools {
  /// The tools whose path input ingest keeps, repo-relative.
  public static let fileTools: Set<ToolKind> = [
    .read, .edit, .write, .multiEdit, .notebookEdit, .grep, .glob,
  ]

  /// Each `tool_use` in `data`, in order, paired with its `tool_result` by id.
  /// A repeated `tool_use` id counts once, and a call keeps its first result. A last line with
  /// no newline that isn't JSON is skipped: the session may still be writing it.
  public static func calls(in data: Data) throws(TranscriptUsageError) -> [TranscriptToolCall] {
    let lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
    let endsWithNewline = data.last == UInt8(ascii: "\n")
    var uses: [(id: String, kind: ToolKind?, time: Date, path: String?, cwd: String?)] = []
    var seen: Set<String> = []
    var results: [String: Date] = [:]
    for (index, line) in lines.enumerated() where !line.isEmpty {
      let number = index + 1
      func malformed(_ what: String) -> TranscriptUsageError {
        TranscriptUsageError(line: number, reason: what)
      }
      guard let object = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any]
      else {
        if index == lines.count - 1, !endsWithNewline { break }
        throw malformed("not a JSON object")
      }
      let type = object["type"] as? String
      guard type == "assistant" || type == "user",
        let content = (object["message"] as? [String: Any])?["content"] as? [Any]
      else { continue }
      let blocks = content.compactMap { $0 as? [String: Any] }
      let tools = blocks.filter {
        let kind = $0["type"] as? String
        return (kind == "tool_use" && type == "assistant")
          || (kind == "tool_result" && type == "user")
      }
      if tools.isEmpty { continue }
      guard let text = object["timestamp"] as? String,
        let time = try? Date(text, strategy: timeFormat)
      else { throw malformed("a tool block on a line with no ISO 8601 `timestamp`") }
      for block in tools {
        if block["type"] as? String == "tool_result" {
          guard let id = block["tool_use_id"] as? String, TranscriptUsage.isMessageID(id) else {
            throw malformed("a `tool_result` with no `tool_use_id` of letters, digits, `_` and `-`")
          }
          if results[id] == nil { results[id] = time }
          continue
        }
        guard let id = block["id"] as? String, TranscriptUsage.isMessageID(id) else {
          throw malformed("a `tool_use` with no `id` of letters, digits, `_` and `-`")
        }
        guard let name = block["name"] as? String else {
          throw malformed("a `tool_use` with no `name`")
        }
        guard seen.insert(id).inserted else { continue }
        let kind = self.kind(of: name)
        var path: String?
        if let kind, fileTools.contains(kind), let input = block["input"] as? [String: Any] {
          path =
            ["file_path", "path", "notebook_path"].lazy.compactMap { input[$0] as? String }
            .first
        }
        uses.append((id, kind, time, path, object["cwd"] as? String))
      }
    }
    return uses.map { use in
      TranscriptToolCall(
        id: use.id, kind: use.kind, time: use.time,
        milliseconds: results[use.id].map {
          max(0, Int(($0.timeIntervalSince(use.time) * 1000).rounded()))
        },
        path: use.path, cwd: use.cwd)
    }
  }

  /// `mcp__…` names count as ``ToolKind/mcp``; any other name ``ToolKind`` doesn't hold is `nil`.
  public static func kind(of name: String) -> ToolKind? {
    if name.hasPrefix("mcp__") { return .mcp }
    guard let kind = ToolKind(rawValue: name), kind != .mcp else { return nil }
    return kind
  }

  private static let timeFormat = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
}

/// 1 transcript's tool calls and what they're tagged with.
public struct ToolTranscript: Sendable, Equatable {
  public let agent: UsageAgent
  public let agentID: String?
  public let role: AgentRole?
  public let task: String?
  public let calls: [TranscriptToolCall]

  public init(
    agent: UsageAgent, agentID: String?, role: AgentRole?, task: String?,
    calls: [TranscriptToolCall]
  ) {
    self.agent = agent
    self.agentID = agentID
    self.role = role
    self.task = task
    self.calls = calls
  }
}

/// What 1 tool ingest writes.
public struct ToolIngestPlan: Sendable, Equatable {
  public let events: [HarnessEvent]
  /// Distinct tool calls read, stored before or not.
  public let callsRead: Int
  /// Windows skipped because the store already holds their event.
  public let alreadyStored: Int

  public init(events: [HarnessEvent], callsRead: Int, alreadyStored: Int) {
    self.events = events
    self.callsRead = callsRead
    self.alreadyStored = alreadyStored
  }
}

/// From a session's tool calls to the `agent.tools` events not stored yet.
public enum ToolIngest {
  /// `topLevels` maps each working directory to the git top level holding it; a path is kept
  /// only when it sits inside its line's top level. `stored` is every `agent.tools` event id the
  /// store holds.
  public static func plan(
    sessionID: String, transcripts: [ToolTranscript], buildRun: String?,
    topLevels: [String: String], stored: Set<String>
  ) -> ToolIngestPlan {
    var events: [HarnessEvent] = []
    var read: Set<String> = []
    var alreadyStored = 0
    let window = TimeInterval(AgentToolsEvent.windowSeconds)
    for transcript in transcripts {
      // A worker's file may also sit under the session's subagents; the first file read keeps it.
      let calls = transcript.calls.filter { read.insert($0.id).inserted }
      // Windows run from the agent's first call, so a transcript read again yields the same ones.
      guard let anchor = calls.map(\.time).min() else { continue }
      let buckets = Dictionary(grouping: calls) {
        Int(($0.time.timeIntervalSince(anchor) / window).rounded(.down))
      }
      for bucket in buckets.keys.sorted() {
        let inWindow = (buckets[bucket] ?? []).sorted { $0.time < $1.time }
        guard let windowStart = inWindow.first?.time else { continue }
        let id = eventID(
          sessionID: sessionID, agentID: transcript.agentID, windowStart: windowStart)
        if stored.contains(id) {
          alreadyStored += 1
          continue
        }
        var counts: [ToolKind: (count: Int, milliseconds: Int)] = [:]
        var otherCount = 0
        var files: [String] = []
        var dropped = 0
        for call in inWindow {
          if let kind = call.kind {
            counts[kind, default: (0, 0)].count += 1
            counts[kind, default: (0, 0)].milliseconds += call.milliseconds ?? 0
          } else {
            otherCount += 1
          }
          guard let path = call.path else { continue }
          guard let kept = relative(path, cwd: call.cwd, topLevels: topLevels),
            EventPayloadGuard.rejection(inJSON: kept) == nil
          else {
            dropped += 1
            continue
          }
          if !files.contains(kept), files.count < AgentToolsEvent.maxFiles { files.append(kept) }
        }
        let tools = AgentToolsEvent(
          sessionID: sessionID, agent: transcript.agent, agentID: transcript.agentID,
          role: transcript.role, task: transcript.task, buildRun: buildRun,
          windowStart: windowStart,
          windowEnd: anchor.addingTimeInterval(window * Double(bucket + 1)),
          tools: ToolKind.allCases.compactMap { kind in
            counts[kind].map {
              ToolCallCount(tool: kind, count: $0.count, milliseconds: $0.milliseconds)
            }
          },
          otherCount: otherCount, files: files, droppedPaths: dropped)
        events.append(
          HarnessEvent(
            eventID: id, time: windowStart, source: HarnessEventSource(route: .ingest),
            payload: .agentTools(tools)))
      }
    }
    return ToolIngestPlan(events: events, callsRead: read.count, alreadyStored: alreadyStored)
  }

  /// The same window of the same agent always gets the same id, so ingesting again adds nothing.
  public static func eventID(sessionID: String, agentID: String?, windowStart: Date) -> String {
    let milliseconds = Int((windowStart.timeIntervalSince1970 * 1000).rounded())
    return "tools-\(sessionID)-\(agentID ?? "main")-\(milliseconds)"
  }

  /// `path` relative to the top level of `cwd`, resolved against `cwd` when relative; `nil` for
  /// a `~` path, an unknown top level, or a path that lands outside it.
  static func relative(_ path: String, cwd: String?, topLevels: [String: String]) -> String? {
    guard !path.hasPrefix("~"), let cwd, let top = topLevels[cwd] else { return nil }
    let absolute = path.hasPrefix("/") ? path : "\(cwd)/\(path)"
    guard let parts = components(absolute), let root = components(top), parts.starts(with: root)
    else { return nil }
    let rest = parts.dropFirst(root.count)
    return rest.isEmpty ? "." : rest.joined(separator: "/")
  }

  /// `nil` when a `..` climbs above `/`.
  private static func components(_ path: String) -> [Substring]? {
    var parts: [Substring] = []
    for part in path.split(separator: "/") where part != "." {
      if part == ".." {
        guard parts.popLast() != nil else { return nil }
      } else {
        parts.append(part)
      }
    }
    return parts
  }
}
